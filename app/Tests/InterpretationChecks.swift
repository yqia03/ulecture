import Foundation
import AppKit
import AVFoundation

private final class EmptyCheckCredentials: CloudCredentialStore {
    var reads = 0
    func save(_ value: String, reference: String) throws { throw CloudFailure.authentication }
    func read(reference: String) throws -> String? { reads += 1; return nil }
    func remove(reference: String) throws { }
}
private final class NoRequestProtocol: URLProtocol {
    private static let lock = NSLock()
    private static var count = 0
    static var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.lock.lock(); Self.count += 1; Self.lock.unlock(); client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() { }
}
private actor InterpretationSilentBackend: AudioCaptureBackend {
    var permissions = 0, starts = 0, stops = 0
    var receiver: (@Sendable (AVAudioPCMBuffer) -> Void)?
    var token: UUID?
    func requestPermission(for source: AudioSource) async throws { permissions += 1 }
    func prepare(requestID: UUID) async throws { token = requestID }
    func start(requestID: UUID, configuration: AudioConfiguration, receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void, failed: @escaping @Sendable (String) -> Void) async throws {
        guard token == requestID else { throw CancellationError() }; starts += 1; receiver = receive
    }
    func stop() async throws { stops += 1; token = nil }
    func microphoneHealth(configuration: AudioConfiguration) async -> String? { nil }
    func feed(_ samples: [Float]) async throws {
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        for start in stride(from: 0, to: samples.count, by: 1600) {
            let chunk = Array(samples[start..<min(start + 1600, samples.count)])
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.count))!
            buffer.frameLength = buffer.frameCapacity
            chunk.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: chunk.count) }
            receiver?(buffer)
            // Exercise the public receive boundary at its real PCM cadence.
            // An accelerated burst would correctly trip its two-second bound.
            try await Task.sleep(nanoseconds: UInt64(Double(chunk.count) / 16000 * 1_000_000_000))
        }
    }
}

@main struct InterpretationChecks {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), out = URL(fileURLWithPath: CommandLine.arguments[2]), mode = CommandLine.arguments[3]
        func require(_ value: Bool, _ reason: String) throws { if !value { throw AudioFailure.message(reason) } }
        let startTime = ProcessInfo.processInfo.systemUptime
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let suite = "local.ulecture.check." + cloudHash(out.path)
        let defaults = UserDefaults(suiteName: suite)!
        if mode == "create" { defaults.removePersistentDomain(forName: suite) }
        let library = try LibraryStore(rootURL: out.appendingPathComponent("catalog"))
        let transcriptRoot = out.appendingPathComponent("independent-transcripts")
        try library.configureTranscriptStorage(rootURL: transcriptRoot)
        let models = ModelManager(cacheDirectory: out.appendingPathComponent("models"))
        models.bundledDirectoryForChecks = root.appendingPathComponent("app/Resources/Models")
        let credentials = EmptyCheckCredentials()
        let urlConfig = URLSessionConfiguration.ephemeral; urlConfig.protocolClasses = [NoRequestProtocol.self]
        let session = URLSession(configuration: urlConfig)
        let settings = CloudServiceSettings(credentials: credentials, session: session, defaults: defaults)
        let backend = InterpretationSilentBackend(), coordinator = CaptureSessionCoordinator()
        let controller = InterpretationController(library: library, models: models, settings: settings, backend: backend, coordinator: coordinator, defaults: defaults, cloudSession: session)
        await controller.reloadSessions()
        var passed: [String] = []
        try require(InterpretationOnlineText.values.values.allSatisfy { $0.count == 4 && $0.allSatisfy { !$0.isEmpty } }, "Online interpretation requires four nonempty translations")
        for code in InterpretationFailure.allCases.map(\.localizedDescription) + ["interpretation.invalidRecord", "interpretation.untimedSubtitleExport", "mainAIUnsupportedProvider", "mainAIProviderMismatch", "onlineHandshakePassed", "online.captureInterrupted"] {
            for language in ["zh-Hans", "zh-Hant", "en", "ja"] { try require(InterpretationOnlineText.text(code, language: language) != code, "Untranslated online code: " + code) }
        }
        passed.append("online interpretation labels and diagnostic codes resolve in four languages")
        let initialPermissions = await backend.permissions, initialStarts = await backend.starts
        try require(initialPermissions == 0 && initialStarts == 0, "Constructing interpretation requested capture")
        try require(credentials.reads == 0 && NoRequestProtocol.requests == 0, "Opening interpretation read credentials or requested provider")
        passed.append("construction: zero capture, permission, secret reads or provider requests")
        if mode == "create" {
            await models.restoreAtLaunch()
            _ = try await models.ensureLoaded(); try require(models.ready, models.status)
            var config = AudioConfiguration(); config.source = .system; config.language = "en"; config.saveRecording = true
            await controller.configure(config, targetLanguage: "zh-Hant")
            await controller.newSession(title: "Independent silent engine check")
            guard let first = controller.selected else { throw AudioFailure.message(controller.error ?? "No session") }
            try require(first.courseID == nil && controller.record?.targetLanguage == "zh-Hant" && controller.record?.recordingEnabled == true && controller.audio.configuration.source == .system, "Draft configuration lost when creating independent session")
            controller.subtitles.updateFragment(CaptionFragment(id: "target-change-source", revision: 1, order: 0, text: "Source stays"))
            controller.subtitles.updateFragment(CaptionFragment(id: "target-change-source", revision: 1, order: 0, text: "舊譯文", sourceRevision: 1), translation: true)
            await controller.configure(config, targetLanguage: "zh-Hans")
            try require(controller.subtitles.translationBuffer.fragments.isEmpty && controller.subtitles.sourceBuffer.fragments.count == 1, "Changing translation target retained old-language text or cleared source")
            await controller.configure(config, targetLanguage: "zh-Hant")
            let firstDirectory = controller.saveLocation!
            try require(firstDirectory.path.hasPrefix(transcriptRoot.path + "/Standalone/") && FileManager.default.fileExists(atPath: firstDirectory.appendingPathComponent("session.sqlite").path), "Session is not in independent real database")
            try require(controller.cloud?.speech.enabled == false, "Speech enabled automatically")
            await controller.start()
            try require(controller.audio.phase == .capturing && coordinator.sessionID == first.id, controller.error ?? "Interpretation failed to acquire capture")
            let siblingBackend = InterpretationSilentBackend(), sibling = AudioController(modelManager: models, backend: siblingBackend, coordinator: coordinator)
            var rejected = false
            do { try await sibling.start(sessionID: "sibling", elapsedOffset: 0, recordingDirectory: nil) } catch { rejected = true }
            let siblingPermissions = await siblingBackend.permissions
            try require(rejected && siblingPermissions == 0, "Sibling reached permission before capture lease rejection")
            passed.append("independent session preserves chosen options; shared capture lease refuses sibling")

            controller.subtitles.display(source: "Source text", translation: "翻譯文字")
            controller.subtitles.update { $0.fontSize = 31; $0.sourceLines = 3; $0.translationLines = 4; $0.translationFirst = true; $0.red = 0.2; $0.green = 0.3; $0.blue = 0.4; $0.opacity = 0.55; $0.alwaysOnTop = true }
            if ProcessInfo.processInfo.environment["ULECTURE_SKIP_PANEL"] != "1" {
            let keyWindow = NSApp.keyWindow
            controller.subtitles.show()
            try require(controller.subtitles.isVisible && controller.subtitles.panel?.level == .floating && controller.subtitles.panel?.hidesOnDeactivate == false, "Native subtitle panel not persistent floating")
            try require(NSApp.keyWindow === keyWindow, "Showing subtitle stole key focus")
            controller.subtitles.panel?.performClose(nil)
            try require(!controller.subtitles.isVisible && controller.audio.phase == .capturing && coordinator.sessionID == first.id, "Closing captions changed capture")
            controller.subtitles.show(); controller.subtitles.panel?.setFrame(CGRect(x: 220, y: 180, width: 680, height: 230), display: true)
            controller.subtitles.update { $0.alwaysOnTop = false }
            try require(controller.subtitles.panel?.level == .normal && controller.audio.phase == .capturing, "Subtitle preference changed capture or did not change level")
            controller.subtitles.hide()
            } else { controller.subtitles.update { $0.alwaysOnTop = false } }
            let safe = SubtitlePanelController.constrainedFrame(CGRect(x: 99000, y: -5000, width: 6000, height: 4000), screens: [CGRect(x: 0, y: 0, width: 800, height: 600)])
            try require(safe == CGRect(x: 0, y: 0, width: 800, height: 600), "Off-screen restoration did not constrain panel")
            passed.append(ProcessInfo.processInfo.environment["ULECTURE_SKIP_PANEL"] == "1" ? "subtitle preferences and screen geometry only; native panel skipped to avoid concurrent UI testing" : "native NSPanel open/close/show, focus, level, geometry and preferences; close retains capture")

            let fixture = root.appendingPathComponent("app/Tests/Fixtures/Audio/fictional-lecture-en.flac")
            let originalFixtureHash = try LibraryStore.sha256(of: fixture)
            let samples = try AudioPCMConverter.readFile(fixture)
            try await backend.feed(samples)
            await controller.pause()
            try require(!controller.hasUnsavedContent && !controller.transcripts.isEmpty && !controller.recordings.isEmpty, "Actual ASR or recording failed: " + (controller.error ?? "no output"))
            try require(controller.transcripts.allSatisfy { $0.classroomID == first.id }, "Transcript assigned to wrong session")
            try require(try LibraryStore.sha256(of: fixture) == originalFixtureHash, "Source fixture was modified")
            for row in controller.recordings {
                let recordingURL = try library.attachmentURL(assetID: row.assetID)
                try require(recordingURL.path.hasPrefix(firstDirectory.appendingPathComponent("recordings").path), "Recording not stored beside independent session")
                let file = try AVAudioFile(forReading: recordingURL)
                try require(file.length > 0 && abs(Double(file.length) / file.processingFormat.sampleRate - Double(row.endMS - row.startMS) / 1000) < 0.1, "Recording metadata does not match actual PCM")
            }
            passed.append("actual ASR/VAD from public fictional FLAC via production start/backend receive/drain; transcript and real recorded PCM persisted")
            let transcriptCount = controller.transcripts.count
            try await backend.feed(Array(samples.prefix(3200)))
            try await Task.sleep(nanoseconds: 30_000_000)
            try require(controller.transcripts.count == transcriptCount && coordinator.owner == nil, "Late samples after pause escaped sink")
            await controller.setTranslationPaused(true)
            let course = try library.createItem(kind: .course, title: "Later associated course")
            await controller.associateCourse(course.id)
            try require(controller.selected?.id == first.id && controller.selected?.courseID == course.id && controller.saveLocation == firstDirectory, "Association duplicated identity or relocated transcript database")
            await controller.newSession(title: "Second independent session")
            guard let second = controller.selected else { throw AudioFailure.message("Missing second session") }
            await controller.selectSession(first.id)
            try require(controller.transcripts.count == transcriptCount && controller.cloud?.state.translationUserPaused == true && controller.audio.phase != .capturing, "Switching sessions lost data/pause intent or auto-started")
            passed.append("late samples ignored; association preserves id/directory; switching restores data and translation pause")

            // A real permissions failure at the independent root must keep the
            // callback in memory and block switching until it commits on retry.
            let missing = AudioTranscript(id: UUID().uuidString, sessionID: first.id, epochID: UUID().uuidString, language: "en", text: "Durable retry source", sequence: 50, revision: 1, start: 100, end: 102, confirmedAt: Date())
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o500)], ofItemAtPath: firstDirectory.path)
            controller.audio.onConfirmed?(missing)
            for _ in 0..<200 {
                if controller.error != nil { break }
                try await Task.sleep(nanoseconds: 10_000_000)
            }
            try require(controller.error != nil, "Expected durable storage failure did not reach the UI")
            try FileManager.default.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: firstDirectory.path)
            try require(controller.hasUnsavedContent, "Write failure claimed saved")
            await controller.selectSession(second.id)
            try require(controller.selected?.id == first.id, "Switched with unsaved source")
            await controller.retryUnsaved()
            try require(!controller.hasUnsavedContent && controller.transcripts.contains { $0.id == missing.id }, "Retry did not commit retained transcript")
            passed.append("real root permission failure retains source; blocks switch; retry commits once")
            await controller.end()
            try require(controller.record?.state == "ended", "End did not persist after tail")
            let startCount = await backend.starts
            await controller.start()
            try require(await backend.starts == startCount, "Ended interpretation restarted")
            await controller.selectSession(second.id)
            try require(controller.record?.state == "draft", "Viewing a new session changed draft state")
            let saved: [String: Any] = ["firstID": first.id, "secondID": second.id, "courseID": course.id, "firstDirectory": firstDirectory.path, "transcriptCount": controller.sessions.count]
            try JSONSerialization.data(withJSONObject: saved, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("saved-identities.json"))
            defaults.synchronize()
        } else {
            let facts = try JSONSerialization.jsonObject(with: Data(contentsOf: out.appendingPathComponent("saved-identities.json"))) as! [String: Any]
            let first = facts["firstID"] as! String, second = facts["secondID"] as! String
            try require(controller.sessions.count == 2 && controller.selected == nil && !models.ready, "Relaunch auto-selected/captured or lost sessions")
            await controller.selectSession(first)
            try require(controller.record?.state == "ended" && !controller.transcripts.isEmpty && !controller.recordings.isEmpty && controller.cloud?.state.translationUserPaused == true, "New process failed to restore ended data/pause")
            try require(controller.saveLocation?.path == facts["firstDirectory"] as? String && controller.selected?.courseID == facts["courseID"] as? String, "Association or actual directory changed across process")
            let p = controller.subtitles.preferences
            try require(p.fontSize == 31 && p.sourceLines == 3 && p.translationLines == 4 && p.translationFirst && p.red == 0.2 && p.green == 0.3 && p.blue == 0.4 && p.opacity == 0.55 && !p.alwaysOnTop, "Subtitle preference restore incomplete")
            try require(!controller.subtitles.isVisible && controller.cloud?.speech.enabled == false, "New process enabled subtitles or speech automatically")
            let restoredPermissions = await backend.permissions
            try require(credentials.reads == 0 && restoredPermissions == 0 && NoRequestProtocol.requests == 0, "Relaunch/restoring sessions contacted cloud/capture")
            await controller.selectSession(second)
            try require(controller.record?.state == "draft", "Selection altered fresh draft")
            passed.append("fresh process: real sessions/transcript/recording/association/pause and all subtitle preferences restored; zero permissions/secrets/cloud")
            defaults.removePersistentDomain(forName: suite)
        }
        try require(await controller.prepareForExit(), "Exit preparation claimed loss")
        try require(await models.unload(), "Test model did not release after capture drained")
        try require(NoRequestProtocol.requests == 0, "Test made provider request")
        let report: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "mode": mode, "checks": passed, "wallSeconds": ProcessInfo.processInfo.systemUptime - startTime, "actualHardwareCapture": false, "actualPermissionRequest": false, "playedSound": false, "providerRequests": NoRequestProtocol.requests, "credentials": "injected empty test store; real secret reads zero", "panelEvidence": "Native panel methods and window state, not cross-application mouse/fullscreen/multimonitor acceptance", "qualityAcceptance": "not assessed"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent(mode + ".json"))
        print("PASS: interpretation \(mode), \(passed.count) scenarios; no hardware capture, sound or provider requests")
    }
}
