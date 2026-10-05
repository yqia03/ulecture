import Foundation
import AVFoundation

private final class ReplayEvents: @unchecked Sendable {
    let lock = NSLock()
    var transcripts: [AudioTranscript] = [], gaps: [AudioGap] = [], recordings: [AudioRecording] = [], provisional: [String] = [], errors: [String] = []
    var confirmations: [Double] = []
    var captionDrafts: [AudioProvisional] = []
    func caption(_ draft: AudioProvisional) { lock.lock(); captionDrafts.append(draft); lock.unlock() }
    func add(_ row: AudioTranscript) { lock.lock(); transcripts.append(row); confirmations.append(ProcessInfo.processInfo.systemUptime); lock.unlock() }
    func gap(_ row: AudioGap) { lock.lock(); gaps.append(row); lock.unlock() }
    func recording(_ row: AudioRecording) { lock.lock(); recordings.append(row); lock.unlock() }
    func interim(_ text: String) { lock.lock(); if !text.isEmpty { provisional.append(text) }; lock.unlock() }
    func error(_ text: String) { lock.lock(); errors.append(text); lock.unlock() }
}

@main struct AudioChecks {
    static func expect(_ value: Bool, _ name: String) throws { if !value { throw AudioFailure.message("FAIL: \(name)") } }
    static func replay(engine: ASREngine, samples: [Float], language: String, dir: URL?, limits: AudioPipeline.Limits = .init(), anchor: Double = 0, allowProvisional: Bool = false) async throws -> [String: Any] {
        let events = ReplayEvents(), started = ProcessInfo.processInfo.systemUptime
        let pipe = try AudioPipeline(engine: engine, sessionID: "development-replay", epochID: UUID().uuidString, language: language, anchor: anchor, recordingDirectory: dir, limits: limits, onConfirmed: events.add, onProvisional: events.interim, onGap: events.gap, onRecording: events.recording, onError: events.error, onCaptionProvisional: events.caption)
        var finalInputAt = started
        for offset in stride(from: 0, to: samples.count, by: 1600) {
            try expect(pipe.append(Array(samples[offset..<min(offset + 1600, samples.count)])), "bounded admission accepted paced file chunk")
            await pipe.barrier(); finalInputAt = ProcessInfo.processInfo.systemUptime
            if allowProvisional, offset == 112000 { try await Task.sleep(nanoseconds: 500_000_000) }
        }
        await pipe.finish(); let elapsed = ProcessInfo.processInfo.systemUptime - started
        await pipe.finish() // Repeated end must not deliver duplicate confirmed records.
        try expect(!pipe.append([Float](repeating: 0.01, count: 1600)), "ended pipeline rejects additional audio")
        try expect(Set(events.transcripts.map(\.id)).count == events.transcripts.count, "confirmation IDs unique / repeated end idempotent")
        var previous = anchor
        for row in events.transcripts { try expect(row.start >= previous && row.end > row.start && row.end <= anchor + Double(samples.count)/16000 + 0.021, "real timeline monotonic and bounded"); previous = row.end }
        let clearIDs = Set(events.captionDrafts.filter { $0.text.isEmpty }.map(\.id))
        try expect(events.transcripts.allSatisfy { $0.replacesProvisionalID.map(clearIDs.contains) == true }, "confirmed rows explicitly replace and clear their utterance draft")
        let draftIDs = Set(events.captionDrafts.filter { !$0.text.isEmpty }.map(\.id))
        try expect(draftIDs.isSubset(of: clearIDs), "every emitted provisional identity is finalized or cleared at drain")
        let data = try JSONEncoder().encode(events.transcripts)
        return ["text": events.transcripts.map(\.text).joined(separator: " "), "segments": try JSONSerialization.jsonObject(with: data), "sampleSeconds": Double(samples.count)/16000, "wallSeconds": elapsed, "finalFeedToLastConfirmationSeconds": max(0, (events.confirmations.last ?? finalInputAt) - finalInputAt), "provisionalReplacements": events.provisional.count, "stableDraftIdentities": draftIDs.count, "finalDraftMappingsVerified": true, "gaps": try JSONSerialization.jsonObject(with: JSONEncoder().encode(events.gaps)), "recordings": try JSONSerialization.jsonObject(with: JSONEncoder().encode(events.recordings)), "errors": events.errors, "recordingEnabled": dir != nil, "measurementBoundary": "silent accelerated file-feed start to drain; final input admission to last confirmed callback. Not physical utterance latency or live P95."]
    }
    static func main() async throws {
        let args = CommandLine.arguments
        guard args.count >= 3 else { throw AudioFailure.message("Usage: audio-checks project-root output-directory") }
        let root = URL(fileURLWithPath: args[1]), out = URL(fileURLWithPath: args[2]); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let model = root.appendingPathComponent("app/Resources/Models/ggml-base.bin"), vad = root.appendingPathComponent("app/Resources/Models/ggml-silero-v6.2.0.bin")
        try OfflineResource.validate(model, resource: .base); try OfflineResource.validate(vad, resource: .vad)
        let engine = try ASREngine(model: model, vad: vad)
        let fixtures: [(String,String,String)] = [
            ("fictional-en", "en", "app/Tests/Fixtures/Audio/fictional-lecture-en.flac"),
            ("fictional-ja", "ja", "app/Tests/Fixtures/Audio/fictional-lecture-ja.flac")]
        var results: [String: Any] = [:], cached: [String: [Float]] = [:]
        for (name, language, path) in fixtures {
            let samples = try AudioPCMConverter.readFile(root.appendingPathComponent(path)); cached[name] = samples
            results[name] = try await replay(engine: engine, samples: samples, language: language, dir: nil)
        }
        for language in ["en", "ja"] {
            let result = try await replay(engine: engine, samples: [Float](repeating: 0, count: 128000), language: language, dir: nil)
            try expect((result["text"] as? String) == "", "\(language) digital silence emits no hallucinated transcript"); results["silence-\(language)"] = result
        }
        let recordingDir = out.appendingPathComponent("explicit-recording-check")
        results["recording-enabled"] = try await replay(engine: engine, samples: cached["fictional-en"]!, language: "en", dir: recordingDir, anchor: 42)
        let recordings = (results["recording-enabled"] as! [String: Any])["recordings"] as! [[String: Any]]
        try expect(!recordings.isEmpty && recordings.allSatisfy { $0["verified"] as? Bool == true }, "explicit audio chunks really reopened and verified")
        let speech = cached["fictional-en"]!
        let half = speech.count / 2
        results["pause-tail"] = try await replay(engine: engine, samples: Array(speech[..<half]), language: "en", dir: nil, anchor: 0)
        results["resume-new-epoch"] = try await replay(engine: engine, samples: Array(speech[half...]), language: "en", dir: nil, anchor: Double(half)/16000 + 5)
        let provisional = try await replay(engine: engine, samples: cached["fictional-ja"]!, language: "ja", dir: nil, allowProvisional: true)
        try expect((provisional["provisionalReplacements"] as? Int ?? 0) > 0, "real engine interim output appears before end and is replaced")
        results["provisional-file-paced-check"] = provisional
        var crowded = AudioPipeline.Limits(); crowded.maximumUtteranceSeconds = 2; crowded.maximumQueuedFinals = 1; crowded.provisionalSeconds = 100
        let overload = try await replay(engine: engine, samples: Array(repeating: speech, count: 4).flatMap { $0 }, language: "en", dir: nil, limits: crowded)
        try expect(!(overload["gaps"] as! [[String: Any]]).isEmpty, "bounded overload reports dropped audio gaps"); results["overload-injected-limits"] = overload
        var alternative = AudioPipeline.Limits(); alternative.silenceSeconds = 1.2
        results["ja-silence-endpoint-1.2s-comparison"] = try await replay(engine: engine, samples: cached["fictional-ja"]!, language: "ja", dir: nil, limits: alternative)
        let manager = ModelManager(cacheDirectory: out.appendingPathComponent("isolated-model-cache"))
        await manager.prepareBundledOrCached()
        let missingReady = manager.ready
        try expect(!missingReady, "missing resources never report ready")
        let cache = manager.cacheDirectory
        try FileManager.default.copyItem(at: vad, to: cache.appendingPathComponent(OfflineResource.vad.name))
        await manager.importModel(url: model)
        let importedReady = manager.ready
        try expect(importedReady, "explicit import hash checks and genuinely loads model")
        #if AUDIO_TESTING
        // Corrupt cache repair uses the real preparation path and only verified local bundle
        // fixtures. Network remains OS denied throughout this executable.
        let repairCache = out.appendingPathComponent("corrupt-cache-repair")
        try FileManager.default.createDirectory(at: repairCache, withIntermediateDirectories: true)
        let badBaseBytes = Data("broken cached base".utf8), badVADBytes = Data("broken cached VAD".utf8)
        try badBaseBytes.write(to: repairCache.appendingPathComponent(OfflineResource.base.name))
        try badVADBytes.write(to: repairCache.appendingPathComponent(OfflineResource.vad.name))
        let repairManager = ModelManager(cacheDirectory: repairCache)
        await repairManager.prepareBundledOrCached()
        try expect(!repairManager.ready, "corrupt cache with no usable bundle never becomes ready")
        repairManager.bundledDirectoryForChecks = model.deletingLastPathComponent()
        await repairManager.prepareBundledOrCached()
        try expect(repairManager.ready, "bad base and VAD caches repair from verified bundled resources and actually load")
        let preservedBad = try FileManager.default.contentsOfDirectory(at: repairCache, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.contains(".rejected-") }
        let preservedBytes = try preservedBad.map { try Data(contentsOf: $0) }
        try expect(preservedBytes.contains(badBaseBytes) && preservedBytes.contains(badVADBytes), "corrupt cache originals preserved after verified replacement")
        try badVADBytes.write(to: repairCache.appendingPathComponent(OfflineResource.vad.name))
        repairManager.bundledDirectoryForChecks = nil
        await repairManager.prepareBundledOrCached()
        try expect(!repairManager.ready && repairManager.resourceState == .error && repairManager.engine == nil, "damaged disk resource revokes readiness even when an earlier in-memory engine existed")
        repairManager.bundledDirectoryForChecks = model.deletingLastPathComponent()
        await repairManager.importModel(url: model)
        try expect(repairManager.ready, "explicit base import also repairs corrupt cached VAD from bundle")
        try OfflineResource.validate(repairCache.appendingPathComponent(OfflineResource.vad.name), resource: .vad)
        #endif
        let controller = AudioController(modelManager: manager)
        let initialPhase = controller.phase
        try expect(initialPhase == .ready, "new controller never starts capture")
        try expect(controller.playbackPosition == nil, "new controller playback position is absent and no audio is started")
        controller.stopPlayback()
        try expect(controller.playbackPosition == nil && !controller.playbackPaused, "explicit stop clears playback position without playing")
        controller.pausePlayback(); try controller.resumePlayback()
        try expect(controller.playbackPosition == nil && !controller.playbackPaused, "pause/resume with no selected recording remains silent and idle")
        var changed = AudioConfiguration(); changed.language = "ja"
        await controller.configure(changed)
        let configuredPhase = controller.phase
        try expect(configuredPhase == .paused, "configuration change stays paused")
        #if AUDIO_TESTING
        var deliveredTexts = 0, deliveredRecordings = 0
        controller.onConfirmed = { _ in deliveredTexts += 1 }
        controller.onRecording = { _ in deliveredRecordings += 1 }
        let lateTap = try await controller.beginSilentReplayForCheck(samples: speech, recordingDirectory: out.appendingPathComponent("controller-explicit-recording"))
        // Concurrent lifecycle requests must share one drain and one delivery barrier.
        let firstPause = Task { await controller.pause() }, secondPause = Task { await controller.pause() }
        await firstPause.value; await secondPause.value
        try expect(deliveredTexts > 0 && deliveredRecordings > 0 && !controller.draining, "controller pause waits for actual main-queue confirmed and recording callbacks")
        let finalTextCount = deliveredTexts, finalRecordingCount = deliveredRecordings
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let silenceFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
                let lateBuffer = AVAudioPCMBuffer(pcmFormat: silenceFormat, frameCapacity: 1600)!; lateBuffer.frameLength = 1600
                lateBuffer.floatChannelData![0].initialize(repeating: 0, count: 1600)
                for _ in 0..<100 { lateTap(lateBuffer) }
                continuation.resume()
            }
        }
        await controller.pause()
        try expect(deliveredTexts == finalTextCount && deliveredRecordings == finalRecordingCount && !controller.draining, "actual tap callback rejects stale frames after concurrent pause without locking main queue")
        #endif
        await controller.end()
        var endedRejected = false
        do { try await controller.start(sessionID: "ended-test", elapsedOffset: 0, recordingDirectory: nil) } catch { endedRejected = true }
        try expect(endedRejected, "ended controller rejects capture before any permissions")
        let bad = out.appendingPathComponent("corrupt-model.bin"); try Data("not a model".utf8).write(to: bad)
        var rejected = false; do { try OfflineResource.validate(bad, resource: .base) } catch { rejected = true }
        try expect(rejected, "corrupt resource cannot become ready")
        rejected = false; do { _ = try ASREngine(model: bad, vad: vad) } catch { rejected = true }
        try expect(rejected, "actual engine load rejects malformed model")
        let invalidDir = out.appendingPathComponent("not-directory"); try Data("x".utf8).write(to: invalidDir)
        rejected = false; do { _ = try AudioRecordingWriter(directory: invalidDir, session: "test", epoch: "test", offset: 0) { _ in } } catch { rejected = true }
        try expect(rejected, "actual recording creation failure surfaces")
        let report: [String: Any] = ["date": ISO8601DateFormatter().string(from: Date()), "evidence": "production Swift PCM segmentation + pinned C++ engine, silent replay of project-created fictional Kokoro speech FLACs; no hardware capture, permission prompt, playback or provider request", "results": results, "checks": ["pinned model hashes", "real model and VAD load", "both languages raw transcription", "digital silence empty", "provisional replacement", "tail finalization", "end terminal/idempotent", "monotonic bounded timestamps", "overload explicit gaps", "optional recording real write/readback", "corrupt model failure", "invalid recording path rejection", "missing/imported model true readiness", "configuration stays paused", "ended controller rejects explicit start before permissions", "corrupt base/VAD cache repaired from verified bundle and preserved", "base import repairs bad VAD cache", "playback position idle/stop safe", "pause/resume without a player remains silent", "real CaptureSink worker callback silent replay", "concurrent pause shares one delivery barrier", "100 stale tap callbacks rejected after pause"], "qualityAcceptance": "pending; outputs are unmodified, reference text never supplied to decoder", "externalProviderRequests": 0]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("audio-results.json"), options: .atomic)
        print("Audio pipeline engineering checks passed; quality requires separate review. \(out.path)")
    }
}
