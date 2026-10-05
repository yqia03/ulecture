import Foundation
import AVFoundation
import AppKit

private actor NativeFormatBackend: AudioCaptureBackend {
    var starts = 0, stops = 0, permissions = 0
    private var token: UUID?
    private var receiver: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var healthFailure: String?
    func requestPermission(for source: AudioSource) async throws { permissions += 1 }
    func prepare(requestID: UUID) async throws { token = requestID }
    func start(requestID: UUID, configuration: AudioConfiguration, receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void, failed: @escaping @Sendable (String) -> Void) async throws {
        guard token == requestID else { throw CancellationError() }
        starts += 1; receiver = receive
    }
    func stop() async throws { stops += 1; token = nil }
    func microphoneHealth(configuration: AudioConfiguration) async -> String? { healthFailure }
    func failHealth() { healthFailure = "injected-device-unplugged" }
    func emit(sampleRate: Double = 48000, channels: AVAudioChannelCount = 2, silence: Bool = false) {
        let count = AVAudioFrameCount(sampleRate / 10)
        let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channels)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: count)!; pcm.frameLength = count
        for c in 0..<Int(channels) { for i in 0..<Int(count) { pcm.floatChannelData![c][i] = silence ? 0 : sin(Float(i) * 2 * .pi * 400 / Float(sampleRate)) * 0.2 } }
        receiver?(pcm)
        // A hardware tap can reuse its storage immediately after callback return.
        for c in 0..<Int(channels) { pcm.floatChannelData![c].update(repeating: 0.99, count: Int(count)) }
    }
}

private final class FrameResults: @unchecked Sendable {
    private let lock = NSLock()
    private let google = AudioPCMConverter(targetSampleRate: 16000)
    private let openAI = AudioPCMConverter(targetSampleRate: 24000)
    private var count = 0, googleCount = 0, openAICount = 0, rates = Set<Double>(), channels = Set<UInt32>(), maxSample: Float = 0
    private var lastSequence = 0, sequencesValid = true
    func receive(_ frame: CapturedAudioFrame) -> Bool {
        lock.lock(); defer { lock.unlock() }
        do {
            let a = try google.convert(frame.pcm), b = try openAI.convert(frame.pcm)
            count += 1; googleCount += a.count; openAICount += b.count
            rates.insert(frame.sampleRate); channels.insert(frame.channelCount)
            maxSample = max(maxSample, a.map(abs).max() ?? 0, b.map(abs).max() ?? 0)
            if frame.sequence <= lastSequence { sequencesValid = false }; lastSequence = frame.sequence
            return true
        } catch { return false }
    }
    var snapshot: (Int, Int, Int, Set<Double>, Set<UInt32>, Float, Bool) {
        lock.lock(); defer { lock.unlock() }; return (count, googleCount, openAICount, rates, channels, maxSample, sequencesValid)
    }
    func finish() throws {
        lock.lock(); defer { lock.unlock() }
        googleCount += try google.finish().count; openAICount += try openAI.finish().count
    }
}

private final class BlockedFrames: @unchecked Sendable {
    let entered = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
    func receive(_ frame: CapturedAudioFrame) -> Bool { entered.signal(); _ = release.wait(timeout: .now() + 5); return true }
    func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 2) == .success }
}

private final class GatedCountingFrames: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private let entered = DispatchSemaphore(value: 0)
    let release = DispatchSemaphore(value: 0)
    var delivered: Int { lock.lock(); defer { lock.unlock() }; return count }
    func receive(_ frame: CapturedAudioFrame) -> Bool {
        lock.lock(); count += 1; let first = count == 1; lock.unlock()
        if first { entered.signal(); _ = release.wait(timeout: .now() + 5) }
        return true
    }
    func waitUntilEntered() -> Bool { entered.wait(timeout: .now() + 2) == .success }
}

@main struct OnlineCaptureChecks {
    @MainActor static func eventually(_ message: String, _ predicate: @escaping @MainActor () -> Bool) async throws {
        for _ in 0..<300 { if predicate() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
        throw AudioFailure.message(message)
    }
    @MainActor static func main() async throws {
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        func require(_ value: Bool, _ message: String) throws { if !value { throw AudioFailure.message(message) } }
        let models = ModelManager(cacheDirectory: out.appendingPathComponent("never-created-model-cache"))
        models.bundledDirectoryForChecks = out.appendingPathComponent("missing-bundle")
        var downloads = 0
        models.downloadForChecks = { _ in downloads += 1; throw AudioFailure.message("No downloads allowed") }
        await models.restoreAtLaunch()
        try require(!models.ready && !models.resourcesAvailable && models.engine == nil, "Missing models became ready")
        try require(!FileManager.default.fileExists(atPath: models.cacheDirectory.path), "Read-only startup wrote model cache")
        let coordinator = CaptureSessionCoordinator(), backend = NativeFormatBackend()
        let capture = AudioCaptureSession(backend: backend, coordinator: coordinator)
        var config = AudioConfiguration(); config.saveRecording = true
        await capture.configure(config)
        var recordings: [AudioRecording] = [], gaps: [AudioGap] = []
        capture.onRecording = { recordings.append($0) }; capture.onGap = { gaps.append($0) }
        let result = FrameResults()
        try await capture.preflight(sessionID: "online-no-model", elapsedOffset: 0)
        let preflightStarts = await backend.starts
        try require(capture.phase == .starting && coordinator.owner != nil && preflightStarts == 0, "Preflight did not hold the lease before service handshake")
        try await capture.startPrepared(recordingDirectory: out.appendingPathComponent("recordings"), onFrame: { result.receive($0) })
        for _ in 0..<30 { await backend.emit(); await capture.captureBarrierForChecks() }
        try result.finish()
        let snapshot = result.snapshot
        try require(snapshot.0 == 30 && snapshot.3 == [48000] && snapshot.4 == [2], "Capture lost native rate/channels")
        try require(abs(snapshot.1 - 48000) < 128 && abs(snapshot.2 - 72000) < 192, "Independent resampling duration drifted: \(snapshot.1) / \(snapshot.2)")
        try require(snapshot.5 < 0.4 && snapshot.5 > 0.1 && snapshot.6, "Copied PCM reused hardware memory or ordering changed")
        capture.stopAdmission(); await capture.pause()
        let stoppedCount = result.snapshot.0
        for _ in 0..<100 { await backend.emit() }
        await capture.pause()
        try require(result.snapshot.0 == stoppedCount && coordinator.owner == nil && !capture.draining, "Late capture callbacks escaped pause")
        try require(!recordings.isEmpty && recordings.allSatisfy(\.verified), "Online independent recording was not saved")
        let silence = FrameResults()
        try await capture.start(sessionID: "online-no-model", elapsedOffset: capture.currentOffset, recordingDirectory: out.appendingPathComponent("recordings"), onFrame: { silence.receive($0) })
        for _ in 0..<10 { await backend.emit(sampleRate: 44100, channels: 1, silence: true); await capture.captureBarrierForChecks() }
        await capture.end()
        try require(silence.snapshot.0 == 10 && silence.snapshot.3 == [44100] && silence.snapshot.5 == 0, "Silence was removed before online consumers")
        try require(capture.phase == .ended && !gaps.isEmpty && coordinator.owner == nil, "End did not preserve gaps/release lease")
        var endedRejected = false
        do { try await capture.start(sessionID: "online-no-model", elapsedOffset: 0, recordingDirectory: nil, onFrame: { _ in true }) } catch { endedRejected = true }
        try require(endedRejected && capture.phase == .ended, "Ended capture restarted")
        // Hardware PCM16 interleaved input is copied with its original format.
        let intFormat = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 44100, channels: 2, interleaved: true)!
        let intPCM = AVAudioPCMBuffer(pcmFormat: intFormat, frameCapacity: 4410)!; intPCM.frameLength = 4410
        intPCM.int16ChannelData![0].initialize(repeating: 8192, count: 8820)
        let owned = try CapturedAudioFrame.copy(intPCM, epochID: "int16", sequence: 1)
        intPCM.int16ChannelData![0].update(repeating: 0, count: 8820)
        let intConverter = AudioPCMConverter(targetSampleRate: 24000)
        let intSamples = try intConverter.convert(owned.pcm) + intConverter.finish()
        // The leading/trailing filter transient is excluded from the DC plateau.
        try require(owned.pcm.format == intFormat && abs(intSamples.count - 2400) < 64 && intSamples.dropFirst(100).dropLast(64).allSatisfy { abs($0 - 0.25) < 0.01 }, "Interleaved PCM16 copy/resampling failed: \(intSamples.count) frames")
        // Slow downstream work cannot create an unbounded capture queue.
        let blockedBackend = NativeFormatBackend(), blockedCapture = AudioCaptureSession(backend: blockedBackend, coordinator: CaptureSessionCoordinator()), blocked = BlockedFrames()
        try await blockedCapture.start(sessionID: "bounded", elapsedOffset: 0, recordingDirectory: nil, onFrame: { blocked.receive($0) })
        await blockedBackend.emit()
        let entered = await Task.detached { blocked.waitUntilEntered() }.value
        try require(entered, "Blocked capture fixture did not enter")
        for _ in 0..<30 { await blockedBackend.emit() }
        try await eventually("Capture overload did not pause") { blockedCapture.phase == .paused }
        blocked.release.signal(); await blockedCapture.pause()
        try require(blockedCapture.status.contains("两秒") && !blockedCapture.draining, "Overload reason/drain was lost")
        for ending in [false, true] {
            let gateBackend = NativeFormatBackend(), gate = GatedCountingFrames()
            let gatedCapture = AudioCaptureSession(backend: gateBackend, coordinator: CaptureSessionCoordinator())
            var deliveredAtDrain = 0
            gatedCapture.onDrain = { deliveredAtDrain = gate.delivered }
            try await gatedCapture.start(sessionID: ending ? "end-tail" : "pause-tail", elapsedOffset: 0, recordingDirectory: nil, onFrame: { gate.receive($0) })
            await gateBackend.emit()
            let gateEntered = await Task.detached { gate.waitUntilEntered() }.value
            try require(gateEntered, "Tail gate did not enter")
            for _ in 0..<5 { await gateBackend.emit() }
            gatedCapture.stopAdmission(preservingAdmittedFrames: ending)
            let closing = Task { @MainActor in if ending { await gatedCapture.end() } else { await gatedCapture.pause() } }
            try await eventually("Tail drain did not begin") { gatedCapture.draining }
            for _ in 0..<5 { await gateBackend.emit() }
            gate.release.signal(); await closing.value
            let expectedFrames = ending ? 6 : 1
            try require(gate.delivered == expectedFrames && deliveredAtDrain == expectedFrames, "Normal end lost admitted frames or pause dispatched queued frames")
        }
        // Device loss and sleep use the same immediate admission closure.
        let deviceBackend = NativeFormatBackend(), deviceCapture = AudioCaptureSession(backend: deviceBackend, coordinator: CaptureSessionCoordinator())
        try await deviceCapture.start(sessionID: "device", elapsedOffset: 0, recordingDirectory: nil, onFrame: { _ in true })
        await deviceBackend.failHealth()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)
        try await eventually("Device loss did not pause") { deviceCapture.phase == .paused && !deviceCapture.draining }
        try require(deviceCapture.status == "injected-device-unplugged", "Device loss reason changed")
        let sleepCapture = AudioCaptureSession(backend: NativeFormatBackend(), coordinator: CaptureSessionCoordinator())
        try await sleepCapture.start(sessionID: "sleep", elapsedOffset: 0, recordingDirectory: nil, onFrame: { _ in true })
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.willSleepNotification, object: nil)
        try await eventually("Sleep did not pause") { sleepCapture.phase == .paused && !sleepCapture.draining }
        NSWorkspace.shared.notificationCenter.post(name: NSWorkspace.didWakeNotification, object: nil)
        try await Task.sleep(nanoseconds: 30_000_000)
        try require(sleepCapture.phase == .paused, "Wake automatically resumed capture")
        try require(models.engine == nil && !models.ready && downloads == 0 && !FileManager.default.fileExists(atPath: models.cacheDirectory.path), "Online capture touched local ASR")
        let report: [String: Any] = ["nativeInputSampleRates": [48000, 44100], "inputChannels": [2, 1], "googleFrames": snapshot.1, "openAIFrames": snapshot.2, "silenceFramesDelivered": silence.snapshot.0, "recordingChunks": recordings.count, "staleCallbacksRejected": 100, "interleavedPCM16": true, "boundedOverload": true, "normalEndDrainsRawFrames": true, "pauseRejectsQueuedFrames": true, "deviceLoss": true, "sleepManualResume": true, "modelLoaded": false, "modelDownloads": downloads, "hardware": "injected backend", "networkRequests": 0, "physicalAudioAcceptance": false]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("online-capture.json"))
        print("PASS: model-free shared capture; independent 16/24k resampling, native 48/44.1k preservation, owned PCM, silence, recording, preflight lease, pause/end and 100 late callbacks")
    }
}
