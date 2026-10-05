import Foundation

/// Shared by settings tests and all production providers. No second handshake
/// starts while an earlier connection may still be generating billable output.
@MainActor final class InterpretationConnectionLease {
    static let shared = InterpretationConnectionLease()
    private var owner: UUID?
    func acquire(_ owner: UUID) throws {
        guard self.owner == nil else { throw InterpretationFailure.serviceBusy }
        self.owner = owner
    }
    func release(_ owner: UUID) { if self.owner == owner { self.owner = nil } }
}

@MainActor protocol InterpretationSession: AnyObject {
    var onEvent: ((InterpretationSessionEvent) -> Void)? { get set }
    var inputFormat: InterpretationPCMFormat { get }
    var inputChunkMilliseconds: Int { get }
    func start(configuration: InterpretationSessionConfiguration, apiKey: String) async throws
    func sendAudio(_ pcm16: Data) async throws
    func finish() async -> InterpretationFinishResult
    func abort()
}

@MainActor enum InterpretationSessionFactory {
    static func make(provider: InterpretationProvider) -> any InterpretationSession {
        switch provider {
        case .google: return GoogleInterpretationSession()
        case .openAI: return OpenAIInterpretationSession()
        }
    }
    /// Tests authentication and the actual translation configuration. No microphone or audio is sent.
    static func testConnection(configuration: InterpretationSessionConfiguration, apiKey: String,
        sessionFactory: @MainActor (InterpretationProvider) -> any InterpretationSession = { make(provider: $0) }) async throws {
        let session = sessionFactory(configuration.provider)
        defer { session.abort() }
        try await session.start(configuration: configuration, apiKey: apiKey)
        let result = await session.finish()
        if configuration.provider == .openAI {
            guard result.reason == .protocolClosed && !result.tailMayBeIncomplete else {
                throw result.reason == .timedOut ? InterpretationFailure.finishTimeout : .connectionLost
            }
        } else if result.reason == .failed || result.reason == .transportClosed || result.reason == .aborted {
            throw InterpretationFailure.connectionLost
        }
        // Google has no confirmed session-close acknowledgement. A successful
        // test confirms setup only; settings must label tail completeness unverified.
    }
}

@MainActor final class GoogleInterpretationSession: RealtimeInterpretationSession {
    init(transportFactory: @escaping @MainActor () -> any RealtimeTransport = { URLSessionRealtimeTransport() }, handshakeTimeout: TimeInterval = 15, finishTimeout: TimeInterval = 5) {
        super.init(provider: .google, transportFactory: transportFactory, handshakeTimeout: handshakeTimeout, finishTimeout: finishTimeout)
    }
}

@MainActor final class OpenAIInterpretationSession: RealtimeInterpretationSession {
    init(transportFactory: @escaping @MainActor () -> any RealtimeTransport = { URLSessionRealtimeTransport() }, handshakeTimeout: TimeInterval = 15, finishTimeout: TimeInterval = 5) {
        super.init(provider: .openAI, transportFactory: transportFactory, handshakeTimeout: handshakeTimeout, finishTimeout: finishTimeout)
    }
}

/// Shared connection lifecycle only. Provider codecs below deliberately use their
/// dedicated translation schemas; no conversation/response/VAD turn machinery.
@MainActor class RealtimeInterpretationSession: InterpretationSession {
    var onEvent: ((InterpretationSessionEvent) -> Void)?
    var inputFormat: InterpretationPCMFormat { provider.inputFormat }
    var inputChunkMilliseconds: Int { provider.inputChunkMilliseconds }
    private enum State { case idle, connecting, ready, finishing, closed }
    private let provider: InterpretationProvider
    private let transportFactory: @MainActor () -> any RealtimeTransport
    private let handshakeTimeout: TimeInterval
    private let finishTimeout: TimeInterval
    private var state: State = .idle
    private var configuration: InterpretationSessionConfiguration?
    private var transport: (any RealtimeTransport)?
    private var receiver: Task<Void, Never>?
    private var timer: Task<Void, Never>?
    private var audioSending = false
    private var audioSendWaiters: [CheckedContinuation<Void, Never>] = []
    private var handshake: CheckedContinuation<Void, Error>?
    private var finishWaiters: [CheckedContinuation<InterpretationFinishResult, Never>] = []
    private var finishResult: InterpretationFinishResult?
    private var generation: UInt64 = 0
    private var sequence: UInt64 = 0
    private var openAICreated = false
    private let lease = InterpretationConnectionLease.shared
    private let leaseID = UUID()

    init(provider: InterpretationProvider, transportFactory: @escaping @MainActor () -> any RealtimeTransport, handshakeTimeout: TimeInterval, finishTimeout: TimeInterval) {
        self.provider = provider; self.transportFactory = transportFactory
        self.handshakeTimeout = handshakeTimeout; self.finishTimeout = finishTimeout
    }

    func start(configuration: InterpretationSessionConfiguration, apiKey: String) async throws {
        guard state == .idle, configuration.provider == provider else { throw InterpretationFailure.invalidConfiguration }
        let config = try configuration.validated()
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { throw InterpretationFailure.missingCredential }
        guard key.utf8.count <= 16_384, !key.contains("\n"), !key.contains("\r") else { throw InterpretationFailure.invalidConfiguration }
        try Task.checkCancellation()
        self.configuration = config
        let request = try makeRequest(config: config, key: key)
        try lease.acquire(leaseID)
        let transport = transportFactory()
        self.transport = transport
        state = .connecting; generation &+= 1
        let current = generation
        try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                handshake = continuation
                armTimer(seconds: handshakeTimeout, generation: current) { [weak self] in self?.fail(.handshakeTimeout) }
                receiver = Task { [weak self] in
                    do {
                        try await transport.connect(request: request)
                        guard let self, self.isCurrent(current) else { return }
                        if self.provider == .google { try await self.sendJSON(self.googleSetup(config)) }
                        while self.isCurrent(current) && !Task.isCancelled {
                            let data = try await transport.receive()
                            guard self.isCurrent(current) else { return }
                            try await self.receive(data)
                        }
                    } catch {
                        guard let self, self.isCurrent(current) else { return }
                        if self.state == .finishing {
                            self.complete(.init(reason: .transportClosed, tailMayBeIncomplete: true))
                        } else { self.fail(InterpretationFailure.fromTransport(error)) }
                    }
                }
            }
        }, onCancel: { [weak self] in Task { @MainActor in self?.abort() } })
    }

    func sendAudio(_ pcm16: Data) async throws {
        guard state == .ready, let transport else { throw InterpretationFailure.cancelled }
        guard !audioSending else { throw InterpretationFailure.bufferOverflow }
        let limit = inputFormat.bytesPerSecond * inputChunkMilliseconds / 1000
        guard !pcm16.isEmpty, pcm16.count <= limit, pcm16.count % inputFormat.bytesPerFrame == 0 else { throw InterpretationFailure.audioFormat }
        let message: [String: Any]
        switch provider {
        case .google: message = ["realtimeInput": ["audio": ["data": pcm16.base64EncodedString(), "mimeType": "audio/pcm;rate=16000"]]]
        case .openAI: message = ["type": "session.input_audio_buffer.append", "audio": pcm16.base64EncodedString()]
        }
        let encoded = try JSONSerialization.data(withJSONObject: message)
        let current = generation
        audioSending = true
        do {
            // No intermediate unstructured task: a caller's pause barrier cannot
            // run between admission and the first transport send invocation.
            try await transport.send(encoded)
            if generation == current { completeAudioSend() }
        } catch {
            let failure = InterpretationFailure.fromTransport(error)
            if isCurrent(current) { completeAudioSend(); fail(failure) }
            throw failure
        }
    }

    func finish() async -> InterpretationFinishResult {
        if let finishResult { return finishResult }
        guard state == .ready || state == .finishing else {
            abort(); return finishResult ?? .init(reason: .aborted, tailMayBeIncomplete: true)
        }
        return await withCheckedContinuation { continuation in
            finishWaiters.append(continuation)
            guard state != .finishing else { return }
            state = .finishing
            let current = generation
            armTimer(seconds: finishTimeout, generation: current) { [weak self] in
                self?.complete(.init(reason: .timedOut, tailMayBeIncomplete: true))
            }
            Task { [weak self] in
                do {
                    await self?.waitForAudioSend()
                    guard let self, self.isCurrent(current), self.state == .finishing else { return }
                    switch self.provider {
                    case .google: try await self.sendJSON(["realtimeInput": ["audioStreamEnd": true]])
                    case .openAI: try await self.sendJSON(["type": "session.close"])
                    }
                } catch {
                    guard let self, self.isCurrent(current) else { return }
                    self.complete(.init(reason: .transportClosed, tailMayBeIncomplete: true))
                }
            }
        }
    }

    func abort() {
        guard state != .closed else { return }
        complete(.init(reason: .aborted, tailMayBeIncomplete: true), handshakeError: .cancelled)
    }

    private func waitForAudioSend() async {
        guard audioSending else { return }
        await withCheckedContinuation { audioSendWaiters.append($0) }
    }
    private func completeAudioSend() {
        audioSending = false
        let waiters = audioSendWaiters; audioSendWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    private func makeRequest(config: InterpretationSessionConfiguration, key: String) throws -> URLRequest {
        let url: URL
        switch provider {
        case .google:
            url = URL(string: "wss://generativelanguage.googleapis.com/ws/google.ai.generativelanguage.v1beta.GenerativeService.BidiGenerateContent")!
        case .openAI:
            var components = URLComponents(string: "wss://api.openai.com/v1/realtime/translations")!
            components.queryItems = [.init(name: "model", value: config.modelID)]
            guard let result = components.url else { throw InterpretationFailure.invalidConfiguration }
            url = result
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = handshakeTimeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(provider == .google ? key : "Bearer \(key)", forHTTPHeaderField: provider == .google ? "x-goog-api-key" : "Authorization")
        return request
    }

    private func googleSetup(_ config: InterpretationSessionConfiguration) -> [String: Any] {
        var setup: [String: Any] = [
            "model": "models/\(config.modelID)",
            "generationConfig": ["responseModalities": ["AUDIO"], "translationConfig": ["targetLanguageCode": config.targetLanguageCode, "echoTargetLanguage": false]],
            "outputAudioTranscription": [String: String]()
        ]
        // API reference and official SDK converter use setup-level fields. The
        // translation guide's nested example conflicts; covered by smoke-test gate.
        if config.inputTranscription { setup["inputAudioTranscription"] = [String: String]() }
        return ["setup": setup]
    }

    private func sendJSON(_ object: [String: Any]) async throws {
        guard let transport else { throw InterpretationFailure.connectionLost }
        try await transport.send(JSONSerialization.data(withJSONObject: object))
    }

    private func receive(_ data: Data) async throws {
        guard data.count <= 4 * 1024 * 1024,
              let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw InterpretationFailure.protocolViolation }
        if let error = message["error"] as? [String: Any] {
            let code = (error["code"] as? String) ?? (error["status"] as? String) ?? (error["code"] as? NSNumber)?.stringValue
            throw InterpretationFailure.fromProvider(code: code, type: error["type"] as? String)
        }
        switch provider {
        case .google: try receiveGoogle(message)
        case .openAI: try await receiveOpenAI(message)
        }
    }

    private func receiveGoogle(_ message: [String: Any]) throws {
        if let setupComplete = message["setupComplete"] as? [String: Any] {
            guard state == .connecting else { return }
            let sessionID = setupComplete["sessionId"] as? String
            ready(sessionID: sessionID, expiresAt: nil)
            return
        }
        guard state == .ready || state == .finishing else { throw InterpretationFailure.protocolViolation }
        if let usage = message["usageMetadata"] as? [String: Any] {
            emit(.usage(.init(inputTokens: usage["promptTokenCount"] as? Int, outputTokens: usage["responseTokenCount"] as? Int, totalTokens: usage["totalTokenCount"] as? Int)))
        }
        if let goAway = message["goAway"] as? [String: Any] {
            let seconds = (goAway["timeLeft"] as? String).flatMap { Double($0.hasSuffix("s") ? String($0.dropLast()) : $0) }
            emit(.connectionWillClose(seconds: seconds))
        }
        // Session resumption is deliberately not enabled until this dedicated
        // model's recovery behavior is validated. Handles never enter app events.
        guard let content = message["serverContent"] as? [String: Any] else { return }
        for (field, track) in [("inputTranscription", InterpretationTranscriptTrack.source), ("outputTranscription", .translation)] {
            guard let transcript = content[field] as? [String: Any] else { continue }
            let text = transcript["text"] as? String ?? "", finished = transcript["finished"] as? Bool
            // Official SDK makes text optional independently of finished. This
            // only honors a received final flag; it does not require the model
            // to emit one or infer a turn boundary when no flag arrives.
            if !text.isEmpty || finished == true { emit(.transcript(track: track, text: text, isFinal: finished, languageCode: transcript["languageCode"] as? String)) }
        }
        if content["interrupted"] as? Bool == true { emit(.interrupted) }
        if let turn = content["modelTurn"] as? [String: Any], let parts = turn["parts"] as? [[String: Any]] {
            for part in parts {
                guard let inline = part["inlineData"] as? [String: Any] else { continue }
                guard let encoded = inline["data"] as? String, let bytes = Data(base64Encoded: encoded), !bytes.isEmpty,
                      bytes.count % 2 == 0 else { throw InterpretationFailure.audioFormat }
                if inline["mimeType"] != nil {
                    guard let mime = inline["mimeType"] as? String else { throw InterpretationFailure.audioFormat }
                    let normalized = mime.lowercased().replacingOccurrences(of: " ", with: "")
                    guard normalized == "audio/pcm;rate=24000" || normalized == "audio/pcm" else { throw InterpretationFailure.audioFormat }
                }
                emit(.audio(bytes, .translatedAudio))
            }
        }
        // A generation boundary is not proof that all Google input was flushed.
        if state == .finishing && content["turnComplete"] as? Bool == true {
            complete(.init(reason: .generationBoundary, tailMayBeIncomplete: true))
        }
    }

    private func receiveOpenAI(_ message: [String: Any]) async throws {
        guard let type = message["type"] as? String else { throw InterpretationFailure.protocolViolation }
        let eventID = message["event_id"] as? String
        let elapsed = (message["elapsed_ms"] as? NSNumber)?.intValue
        if type == "session.created" {
            guard state == .connecting, !openAICreated, let config = configuration else { throw InterpretationFailure.protocolViolation }
            _ = try validateOpenAISession(message, checkAudio: false)
            openAICreated = true
            let transcription: Any = config.inputTranscription ? ["model": "gpt-realtime-whisper"] : NSNull()
            try await sendJSON(["type": "session.update", "session": ["audio": ["input": ["transcription": transcription, "noise_reduction": NSNull()], "output": ["language": config.targetLanguageCode]]]])
            return
        }
        if type == "session.updated" {
            guard state == .connecting, openAICreated else { throw InterpretationFailure.protocolViolation }
            let session = try validateOpenAISession(message, checkAudio: true)
            let expires = (session["expires_at"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue) }
            ready(sessionID: session["id"] as? String, expiresAt: expires)
            return
        }
        guard state == .ready || state == .finishing else { throw InterpretationFailure.protocolViolation }
        switch type {
        case "session.input_transcript.delta", "session.output_transcript.delta":
            guard let text = message["delta"] as? String else { throw InterpretationFailure.protocolViolation }
            if !text.isEmpty { emit(.transcript(track: type == "session.input_transcript.delta" ? .source : .translation, text: text, isFinal: nil, languageCode: nil), eventID: eventID, elapsedMS: elapsed) }
        case "session.output_audio.delta":
            guard let encoded = message["delta"] as? String, let bytes = Data(base64Encoded: encoded), !bytes.isEmpty,
                  (message["format"] as? String ?? "pcm16") == "pcm16" else { throw InterpretationFailure.audioFormat }
            if message["sample_rate"] != nil && !(message["sample_rate"] is Int) { throw InterpretationFailure.audioFormat }
            if message["channels"] != nil && !(message["channels"] is Int) { throw InterpretationFailure.audioFormat }
            if message["format"] != nil && !(message["format"] is String) { throw InterpretationFailure.audioFormat }
            let format = InterpretationPCMFormat(sampleRate: message["sample_rate"] as? Int ?? 24_000, channels: message["channels"] as? Int ?? 1)
            guard format == .translatedAudio, bytes.count % format.bytesPerFrame == 0 else { throw InterpretationFailure.audioFormat }
            emit(.audio(bytes, format), eventID: eventID, elapsedMS: elapsed)
        case "session.closed": complete(.init(reason: .protocolClosed, tailMayBeIncomplete: state != .finishing))
        default: break // Forward-compatible unknown events never invent text or audio.
        }
    }

    private func validateOpenAISession(_ message: [String: Any], checkAudio: Bool) throws -> [String: Any] {
        guard let config = configuration, let session = message["session"] as? [String: Any],
              session["type"] as? String == "translation", session["model"] as? String == config.modelID,
              session["id"] is String else { throw InterpretationFailure.incompatibleModel }
        if checkAudio {
            guard let audio = session["audio"] as? [String: Any], let output = audio["output"] as? [String: Any],
                  output["language"] as? String == config.targetLanguageCode else { throw InterpretationFailure.unsupportedLanguage }
            if config.inputTranscription {
                guard let input = audio["input"] as? [String: Any], let transcription = input["transcription"] as? [String: Any],
                      transcription["model"] as? String == "gpt-realtime-whisper" else { throw InterpretationFailure.protocolViolation }
            } else if let input = audio["input"] as? [String: Any], let transcription = input["transcription"], !(transcription is NSNull) {
                throw InterpretationFailure.protocolViolation
            }
        }
        return session
    }

    private func ready(sessionID: String?, expiresAt: Date?) {
        state = .ready; timer?.cancel(); timer = nil
        let continuation = handshake; handshake = nil
        emit(.ready(sessionID: sessionID, expiresAt: expiresAt))
        continuation?.resume()
    }
    private func emit(_ payload: InterpretationSessionEvent.Payload, eventID: String? = nil, elapsedMS: Int? = nil) {
        guard state != .closed else { return }
        sequence &+= 1
        onEvent?(.init(eventID: eventID, sequence: sequence, elapsedMS: elapsedMS, receivedAt: Date(), payload: payload))
    }
    private func isCurrent(_ value: UInt64) -> Bool { generation == value && state != .closed }
    private func armTimer(seconds: TimeInterval, generation: UInt64, action: @escaping @MainActor () -> Void) {
        timer?.cancel()
        timer = Task { [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0.001, seconds) * 1_000_000_000)) } catch { return }
            guard let self, self.isCurrent(generation) else { return }
            action()
        }
    }
    private func fail(_ failure: InterpretationFailure) {
        guard state != .closed else { return }
        emit(.failure(failure))
        complete(.init(reason: .failed, tailMayBeIncomplete: true), handshakeError: failure)
    }
    private func complete(_ result: InterpretationFinishResult, handshakeError: InterpretationFailure = .connectionLost) {
        guard state != .closed else { return }
        let continuation = handshake; handshake = nil
        finishResult = result
        // Invalidate receive/send completions before cancelling the transport.
        generation &+= 1
        timer?.cancel(); timer = nil
        completeAudioSend()
        receiver?.cancel(); receiver = nil
        transport?.close(); transport = nil
        lease.release(leaseID)
        state = .closed
        continuation?.resume(throwing: handshakeError)
        let waiters = finishWaiters; finishWaiters.removeAll()
        for waiter in waiters { waiter.resume(returning: result) }
        sequence &+= 1
        onEvent?(.init(eventID: nil, sequence: sequence, elapsedMS: nil, receivedAt: Date(), payload: .closed(result)))
    }
}
