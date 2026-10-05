import Foundation
import AVFoundation

/// Silent concurrency checks: never constructs an AVAudioEngine, starts a tap,
/// requests permission, loads a model, or creates an audio output player.
@main struct AudioLifecycleChecks {
    static func postWhileMainWaits() async -> Bool {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                let posted = DispatchSemaphore(value: 0)
                DispatchQueue.global(qos: .userInitiated).async {
                    NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: nil)
                    posted.signal()
                }
                let result = posted.wait(timeout: .now() + 0.3)
                continuation.resume(returning: result == .success)
            }
        }
    }
    static func main() async throws {
        let cache = URL(fileURLWithPath: CommandLine.arguments[1]).appendingPathComponent("unused-model-cache")
        let controller = await MainActor.run { AudioController(modelManager: ModelManager(cacheDirectory: cache)) }
        // AVAudioEngine posts its configuration notification from an engine worker.
        // Its synchronous start/stop caller may still own the main thread. This
        // worker must be able to return without first executing main-queue work.
        let started = ProcessInfo.processInfo.systemUptime
        let completedWithoutMainQueue = await postWhileMainWaits()
        // Allow deferred health checks to drain after the simulated engine call.
        await MainActor.run {}
        guard completedWithoutMainQueue else {
            fputs("FAIL: engine configuration notification synchronously waited for blocked main queue (300 ms watchdog)\n", stderr)
            exit(1)
        }
        let stillReady = await MainActor.run { controller.phase == .ready && !controller.draining }
        guard stillReady else { fputs("FAIL: idle notification changed capture lifecycle\n", stderr); exit(1) }
        let sibling = await MainActor.run { AudioController(modelManager: ModelManager(cacheDirectory: cache)) }
        await controller.pause()
        for _ in 0..<25 {
            guard await postWhileMainWaits() else { fputs("FAIL: repeated notification stalled during paused state\n", stderr); exit(1) }
        }
        await controller.end()
        await sibling.pause()
        for _ in 0..<25 {
            guard await postWhileMainWaits() else { fputs("FAIL: repeated notification stalled during ended state\n", stderr); exit(1) }
        }
        let lifecyclePreserved = await MainActor.run { controller.phase == .ended && !controller.draining && sibling.phase == .paused && !sibling.draining }
        guard lifecyclePreserved else { fputs("FAIL: deferred notification resumed a paused/ended controller\n", stderr); exit(1) }
        // Acquisition can fail before model loading and the startup catch. The
        // sound-check status must still expose this refusal without changing
        // the existing owner's lifecycle or touching hardware/model resources.
        let coordinator = await MainActor.run { CaptureSessionCoordinator() }
        let owner = UUID()
        try coordinator.acquire(owner: owner, sessionID: "independent-interpretation")
        let rejected = await MainActor.run { AudioController(modelManager: ModelManager(cacheDirectory: cache), coordinator: coordinator) }
        var leaseFailure: String?
        do { try await rejected.start(sessionID: "sound-check", elapsedOffset: 0, recordingDirectory: nil) }
        catch { leaseFailure = error.localizedDescription }
        let visibleRefusal = await MainActor.run { rejected.status == leaseFailure && rejected.status.contains("另一个音频会话") && rejected.phase == .ready && !rejected.draining && rejected.sessionID == nil && coordinator.owner == owner && coordinator.sessionID == "independent-interpretation" }
        guard visibleRefusal else { fputs("FAIL: shared lease refusal was hidden or changed the active owner\n", stderr); exit(1) }
        coordinator.release(owner: owner)
        guard !FileManager.default.fileExists(atPath: cache.path) else { fputs("FAIL: lease refusal touched model cache\n", stderr); exit(1) }
        print("PASS: refused sound check publishes the real shared-lease failure while independent capture ownership remains unchanged; no hardware or model load")
        print("PASS: 51 production configuration notifications never block engine worker on main queue; two controllers preserve ready/paused/ended lifecycle; \(ProcessInfo.processInfo.systemUptime - started) seconds")
    }
}
