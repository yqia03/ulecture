import Foundation
import AVFoundation
import AppKit

private struct OnlineCheckFailure: Error { let message: String }
@MainActor private func demand(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw OnlineCheckFailure(message: message) }
}

private final class MemoryCredentials: CloudCredentialStore {
    var values: [String: String] = [:], reads = 0
    func save(_ value: String, reference: String) throws { values[reference] = value }
    func read(reference: String) throws -> String? { reads += 1; return values[reference] }
    func remove(reference: String) throws { values[reference] = nil }
    func contains(reference: String) throws -> Bool { values[reference] != nil }
}

private final class NoLegacyCloudRequest: URLProtocol {
    static let lock = NSLock()
    private static var count = 0
    static var requests: Int { lock.lock(); defer { lock.unlock() }; return count }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); Self.count += 1; Self.lock.unlock()
        client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet))
    }
    override func stopLoading() { }
}

private actor OnlineBackend: AudioCaptureBackend {
    var starts = 0
    private var request: UUID?
    private var receiver: (@Sendable (AVAudioPCMBuffer) -> Void)?
    func requestPermission(for source: AudioSource) async throws { }
    func prepare(requestID: UUID) async throws { request = requestID }
    func start(requestID: UUID, configuration: AudioConfiguration, receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void, failed: @escaping @Sendable (String) -> Void) async throws {
        guard request == requestID else { throw CancellationError() }; starts += 1; receiver = receive
    }
    func stop() async throws { request = nil }
    func microphoneHealth(configuration: AudioConfiguration) async -> String? { nil }
    func emit(seconds: Double = 0.05) { receiver?(Self.pcm(seconds: seconds)) }
    nonisolated static func pcm(seconds: Double) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        let frames = AVAudioFrameCount(48_000 * seconds)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)!; pcm.frameLength = frames
        for channel in 0..<2 { pcm.floatChannelData![channel].initialize(repeating: 0, count: Int(frames)) }
        return pcm
    }
}

@MainActor private final class OnlinePlayer: InterpretationAudioPlaying {
    var enabled = true, volume: Float = 0.8
    var onPlayed: ((Double) -> Void)?, onSkipped: ((Double) -> Void)?
    var generation: UUID?, enqueues = 0, stops = 0
    func begin(generation: UUID) { self.generation = generation }
    func enqueue(_ data: Data, sampleRate: Int, channels: Int, generation: UUID) throws {
        guard self.generation == generation, enabled else { return }; enqueues += 1
        onPlayed?(Double(data.count) / Double(sampleRate * channels * 2))
    }
    func stop() { generation = nil; stops += 1 }
}

@MainActor private final class OnlineSession: InterpretationSession {
    let provider: InterpretationProvider
    var onEvent: ((InterpretationSessionEvent) -> Void)?
    var inputFormat: InterpretationPCMFormat { provider.inputFormat }
    var inputChunkMilliseconds: Int { provider.inputChunkMilliseconds }
    var sent: [Data] = [], starts = 0, finishes = 0, aborts = 0
    var blockHandshake = false, failure: InterpretationFailure?
    var expiresAt: Date?
    var handshake: CheckedContinuation<Void, Error>?
    var onFinish: (() -> Void)?
    private var sequence: UInt64 = 0
    init(_ provider: InterpretationProvider) { self.provider = provider }
    func start(configuration: InterpretationSessionConfiguration, apiKey: String) async throws {
        starts += 1
        try demand(configuration.provider == provider && apiKey == "fixture-only", "authorization changed")
        if let failure { throw failure }
        if blockHandshake { try await withCheckedThrowingContinuation { handshake = $0 } }
        emit(.ready(sessionID: "fixture", expiresAt: expiresAt))
    }
    func sendAudio(_ pcm16: Data) async throws { sent.append(pcm16) }
    func finish() async -> InterpretationFinishResult {
        finishes += 1
        if let handshake { self.handshake = nil; handshake.resume(throwing: InterpretationFailure.cancelled) }
        onFinish?()
        return .init(reason: provider == .openAI ? .protocolClosed : .generationBoundary, tailMayBeIncomplete: provider == .google)
    }
    func abort() { aborts += 1; if let handshake { self.handshake = nil; handshake.resume(throwing: InterpretationFailure.cancelled) } }
    func emit(_ payload: InterpretationSessionEvent.Payload, id: String? = nil, elapsed: Int? = nil) {
        sequence += 1
        onEvent?(.init(eventID: id, sequence: sequence, elapsedMS: elapsed, receivedAt: Date(), payload: payload))
    }
}

@MainActor private final class OnlineFixture {
    let library: LibraryStore, credentials = MemoryCredentials(), backend = OnlineBackend(), capture: AudioCaptureSession
    let settings: InterpretationServiceSettings, player = OnlinePlayer(), sessionID: String
    let defaults: UserDefaults
    var sessions: [OnlineSession] = [], customize: ((OnlineSession, Int) -> Void)?
    var gaps: [AudioGap] = []
    var run: InterpretationOnlineRun!
    init(root: URL) throws {
        let suite = "online-tests-" + UUID().uuidString
        defaults = UserDefaults(suiteName: suite)!
        library = try LibraryStore(rootURL: root.appendingPathComponent("library"))
        try library.configureTranscriptStorage(rootURL: root.appendingPathComponent("transcripts"))
        sessionID = try library.createStandaloneSession(title: "Online fixture").id
        capture = AudioCaptureSession(backend: backend, coordinator: CaptureSessionCoordinator())
        let mainAI = CloudServiceSettings(credentials: credentials, defaults: defaults)
        settings = InterpretationServiceSettings(mainAI: mainAI, credentials: credentials, defaults: defaults)
        for provider in InterpretationProvider.allCases { try settings.saveCredential("fixture-only", for: provider) }
        run = InterpretationOnlineRun(library: library, capture: capture, settings: settings, factory: { [unowned self] provider in
            let next = OnlineSession(provider); self.customize?(next, self.sessions.count); self.sessions.append(next); return next
        }, player: player, retryDelay: { _ in 0.001 })
        capture.onPhaseChanged = { [weak run] phase in run?.capturePhaseChanged(phase) }
        capture.onGap = { [weak self] in self?.gaps.append($0) }
    }
    func start(_ provider: InterpretationProvider) async {
        await run.start(sessionID: sessionID, mode: provider == .google ? .googleOnline : .openAIOnline,
            sourceLanguage: "en", targetLanguage: "zh-Hant", offset: capture.currentOffset, recordingDirectory: nil)
    }
    func feed(seconds: Double = 0.05) async { await backend.emit(seconds: seconds); await capture.captureBarrierForChecks(); await Task.yield() }
}

@main struct OnlineInterpretationChecks {
    @MainActor static func wait(_ label: String, _ predicate: () -> Bool) async throws {
        for _ in 0..<300 { if predicate() { return }; try await Task.sleep(nanoseconds: 5_000_000) }
        throw OnlineCheckFailure(message: label)
    }
    @MainActor static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1])
        for provider in InterpretationProvider.allCases {
            try await lifecycle(provider, root: output.appendingPathComponent(provider.rawValue))
        }
        try await cancelledHandshake(root: output.appendingPathComponent("handshake"))
        try await recovery(root: output.appendingPathComponent("recovery"))
        try await rotationBounds(root: output.appendingPathComponent("rotation"))
        try await storageFailure(root: output.appendingPathComponent("storage"))
        try await externalStorageFailure(root: output.appendingPathComponent("external-storage"))
        try await generationBound(root: output.appendingPathComponent("generation-bound"))
        try await captionSequenceBound(root: output.appendingPathComponent("caption-sequence-bound"))
        try await pumpBounds()
        try await controllerGates(root: output.appendingPathComponent("controller"))
        let report: [String: Any] = ["providers": ["google", "openAI"], "networkRequests": 0,
            "source": "injected 48k stereo silence", "normalEndDrainsPartialPCM": true, "pauseDiscardsPartialPCM": true,
            "lateEventsRejected": true, "historyNoCredentialRead": true, "retryLimit": 3, "unknownModelEstimate": "absent",
            "usageObservationsPreserved": true, "saveFailureStopsCapture": true, "physicalPlaybackTested": false,
            "actualControllerOnlineRouting": true, "legacyCloudRequests": NoLegacyCloudRequest.requests,
            "realProviderAcceptance": false, "generationAndCaptionSequenceBounds": true]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("online-interpretation.json"))
        print("PASS: online orchestration both providers, native PCM tail, captions, pause/resume/end, history, bounded retry and backpressure, save failure")
    }
    @MainActor static func generationBound(root: URL) async throws {
        let f = try OnlineFixture(root: root)
        var runtime = InterpretationRuntimeRecord(sessionID: f.sessionID)
        runtime.generation = Int.max; runtime.modelID = f.settings.profile(for: .google).modelID; runtime.state = "paused"; runtime.startedAt = Date()
        try f.library.saveInterpretationRuntime(runtime)
        try await f.run.load(sessionID: f.sessionID)
        await f.start(.google)
        try demand(f.run.state == .failed && f.run.errorCode == InterpretationFailure.invalidConfiguration.localizedDescription && f.sessions.isEmpty, "exhausted generation counter connected or overflowed")
    }
    @MainActor static func captionSequenceBound(root: URL) async throws {
        let exhausted = try OnlineFixture(root: root.appendingPathComponent("recovered"))
        var row = InterpretationCaptionRecord(sessionID: exhausted.sessionID, generation: 0, track: "source", text: "Recovered source", language: "en", receivedAtMS: 0)
        row.sequence = UInt64.max - 1
        try exhausted.library.saveInterpretationCaption(row)
        try await exhausted.run.load(sessionID: exhausted.sessionID)
        await exhausted.start(.google)
        try demand(exhausted.run.state == .failed && exhausted.sessions.isEmpty, "unrepresentable recovered caption sequence connected")
        let f = try OnlineFixture(root: root.appendingPathComponent("last-admissible"))
        row.id = UUID().uuidString; row.sessionID = f.sessionID; row.sequence = UInt64(Int64.max) - 1
        try f.library.saveInterpretationCaption(row)
        try await f.run.load(sessionID: f.sessionID)
        await f.start(.google)
        try demand(f.run.state == .running, "last representable caption sequence could not start")
        f.sessions[0].emit(.transcript(track: .source, text: "Last admissible source", isFinal: true, languageCode: "en"), id: "last-admissible")
        f.sessions[0].emit(.transcript(track: .source, text: "Must stop before overflow", isFinal: true, languageCode: "en"), id: "past-limit")
        try demand(f.run.captions.last?.sequence == UInt64(Int64.max) && f.run.captions.last?.text == "Last admissible source" && f.run.state != .running, "caption sequence overflow or unordered extra source admitted")
        await f.run.end()
    }
    @MainActor static func lifecycle(_ provider: InterpretationProvider, root: URL) async throws {
        let f = try OnlineFixture(root: root)
        // No ModelManager or ASR engine is supplied to this complete online path.
        await f.start(provider)
        try demand(f.run.state == .running && f.sessions.count == 1, "online start failed without ASR")
        let first = f.sessions[0]
        for _ in 0..<5 { await f.feed() }
        first.emit(.transcript(track: .translation, text: "翻译", isFinal: nil, languageCode: nil), id: "t1", elapsed: 200)
        first.emit(.transcript(track: .translation, text: "重复", isFinal: nil, languageCode: nil), id: "t1", elapsed: 200)
        first.emit(.transcript(track: .translation, text: "完成", isFinal: nil, languageCode: nil), id: "t2", elapsed: 200)
        first.emit(.transcript(track: .source, text: "hello", isFinal: nil, languageCode: nil), id: "s1")
        first.emit(.transcript(track: .source, text: "", isFinal: true, languageCode: nil), id: "source-final")
        first.emit(.transcript(track: .source, text: "", isFinal: true, languageCode: nil), id: "empty-no-row")
        try demand(f.run.captions.filter { $0.track == "source" }.count == 1 && f.run.captions.last?.isFinal == true, "empty final lost or created empty caption")
        first.emit(.audio(Data(repeating: 0, count: 480), .translatedAudio), id: "audio1")
        try demand(f.run.targetCaption == "翻譯完成" && f.run.sourceCaption == "hello", "dedup/script transformation or independent captions failed")
        try demand(f.player.enqueues == 1, "online audio did not reach player")
        first.emit(.interrupted, id: "interrupt-caption")
        first.emit(.transcript(track: .source, text: "next source", isFinal: nil, languageCode: nil), id: "source-after-interrupt")
        first.emit(.transcript(track: .translation, text: "新译文", isFinal: nil, languageCode: nil), id: "translation-after-interrupt")
        try demand(f.run.captions.filter { $0.track == "source" }.count == 2 && f.run.captions.filter { $0.track == "translation" }.count == 2, "interruption merged different caption fragments")
        try demand(f.run.captions.first(where: { $0.track == "translation" })?.completionBasis == "interrupted", "interrupted partial was falsely finalized")
        f.run.speechEnabled = false
        first.emit(.audio(Data(repeating: 0, count: 480), .translatedAudio), id: "muted-audio")
        for sequence in 1...130 { first.emit(.usage(.init(inputTokens: sequence, outputTokens: sequence * 2, totalTokens: sequence * 3)), id: "usage-\(sequence)") }
        await f.run.pause()
        let sentAtPause = first.sent.reduce(0) { $0 + $1.count }, captionsAtPause = f.run.captions
        try demand(f.run.state == .paused && first.finishes == 1 && f.player.generation == nil, "pause failed")
        try demand(f.gaps.contains { $0.reason == "online-unsent-audio-discarded" }, "paused partial input was not recorded as gap")
        await f.feed()
        first.emit(.transcript(track: .source, text: "late", isFinal: nil, languageCode: nil), id: "late-source")
        first.emit(.audio(Data(repeating: 0, count: 480), .translatedAudio), id: "late-audio")
        try demand(first.sent.reduce(0) { $0 + $1.count } == sentAtPause && f.run.captions == captionsAtPause && f.player.enqueues == 1, "paused callbacks escaped")
        let usage = try f.library.interpretationUsage(sessionID: f.sessionID)[0]
        try demand(usage.generatedSeconds > usage.playedSeconds && usage.inputTokens == nil, "mute changed generation accounting or unknown cumulative values summed")
        try demand(usage.observationCount == 130 && usage.observations?.count == 128 && usage.observations?.first?.inputTokens == 3, "raw usage observations not bounded/preserved")
        try demand(f.run.captions.first?.providerElapsedMS == 200, "provider offset not retained independently")
        let originalBytes = first.sent.reduce(0) { $0 + $1.count }
        await f.start(provider)
        let second = f.sessions[1]
        for _ in 0..<5 { await f.feed() }
        second.onFinish = {
            second.emit(.transcript(track: .translation, text: "尾部", isFinal: nil, languageCode: nil), id: "end-tail")
            second.emit(.audio(Data(repeating: 0, count: 480), .translatedAudio), id: "end-audio")
        }
        await f.run.end()
        let endedBytes = second.sent.reduce(0) { $0 + $1.count }
        try demand(abs(endedBytes - provider.inputFormat.bytesPerSecond / 4) <= 128, "normal end lost converter or partial PCM tail: \(endedBytes)")
        try demand(second.sent.last!.count < provider.inputFormat.bytesPerSecond * provider.inputChunkMilliseconds / 1000, "normal end did not send partial final chunk")
        try demand(endedBytes > originalBytes && f.run.state == .ended && f.run.targetCaption == "尾部", "end tail not persisted")
        try demand(f.player.enqueues == 1 && second.finishes == 1 && !f.run.hasUnsavedContent, "end played audio or duplicated close")
        let reads = f.credentials.reads, connections = f.sessions.count
        try await f.run.load(sessionID: f.sessionID)
        await f.start(provider)
        try demand(f.run.state == .ended && f.credentials.reads == reads && f.sessions.count == connections, "history automatically connected or ended record resumed")
    }
    @MainActor static func cancelledHandshake(root: URL) async throws {
        let f = try OnlineFixture(root: root)
        f.customize = { session, index in session.blockHandshake = index == 0 }
        let start = Task { @MainActor in await f.start(.google) }
        try await wait("handshake fixture never blocked") { f.sessions.first?.handshake != nil }
        await f.run.pause(); await start.value
        let hardwareStarts = await f.backend.starts
        try demand(f.run.state == .paused && f.run.errorCode == nil && hardwareStarts == 0, "pause during handshake became failed or started hardware")
        await f.start(.google)
        try demand(f.run.state == .running && f.sessions.count == 2, "resume after cancelled handshake failed")
        await f.run.end()
    }
    @MainActor static func recovery(root: URL) async throws {
        let f = try OnlineFixture(root: root)
        try f.settings.updateModel("future-translation-v2", for: .openAI)
        f.customize = { session, index in if index > 0 { session.failure = .connectionLost } }
        await f.start(.openAI)
        f.sessions[0].emit(.failure(.connectionLost))
        try await wait("retries did not stop") { f.run.state == .failed && !f.capture.draining }
        try demand(f.sessions.count == 4 && !f.capture.ownsCaptureLease, "retry budget exceeded or lease leaked")
        try demand(f.run.usage.allSatisfy { $0.estimatedCostUSD == nil }, "unknown advanced model received default-model price")
    }
    @MainActor static func storageFailure(root: URL) async throws {
        let f = try OnlineFixture(root: root)
        await f.start(.openAI)
        f.library.onSessionPersisted = { _ in throw OnlineCheckFailure(message: "fixture write failure") }
        f.sessions[0].emit(.transcript(track: .source, text: "preserve unsaved", isFinal: nil, languageCode: nil), id: "save-fault")
        try await wait("save fault did not stop") { f.run.state == .failed && !f.capture.draining }
        try demand(f.run.errorCode == "online.storage" && f.run.hasUnsavedContent && f.player.generation == nil && !f.capture.ownsCaptureLease, "save failure lost dirty data or left capture running")
        f.library.onSessionPersisted = nil; await f.run.retrySave()
        let persisted = try f.library.interpretationCaptions(sessionID: f.sessionID)
        try demand(!f.run.hasUnsavedContent && persisted.last?.text == "preserve unsaved", "save retry lost caption")
        let savedUsage = try f.library.interpretationUsage(sessionID: f.sessionID)
        try demand(savedUsage.last?.status == "interrupted" && persisted.last?.completionBasis == "interrupted" && f.run.runtime?.closeComplete == false, "storage failure retained running metadata")
    }
    @MainActor static func rotationBounds(root: URL) async throws {
        let nearExpiry = try OnlineFixture(root: root.appendingPathComponent("expired"))
        nearExpiry.customize = { session, _ in session.expiresAt = Date().addingTimeInterval(5) }
        await nearExpiry.start(.openAI)
        try demand(nearExpiry.run.state == .failed && nearExpiry.sessions.count == 1, "near-expired session caused immediate reconnect loop")
        let f = try OnlineFixture(root: root.appendingPathComponent("go-away"))
        await f.start(.google)
        for expectedCount in 2...4 {
            f.sessions.last!.emit(.connectionWillClose(seconds: 0))
            try await wait("planned rotation failed") { f.run.state == .running && f.sessions.count == expectedCount }
        }
        f.sessions.last!.emit(.connectionWillClose(seconds: 0))
        try await wait("planned rotations not capped") { f.run.state == .failed && !f.capture.draining }
        try demand(f.sessions.count == 4 && !f.capture.ownsCaptureLease, "GoAway created unlimited billable sessions")
    }
    @MainActor static func externalStorageFailure(root: URL) async throws {
        let f = try OnlineFixture(root: root)
        await f.start(.openAI); await f.feed()
        f.capture.onGap = { [weak run = f.run] _ in run?.handlePersistenceFailure() }
        f.run.handlePersistenceFailure()
        try await wait("external write failure did not drain") { !f.capture.draining }
        let frozen = f.run.usage.last?.connectionSeconds
        try await Task.sleep(nanoseconds: 20_000_000)
        await f.run.retrySave()
        try demand(f.run.state == .failed && f.run.usage.last?.connectionSeconds == frozen && !f.run.hasUnsavedContent, "recursive parent storage failure escaped barrier or extended billable clock")
    }
    @MainActor static func pumpBounds() async throws {
        var postStopSends = 0
        let immediatelyStopped = InterpretationAudioPump(provider: .google, send: { _ in postStopSends += 1 }, failed: { _ in })
        let queuedFrame = try CapturedAudioFrame.copy(OnlineBackend.pcm(seconds: 0.3), epochID: "immediate", sequence: 1)
        _ = immediatelyStopped.append(queuedFrame)
        immediatelyStopped.stop()
        await Task.yield(); await Task.yield()
        try demand(postStopSends == 0, "pause barrier let a scheduled pump begin transport.send")
        var waiter: CheckedContinuation<Void, Never>?, failures: [InterpretationFailure] = [], sends = 0
        let pump = InterpretationAudioPump(provider: .google, send: { _ in
            sends += 1; await withCheckedContinuation { waiter = $0 }
        }, failed: { failures.append($0) })
        let frame = try CapturedAudioFrame.copy(OnlineBackend.pcm(seconds: 0.1), epochID: "fixture", sequence: 1)
        _ = pump.append(frame); _ = pump.append(frame)
        try await wait("pump did not begin send") { waiter != nil }
        for _ in 0..<30 { _ = pump.append(frame) }
        try await wait("pump overflow not reported") { !failures.isEmpty }
        let finished = await pump.finish(timeout: 0.01)
        try demand(!finished && failures == [.bufferOverflow] && sends == 1, "queue/finish wait was unbounded")
        waiter?.resume(); waiter = nil; await Task.yield()
        try demand(sends == 1, "queued audio uploaded after pump stop")
    }

    @MainActor static func controllerGates(root: URL) async throws {
        _ = NSApplication.shared; NSApp.setActivationPolicy(.accessory)
        let library = try LibraryStore(rootURL: root.appendingPathComponent("library"))
        try library.configureTranscriptStorage(rootURL: root.appendingPathComponent("transcripts"))
        let credentials = MemoryCredentials(), defaults = UserDefaults(suiteName: "controller-" + UUID().uuidString)!
        let network = URLSessionConfiguration.ephemeral; network.protocolClasses = [NoLegacyCloudRequest.self]
        let urlSession = URLSession(configuration: network)
        let settings = CloudServiceSettings(credentials: credentials, session: urlSession, defaults: defaults)
        let interpretation = InterpretationServiceSettings(mainAI: settings, credentials: credentials, defaults: defaults)
        for provider in InterpretationProvider.allCases { try interpretation.saveCredential("fixture-only", for: provider) }
        let models = ModelManager(cacheDirectory: root.appendingPathComponent("missing-model-cache"))
        models.bundledDirectoryForChecks = root.appendingPathComponent("missing-model-bundle")
        var downloads = 0
        models.downloadForChecks = { _ in downloads += 1; throw OnlineCheckFailure(message: "ASR download forbidden") }
        await models.restoreAtLaunch()
        let backend = OnlineBackend(), localBackend = OnlineBackend(), player = OnlinePlayer()
        var sessions: [OnlineSession] = []
        let controller = InterpretationController(library: library, models: models, settings: settings, backend: localBackend,
            coordinator: CaptureSessionCoordinator(), defaults: defaults, cloudSession: urlSession, interpretationSettings: interpretation,
            onlineBackend: backend, sessionFactory: { provider in let value = OnlineSession(provider); sessions.append(value); return value }, onlinePlayer: player)
        for mode in [InterpretationMode.googleOnline, .openAIOnline] {
            if controller.selected != nil { await controller.newSession(title: "Switchable new draft") }
            await controller.setMode(mode)
            if controller.selected == nil { await controller.newSession(title: "Controller online") }
            let selected = controller.selected!.id
            await controller.start()
            try demand(controller.online.state == .running && controller.cloud == nil && controller.modeLocked && models.engine == nil && !models.ready, "controller routed online through legacy pipeline")
            await backend.emit(seconds: 0.25); await controller.capture.captureBarrierForChecks()
            let active = sessions.last!
            active.emit(.transcript(track: .source, text: "source", isFinal: nil, languageCode: nil), id: "controller-source")
            active.emit(.transcript(track: .translation, text: "在线译文", isFinal: nil, languageCode: nil), id: "controller-target")
            controller.audio.onConfirmed?(.init(id: UUID().uuidString, sessionID: selected, epochID: UUID().uuidString,
                language: "en", text: "stale local ASR", sequence: 1, revision: 1, start: 0, end: 1, confirmedAt: Date()))
            await controller.pause()
            await controller.setMode(.localSpeechText)
            try demand(controller.mode == mode && controller.error == "onlineNewSessionRequired", "started mode was not locked")
            await controller.configure(controller.capture.configuration, targetLanguage: "zh-Hant")
            try demand(controller.targetLanguage == "zh-Hans" && controller.error == "onlineNewSessionRequired", "started target was not locked")
            if mode == .googleOnline {
                library.onSessionPersisted = { _ in throw OnlineCheckFailure(message: "end checkpoint fixture failure") }
                await controller.end()
                try demand(controller.hasUnsavedContent, "failed end checkpoint claimed complete saving")
                library.onSessionPersisted = nil
                await controller.retryUnsaved()
                try demand(controller.online.state == .ended && controller.online.runtime?.state == "ended", "end retry did not finish online runtime")
            } else { await controller.end() }
            try await Task.sleep(nanoseconds: 30_000_000)
            let finalStoredRecord = try library.classroom(id: selected)
            try demand(controller.record?.state == "ended" && finalStoredRecord?.state == "ended" && !controller.hasUnsavedContent, "late capture phase overwrote ended session state")
            guard let transcriptURL = controller.transcriptFileURL else { throw OnlineCheckFailure(message: "No TXT file location for Finder") }
            try demand(transcriptURL == controller.saveLocation?.appendingPathComponent("transcript.txt"), "Finder target is not the selected session's TXT file")
            let savedText = try String(contentsOf: transcriptURL, encoding: .utf8)
            let bilingualText = try String(contentsOf: transcriptURL.deletingLastPathComponent().appendingPathComponent("transcript-bilingual.txt"), encoding: .utf8)
            try demand(savedText.contains("source") && !savedText.contains("在线译文") && bilingualText.contains("在线译文") && bilingualText.contains("source"), "Online original and bilingual TXT differ from their saved tracks")
            let reads = credentials.reads, connections = sessions.count
            // Saved old records must not be re-enqueued when an online history
            // row is opened, retried or its settings are changed.
            try library.saveTranscript(.init(id: UUID().uuidString, classroomID: selected, epochID: UUID().uuidString,
                startMS: 0, endMS: 1000, text: "legacy historical source", language: "en", revision: 1, confirmedAt: Date()))
            await controller.selectSession(selected)
            await controller.retryUnsaved(); await controller.retryTranslation("fixture-job"); await controller.setTranslationPaused(false)
            try settings.selectProvider(.openAI); try settings.updateModel("gpt-4o")
            await controller.configure(controller.capture.configuration, targetLanguage: "zh-Hant")
            await controller.start()
            let jobs = try library.record(collection: "cloud-state", id: selected, as: CloudState.self)?.jobs ?? []
            try demand(controller.record?.state == "ended" && controller.cloud == nil && jobs.isEmpty && sessions.count == connections && credentials.reads == reads && NoLegacyCloudRequest.requests == 0,
                "history/retry/config restored legacy queue or contacted services")
        }
        let localStarts = await localBackend.starts
        try demand(downloads == 0 && localStarts == 0 && models.engine == nil && !FileManager.default.fileExists(atPath: models.cacheDirectory.path), "controller touched local ASR or its model cache")
        let prepared = await controller.prepareForExit()
        try demand(prepared, "controller exit lost online data")
        urlSession.invalidateAndCancel()
    }
}
