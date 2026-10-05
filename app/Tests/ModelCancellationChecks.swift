import Foundation

private actor ValidationGate {
    private var arrivals = 0
    private var validations: [Int: CheckedContinuation<Void, Error>] = [:]
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []
    func validate() async throws {
        try await withCheckedThrowingContinuation { continuation in
            arrivals += 1
            validations[arrivals] = continuation
            let ready = observers.filter { $0.0 <= arrivals }
            observers.removeAll { $0.0 <= arrivals }
            ready.forEach { $0.1.resume() }
        }
    }
    func waitFor(_ count: Int) async {
        if arrivals >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }
    func release(_ index: Int, valid: Bool) {
        let continuation = validations.removeValue(forKey: index)!
        if valid { continuation.resume() }
        else { continuation.resume(throwing: AudioFailure.message("fixture validation rejected")) }
    }
}

/// Runs only public preparation/cancellation operations with gated verification
/// and a rejecting downloader. Never constructs URLSession or an audio device.
@main struct ModelCancellationChecks {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        var failures: [String] = []
        let started = ProcessInfo.processInfo.systemUptime
        // Bound the entire regression even if a continuation is mishandled.
        DispatchQueue.global().asyncAfter(deadline: .now() + 5) {
            fputs("FAIL: cancellation regression exceeded 5-second watchdog\n", stderr)
            exit(2)
        }
        for location in ["cached-invalid", "cached-valid", "bundled-invalid", "bundled-valid", "superseded"] {
            let caseRoot = root.appendingPathComponent(location)
            let cache = caseRoot.appendingPathComponent("cache"), bundle = caseRoot.appendingPathComponent("bundle")
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
            let fixture = (location.hasPrefix("bundled") ? bundle : cache).appendingPathComponent(OfflineResource.base.name)
            try Data("unchanged fixture".utf8).write(to: fixture)
            let manager = ModelManager(cacheDirectory: cache), gate = ValidationGate()
            manager.bundledDirectoryForChecks = bundle
            manager.validationForChecks = { _, _ in try await gate.validate() }
            var downloadAttempts = 0
            manager.downloadForChecks = { _ in
                downloadAttempts += 1
                throw AudioFailure.message("network replaced by rejecting test downloader")
            }
            let old = Task { await manager.download() }
            await gate.waitFor(1)
            manager.cancel()
            let cancelledStatus = manager.status
            var newer: Task<Void, Never>?
            if location == "superseded" {
                newer = Task { await manager.download() }
                await gate.waitFor(2)
            }
            let expectedStatus = manager.status
            await gate.release(1, valid: location.hasSuffix("-valid"))
            await old.value
            if downloadAttempts != 0 { failures.append("\(location): cancelled preparation reached downloader") }
            if manager.status != expectedStatus { failures.append("\(location): stale preparation changed current status") }
            if manager.progress != 0 { failures.append("\(location): stale preparation changed progress") }
            if manager.ready { failures.append("\(location): cancelled preparation became ready") }
            if manager.busy != (newer != nil) { failures.append("\(location): stale preparation changed current busy state") }
            if let newer {
                manager.cancel()
                await gate.release(2, valid: false)
                await newer.value
            }
            if manager.status != cancelledStatus { failures.append("\(location): final cancelled status was lost") }
            if try Data(contentsOf: fixture) != Data("unchanged fixture".utf8) { failures.append("\(location): fixture was modified") }
            let files = try FileManager.default.contentsOfDirectory(atPath: cache.path)
            if files.contains(where: { $0.hasSuffix(".partial") || $0.contains(".rejected-") }) { failures.append("\(location): cancellation staged or replaced cached files") }
        }
        // A completed download may be delivered after cancellation. Its owned
        // temporary file must be removed without staging or changing UI state.
        let lateGate = ValidationGate()
        let late = ModelManager(cacheDirectory: root.appendingPathComponent("late-result-cache"))
        late.bundledDirectoryForChecks = root.appendingPathComponent("missing-bundle")
        let lateFile = root.appendingPathComponent("late-download-fixture.partial")
        try Data("download completion fixture".utf8).write(to: lateFile)
        late.downloadForChecks = { _ in try await lateGate.validate(); return lateFile }
        let latePreparation = Task { await late.download() }
        await lateGate.waitFor(1)
        late.cancel()
        let lateCancelledStatus = late.status
        await lateGate.release(1, valid: true)
        await latePreparation.value
        if late.status != lateCancelledStatus || late.busy || late.ready || late.progress != 0 { failures.append("late-result: cancelled completion changed readiness or UI state") }
        if FileManager.default.fileExists(atPath: lateFile.path) { failures.append("late-result: owned download temporary file leaked") }
        if try !FileManager.default.contentsOfDirectory(atPath: late.cacheDirectory.path).isEmpty { failures.append("late-result: cancelled completion installed a file") }
        // Positive control proves an uncancelled missing model reaches the stub.
        let control = ModelManager(cacheDirectory: root.appendingPathComponent("positive-control-cache"))
        control.bundledDirectoryForChecks = root.appendingPathComponent("missing-bundle")
        var controlAttempts = 0
        control.downloadForChecks = { _ in controlAttempts += 1; throw AudioFailure.message("expected offline test rejection") }
        await control.download()
        if controlAttempts != 1 || control.ready || control.busy { failures.append("positive control did not reach rejecting downloader exactly once") }
        // Cancellation can arrive after the manager stores its download job but
        // before that job's async method starts. It must not create URLSession.
        let cancelledJob = ModelDownload { _ in }
        var networkStartAttempts = 0
        cancelledJob.beforeNetworkStartForChecks = {
            networkStartAttempts += 1
            throw AudioFailure.message("network construction replaced by test rejection")
        }
        cancelledJob.cancel()
        do { _ = try await cancelledJob.download(URL(string: "https://example.invalid/model")!); failures.append("pre-start: cancelled downloader returned success") }
        catch { }
        if networkStartAttempts != 0 { failures.append("pre-start: cancelled downloader attempted to construct a network session") }
        if !failures.isEmpty {
            failures.forEach { fputs("FAIL: \($0)\n", stderr) }
            exit(1)
        }
        print("PASS: cancellation during cached/bundled valid/invalid verification preserves status, progress, cache and readiness; superseded task cannot alter newer preparation; late download result is removed without installation; uncancelled positive control reaches rejecting downloader; \(ProcessInfo.processInfo.systemUptime - started) seconds; no network, capture, playback or model load")
    }
}
