import Foundation

/// Two separate invocations exercise launch discovery and actual inference.
/// No capture controller, credentials, player, or network is constructed here.
@main struct ModelStartupChecks {
    @MainActor static func main() async throws {
        let args = CommandLine.arguments
        let root = URL(fileURLWithPath: args[1]), cache = URL(fileURLWithPath: args[2])
        let reportURL = URL(fileURLWithPath: args[3]), mode = args[4]
        func require(_ condition: Bool, _ message: String) throws { if !condition { throw AudioFailure.message(message) } }
        let manager = ModelManager(cacheDirectory: cache)
        manager.bundledDirectoryForChecks = mode == "install" ? root.appendingPathComponent("app/Resources/Models") : cache.appendingPathComponent("no-bundled-fallback")
        var downloadAttempts = 0, heartbeats = 0, maximumDelay = 0.0
        manager.downloadForChecks = { _ in downloadAttempts += 1; throw AudioFailure.message("network forbidden") }
        let started = ProcessInfo.processInfo.systemUptime
        let heartbeat = Task { @MainActor in
            var previous = ProcessInfo.processInfo.systemUptime
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 10_000_000)
                let now = ProcessInfo.processInfo.systemUptime
                maximumDelay = max(maximumDelay, now - previous); previous = now; heartbeats += 1
            }
        }
        await manager.restoreAtLaunch()
        try require(manager.resourcesAvailable && !manager.ready && manager.engine == nil && manager.engineState == .unloaded, "Launch must discover resources without loading")
        if mode == "install" { try require(!FileManager.default.fileExists(atPath: cache.path), "Launch installed resources or wrote the model cache") }
        let engine = try await manager.ensureLoaded()
        try require(manager.ready && manager.engineState == .loaded, "Explicit local start failed to load")
        let manifest = try JSONDecoder().decode(ModelInstallation.self, from: Data(contentsOf: cache.appendingPathComponent("installation.json")))
        try require(manifest.schema == 1 && manifest.resources.count == 2 && manifest.resources.allSatisfy { $0.sha256.count == 64 && FileManager.default.fileExists(atPath: $0.path) }, "Manifest does not describe actual installed resources")
        var results: [String: String] = [:]
        for (language, fixture) in [("en", "fictional-lecture-en.flac"), ("ja", "fictional-lecture-ja.flac")] {
            let samples = try AudioPCMConverter.readFile(root.appendingPathComponent("app/Tests/Fixtures/Audio/" + fixture))
            let rows = try await engine.recognize(samples, language: language)
            try require(!rows.isEmpty, "Actual \(language) inference returned no text")
            results[language] = rows.map(\.text).joined(separator: " ")
        }
        if mode == "reuse" {
            // Damage is confined to an independent fixture cache. A loaded engine
            // must not let missing disk resources retain the ready status.
            let badCache = cache.deletingLastPathComponent().appendingPathComponent("missing-after-load")
            try FileManager.default.createDirectory(at: badCache, withIntermediateDirectories: true)
            for resource in [OfflineResource.base, .vad] {
                let target = badCache.appendingPathComponent(resource.name)
                if !FileManager.default.fileExists(atPath: target.path) { try FileManager.default.copyItem(at: cache.appendingPathComponent(resource.name), to: target) }
            }
            let broken = ModelManager(cacheDirectory: badCache)
            broken.bundledDirectoryForChecks = badCache.appendingPathComponent("no-bundle")
            await broken.restoreAtLaunch(); _ = try await broken.ensureLoaded(); try require(broken.ready, "Fault fixture failed to load")
            try FileManager.default.removeItem(at: badCache.appendingPathComponent(OfflineResource.vad.name))
            do { _ = try await broken.ensureLoaded(); throw AudioFailure.message("Missing resource retained ready") }
            catch { try require(!broken.ready && broken.resourceState == .absent && broken.engine == nil, "Missing resource did not revoke readiness") }
        }
        heartbeat.cancel(); await heartbeat.value
        try require(downloadAttempts == 0, "Offline launch attempted download")
        try require(heartbeats > 0 && maximumDelay < 0.25, "Main thread stalled during discovery/load: \(maximumDelay)")
        let result: [String: Any] = ["mode": mode, "pid": ProcessInfo.processInfo.processIdentifier, "cache": cache.path, "actualEngine": true, "downloadAttempts": downloadAttempts, "heartbeats": heartbeats, "maximumMainActorHeartbeatSeconds": maximumDelay, "wallSeconds": ProcessInfo.processInfo.systemUptime - started, "transcription": results, "capture": false, "playback": false, "qualityAcceptance": "not assessed; existing Japanese limitations remain"]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL)
        print("PASS: \(mode), fresh process \(ProcessInfo.processInfo.processIdentifier), real English/Japanese engine, no download/capture/playback; heartbeat max \(maximumDelay)s")
    }
}
