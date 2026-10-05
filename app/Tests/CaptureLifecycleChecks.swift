import Foundation
import AVFoundation

private actor ScriptedCaptureBackend: AudioCaptureBackend {
    var permissions = 0, starts = 0, stops = 0
    var waitPermission = false, waitStart = false, failStop = false
    private var permissionGate: CheckedContinuation<Void, Never>?, startGate: CheckedContinuation<Void, Never>?
    private var stopWaiters: [CheckedContinuation<Void, Never>] = []
    private var startPending = false
    private var epoch: UUID?
    private var receiver: (@Sendable (AVAudioPCMBuffer) -> Void)?
    func configure(waitPermission: Bool = false, waitStart: Bool = false, failStop: Bool = false) { self.waitPermission = waitPermission; self.waitStart = waitStart; self.failStop = failStop }
    func requestPermission(for source: AudioSource) async throws {
        permissions += 1
        if waitPermission { await withCheckedContinuation { permissionGate = $0 } }
    }
    func prepare(requestID: UUID) async throws { epoch = requestID }
    func start(requestID: UUID, configuration: AudioConfiguration, receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void, failed: @escaping @Sendable (String) -> Void) async throws {
        guard epoch == requestID else { throw CancellationError() }
        starts += 1; startPending = true; receiver = receive
        defer { startPending = false; let waiters = stopWaiters; stopWaiters.removeAll(); waiters.forEach { $0.resume() } }
        if waitStart { await withCheckedContinuation { startGate = $0 } }
        guard epoch == requestID else { throw CancellationError() }
    }
    func stop() async throws {
        stops += 1; epoch = nil
        if startPending { await withCheckedContinuation { stopWaiters.append($0) } }
        if failStop { throw AudioFailure.message("injected hardware stop failure") }
    }
    func microphoneHealth(configuration: AudioConfiguration) async -> String? { nil }
    func releasePermission() { permissionGate?.resume(); permissionGate = nil }
    func releaseStart() { startGate?.resume(); startGate = nil }
    func emitLateSilence() {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!; buffer.frameLength = 1600
        buffer.floatChannelData![0].initialize(repeating: 0, count: 1600)
        for _ in 0..<100 { receiver?(buffer) }
    }
}

@main struct CaptureLifecycleChecks {
    @MainActor static func eventually(_ message: String, _ predicate: @escaping @MainActor () async -> Bool) async throws {
        for _ in 0..<500 {
            if await predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        throw AudioFailure.message("Timed out: " + message)
    }
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), out = URL(fileURLWithPath: CommandLine.arguments[2])
        func require(_ condition: Bool, _ message: String) throws { if !condition { throw AudioFailure.message(message) } }
        let models = ModelManager(cacheDirectory: out.appendingPathComponent("models"))
        models.bundledDirectoryForChecks = root.appendingPathComponent("app/Resources/Models")
        await models.restoreAtLaunch(); _ = try await models.ensureLoaded(); try require(models.ready, models.status)
        var results: [String] = [], maximumDelay = 0.0, ticks = 0
        let heartbeat = Task { @MainActor in
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
                let now = ProcessInfo.processInfo.systemUptime; maximumDelay = max(maximumDelay, now - previous); previous = now; ticks += 1
            }
        }
        // A granted permission delivered after cancellation must not start hardware.
        do {
            let coordinator = CaptureSessionCoordinator(), backend = ScriptedCaptureBackend()
            await backend.configure(waitPermission: true)
            let controller = AudioController(modelManager: models, backend: backend, coordinator: coordinator)
            let start = Task { try await controller.start(sessionID: "permission-late", elapsedOffset: 0, recordingDirectory: nil) }
            try await eventually("permission boundary") { await backend.permissions == 1 }
            await controller.pause(); await backend.releasePermission()
            do { try await start.value; throw AudioFailure.message("Cancelled permission returned success") } catch is CancellationError { }
            try require(await backend.starts == 0, "Late permission started hardware")
            try require(controller.phase == .paused && coordinator.owner == nil, "Permission cancellation did not preserve paused state")
            results.append("late permission cannot start hardware")
        }
        // A backend still completing start keeps ownership until stop is proven.
        do {
            let coordinator = CaptureSessionCoordinator(), backend = ScriptedCaptureBackend()
            await backend.configure(waitPermission: true)
            let controller = AudioController(modelManager: models, backend: backend, coordinator: coordinator)
            let start = Task { try await controller.start(sessionID: "task-cancelled", elapsedOffset: 0, recordingDirectory: nil) }
            try await eventually("permission for task cancellation") { await backend.permissions == 1 }
            start.cancel()
            try await eventually("cancellation handler") { controller.phase == .paused && !controller.draining }
            await backend.releasePermission()
            do { try await start.value; throw AudioFailure.message("Cancelled task returned success") } catch is CancellationError { }
            try require(await backend.starts == 0, "Task cancellation allowed late capture")
            results.append("Swift task cancellation invokes the production stop boundary")
        }
        // A backend still completing start keeps ownership until stop is proven.
        do {
            let coordinator = CaptureSessionCoordinator(), backend = ScriptedCaptureBackend()
            await backend.configure(waitStart: true)
            let controller = AudioController(modelManager: models, backend: backend, coordinator: coordinator)
            let start = Task { try await controller.start(sessionID: "start-late", elapsedOffset: 0, recordingDirectory: nil) }
            try await eventually("start boundary") { await backend.starts == 1 }
            controller.stopImmediately(reason: "cancelled")
            let sibling = AudioController(modelManager: models, backend: ScriptedCaptureBackend(), coordinator: coordinator)
            var refused = false
            do { try await sibling.start(sessionID: "concurrent", elapsedOffset: 0, recordingDirectory: nil) } catch { refused = true }
            try require(refused && coordinator.owner != nil && controller.draining, "Lease released before delayed start settled")
            await backend.releaseStart()
            do { try await start.value; throw AudioFailure.message("Cancelled start returned success") } catch is CancellationError { }
            await controller.pause()
            await backend.emitLateSilence()
            try require(coordinator.owner == nil && controller.phase == .paused && !controller.draining && controller.provisional.isEmpty, "Late start/callback changed paused state")
            results.append("late start/callback isolated; lease held until stop; second controller rejected")
        }
        // Startup watchdog is separate from capture duration and does not wait
        // for the system permission callback to release the UI.
        do {
            let coordinator = CaptureSessionCoordinator(), backend = ScriptedCaptureBackend()
            await backend.configure(waitPermission: true)
            let controller = AudioController(modelManager: models, backend: backend, coordinator: coordinator)
            let start = Task { try await controller.start(sessionID: "timeout", elapsedOffset: 0, recordingDirectory: nil, startupTimeout: 0.2) }
            try await eventually("permission before watchdog") { await backend.permissions == 1 }
            try await eventually("watchdog pauses") { controller.phase == .paused && !controller.draining }
            try require(controller.status.contains("超时") && controller.captureDeadline == nil, "Startup timeout used capture timer or lost reason")
            await backend.releasePermission()
            do { try await start.value; throw AudioFailure.message("Timed out start returned success") } catch is CancellationError { }
            results.append("startup timeout while permission pending is responsive and never captures")
        }
        // Production automatic deadline uses the same path as the 15 second UI.
        do {
            let coordinator = CaptureSessionCoordinator(), backend = ScriptedCaptureBackend()
            let controller = AudioController(modelManager: models, backend: backend, coordinator: coordinator)
            try await controller.start(sessionID: "duration", elapsedOffset: 0, recordingDirectory: nil, maximumCaptureDuration: 0.06)
            try require(controller.phase == .capturing && controller.captureDeadline != nil, "Capture did not begin with deadline")
            do { try await controller.start(sessionID: "double-click", elapsedOffset: 0, recordingDirectory: nil); throw AudioFailure.message("Duplicate start accepted") }
            catch { try require(await backend.starts == 1, "Duplicate start reached backend") }
            try await eventually("automatic duration stop") { controller.phase == .paused && !controller.draining }
            try require(controller.captureDeadline == nil && coordinator.owner == nil && !models.isInUse, "Automatic stop did not drain/release")
            var config = controller.configuration; config.language = "ja"; await controller.configure(config)
            try require(controller.phase == .paused && controller.configuration.language == "ja", "Config change auto-resumed")
            await controller.end()
            do { try await controller.start(sessionID: "ended", elapsedOffset: 0, recordingDirectory: nil); throw AudioFailure.message("Ended session restarted") }
            catch { try require(await backend.starts == 1, "Ended start reached backend") }
            results.append("capture duration stops; duplicate/ended start rejected; configuration remains paused")
        }
        // Stopping an idle sibling must not clear an active model's use guard.
        do {
            let coordinator = CaptureSessionCoordinator(), backend = ScriptedCaptureBackend()
            let controller = AudioController(modelManager: models, backend: backend, coordinator: coordinator)
            let sibling = AudioController(modelManager: models, backend: ScriptedCaptureBackend(), coordinator: coordinator)
            try await controller.start(sessionID: "active", elapsedOffset: 0, recordingDirectory: nil)
            await sibling.pause()
            try require(models.isInUse && coordinator.owner != nil, "Idle sibling released active ownership")
            await controller.pause(); results.append("idle sibling cannot clear model-in-use guard")
        }
        // Failed stop must not advertise ended/idle or release another session.
        do {
            let coordinator = CaptureSessionCoordinator(), backend = ScriptedCaptureBackend()
            let controller = AudioController(modelManager: models, backend: backend, coordinator: coordinator)
            try await controller.start(sessionID: "stop-failure", elapsedOffset: 0, recordingDirectory: nil)
            await backend.configure(failStop: true); await controller.end()
            try require(controller.phase == .paused && controller.requiresRestartAfterStopFailure && coordinator.owner != nil, "Stop failure released ownership or advertised ended")
            results.append("failed stop retains capture lease and reports restart required")
        }
        // Exercise the real backend's pre-dispatch cancellation latch without
        // requesting permission. The configuration has no device, so even a
        // broken latch cannot reach AVAudioEngine creation or open hardware.
        do {
            let hardware = HardwareAudioCaptureBackend(), request = UUID()
            try await hardware.prepare(requestID: request); try await hardware.stop()
            var cancelled = false
            do { try await hardware.start(requestID: request, configuration: AudioConfiguration(), receive: { _ in }, failed: { _ in }) }
            catch is CancellationError { cancelled = true }
            try require(cancelled, "Native backend did not reject cancelled generation before start dispatch")
            results.append("native backend rejects cancelled dispatch before constructing hardware")
        }
        heartbeat.cancel(); await heartbeat.value
        try require(ticks > 0 && maximumDelay < 0.25, "MainActor responsiveness exceeded 250ms: \(maximumDelay)")
        let report: [String: Any] = ["checks": results, "maximumMainActorHeartbeatSeconds": maximumDelay, "heartbeatCount": ticks, "actualModelAndVAD": true, "productionStartPauseStateMachine": true, "hardware": "injected silent backend", "captureRequested": false, "permissionRequested": false, "playback": false, "providerRequests": 0, "doesNotProve": "physical devices, TCC consent, live sound check, native backend timings or three-hour classroom"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("capture-lifecycle.json"))
        print("PASS: \(results.count) production capture lifecycle scenarios; actual VAD/model; silent backend; heartbeat maximum \(maximumDelay)s")
    }
}
