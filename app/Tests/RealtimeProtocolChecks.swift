import Foundation

private struct CheckFailure: Error { let reason: String }
@MainActor private func require(_ value: @autoclosure () -> Bool, _ reason: String) throws {
    if !value() { throw CheckFailure(reason: reason) }
}

@MainActor private final class MockRealtimeTransport: RealtimeTransport {
    var request: URLRequest?
    var sent: [[String: Any]] = []
    var incoming: [Data] = []
    var receiveWaiter: CheckedContinuation<Data, Error>?
    var audioSendWaiter: CheckedContinuation<Void, Error>?
    var holdAudioSend = false
    var closed = false
    var onConnect: ((MockRealtimeTransport) -> Void)?
    var onSend: (([String: Any], MockRealtimeTransport) -> Void)?
    func connect(request: URLRequest) async throws { self.request = request; onConnect?(self) }
    func send(_ data: Data) async throws {
        guard !closed else { throw InterpretationFailure.connectionLost }
        let message = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        sent.append(message); onSend?(message, self)
        if holdAudioSend, message["type"] as? String == "session.input_audio_buffer.append" {
            try await withCheckedThrowingContinuation { audioSendWaiter = $0 }
        }
    }
    func receive() async throws -> Data {
        if !incoming.isEmpty { return incoming.removeFirst() }
        if closed { throw CancellationError() }
        return try await withCheckedThrowingContinuation { receiveWaiter = $0 }
    }
    func push(_ message: [String: Any]) {
        let data = try! JSONSerialization.data(withJSONObject: message)
        if let waiter = receiveWaiter { receiveWaiter = nil; waiter.resume(returning: data) }
        else { incoming.append(data) }
    }
    func close() {
        closed = true
        let waiter = receiveWaiter; receiveWaiter = nil
        waiter?.resume(throwing: CancellationError())
        let sendWaiter = audioSendWaiter; audioSendWaiter = nil
        sendWaiter?.resume(throwing: CancellationError())
    }
    static func google() -> MockRealtimeTransport {
        let result = MockRealtimeTransport()
        result.onSend = { message, transport in
            if message["setup"] != nil { transport.push(["setupComplete": [:]]) }
        }
        return result
    }
    static func openAI(transcription: Bool = true) -> MockRealtimeTransport {
        let result = MockRealtimeTransport()
        func session(_ audio: [String: Any]) -> [String: Any] {
            ["id": "sess_fixture", "type": "translation", "model": "gpt-realtime-translate", "expires_at": 2_000_000_000, "audio": audio]
        }
        result.onConnect = { $0.push(["type": "session.created", "event_id": "created", "session": session([:])]) }
        result.onSend = { message, transport in
            if message["type"] as? String == "session.update" {
                var audio = ((message["session"] as? [String: Any])?["audio"] as? [String: Any]) ?? [:]
                if !transcription { audio["input"] = [String: String]() }
                transport.push(["type": "session.updated", "event_id": "updated", "session": session(audio)])
            }
        }
        return result
    }
}

@main struct RealtimeProtocolChecks {
    @MainActor static func main() async throws {
        if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "loopback" {
            try await loopback(port: CommandLine.arguments[2]); return
        }
        try modelAndChunks()
        try await google()
        try await openAI()
        try await failures()
        try await sharedLease()
        try await sendDrainBarrier()
        print("realtime protocol checks passed: framing, dedicated handshakes, subtitles, audio, drain, timeout, redaction and late-event isolation")
    }

    @MainActor static func modelAndChunks() throws {
        for provider in InterpretationProvider.allCases {
            var chunker = InterpretationPCMChunker(format: provider.inputFormat, chunkMilliseconds: provider.inputChunkMilliseconds)
            let size = provider == .google ? 3_200 : 9_600
            try require(chunker.chunkByteCount == size, "wrong provider chunk size")
            let silence = Data(repeating: 0, count: size * 2 + 20)
            var chunks = chunker.append(silence.prefix(9))
            chunks += chunker.append(silence.dropFirst(9))
            try require(chunks.map(\.count) == [size, size], "chunk cadence changed")
            let tail = try chunker.flush()
            try require(tail?.count == 20 && chunker.pending.isEmpty, "tail not flushed once")
            try require(chunks.reduce(Data(), +) + (tail ?? Data()) == silence, "silence was lost")
            _ = chunker.append(Data([1]))
            do { _ = try chunker.flush(); throw CheckFailure(reason: "odd PCM accepted") }
            catch InterpretationFailure.audioFormat { }
            chunker.reset()
        }
        for (provider, model) in [(InterpretationProvider.google, "gemini-3.5-flash"), (.openAI, "gpt-4o"), (.openAI, "gpt-realtime-2.1")] {
            do { _ = try InterpretationSessionConfiguration(provider: provider, modelID: model, targetLanguageCode: "en").validated(); throw CheckFailure(reason: "chat model accepted") }
            catch InterpretationFailure.incompatibleModel { }
        }
        _ = try InterpretationSessionConfiguration(provider: .openAI, modelID: "future-translation-v2", targetLanguageCode: "zh").validated()
        do { _ = try InterpretationSessionConfiguration(provider: .openAI, modelID: "gpt-realtime-translate", targetLanguageCode: "zh-Hant").validated(); throw CheckFailure(reason: "OpenAI script tag accepted") }
        catch InterpretationFailure.unsupportedLanguage { }
    }

    @MainActor static func google() async throws {
        let transport = MockRealtimeTransport.google()
        let session = GoogleInterpretationSession(transportFactory: { transport }, handshakeTimeout: 0.1, finishTimeout: 0.03)
        var events: [InterpretationSessionEvent] = []
        session.onEvent = { events.append($0) }
        try await session.start(configuration: .init(provider: .google, modelID: "gemini-3.5-live-translate-preview", targetLanguageCode: "zh-Hant"), apiKey: "fixture-secret")
        try require(transport.request?.value(forHTTPHeaderField: "x-goog-api-key") == "fixture-secret", "Google header auth missing")
        try require(transport.request?.url?.query == nil, "credential in URL")
        let setup = transport.sent[0]["setup"] as! [String: Any]
        let generation = setup["generationConfig"] as! [String: Any]
        try require(setup["inputAudioTranscription"] != nil && setup["outputAudioTranscription"] != nil, "transcription misplaced")
        try require(generation["inputAudioTranscription"] == nil && generation["translationConfig"] != nil, "Google schema mixed")
        try require(setup["systemInstruction"] == nil && setup["sessionResumption"] == nil, "unverified features enabled")
        try await session.sendAudio(Data(repeating: 0, count: 3_200))
        let input = transport.sent[1]["realtimeInput"] as! [String: Any]
        let audio = input["audio"] as! [String: Any]
        try require(audio["mimeType"] as? String == "audio/pcm;rate=16000", "Google input rate wrong")
        transport.push(["serverContent": ["outputTranscription": ["text": "你好", "languageCode": "zh-Hant"]]])
        transport.push(["serverContent": ["inputTranscription": ["text": "hello", "languageCode": "en"], "modelTurn": ["parts": [["inlineData": ["data": Data([1, 0, 2, 0]).base64EncodedString(), "mimeType": "audio/pcm;rate=24000"]]]]]])
        try await wait { events.count >= 4 }
        let transcripts = events.compactMap { event -> String? in if case .transcript(_, let text, _, _) = event.payload { return text }; return nil }
        try require(!events.contains { if case .transcript(_, _, .some, _) = $0.payload { return true }; return false }, "Google final invented")
        try require(transcripts == ["你好", "hello"], "independent transcript order was changed")
        transport.push(["serverContent": ["inputTranscription": ["finished": true]]])
        try await wait { events.contains { if case .transcript(.source, "", true, _) = $0.payload { return true }; return false } }
        let result = await session.finish()
        try require(result.reason == .timedOut && result.tailMayBeIncomplete, "Google drain falsely confirmed")
        let ending = transport.sent.last?["realtimeInput"] as? [String: Any]
        try require(ending?["audioStreamEnd"] as? Bool == true, "Google stream end absent")
        let count = events.count
        transport.push(["serverContent": ["outputTranscription": ["text": "late"]]])
        await Task.yield()
        try require(events.count == count, "late Google event escaped")
    }

    @MainActor static func openAI() async throws {
        let transport = MockRealtimeTransport.openAI()
        let session = OpenAIInterpretationSession(transportFactory: { transport }, handshakeTimeout: 0.1, finishTimeout: 0.1)
        var events: [InterpretationSessionEvent] = []
        session.onEvent = { events.append($0) }
        try await session.start(configuration: .init(provider: .openAI, modelID: "gpt-realtime-translate", targetLanguageCode: "zh"), apiKey: "fixture-secret")
        try require(transport.request?.url?.path == "/v1/realtime/translations", "generic Realtime endpoint used")
        try require(transport.request?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-secret", "OpenAI auth missing")
        let update = transport.sent[0]["session"] as! [String: Any]
        let audio = update["audio"] as! [String: Any]
        let input = audio["input"] as! [String: Any]
        try require((input["transcription"] as? [String: Any])?["model"] as? String == "gpt-realtime-whisper", "online transcription absent")
        try await session.sendAudio(Data(repeating: 0, count: 9_600))
        try require(transport.sent[1]["type"] as? String == "session.input_audio_buffer.append", "wrong append event")
        for (id, text) in [("text1", "您"), ("text2", "好")] {
            transport.push(["type": "session.output_transcript.delta", "event_id": id, "delta": text, "elapsed_ms": 200])
        }
        transport.push(["type": "session.input_transcript.delta", "event_id": "source", "delta": "hello"])
        transport.push(["type": "session.output_audio.delta", "event_id": "audio", "delta": Data([0, 0, 0, 0, 0, 0]).base64EncodedString(), "sample_rate": 24000, "channels": 1, "format": "pcm16"])
        try await wait { events.count >= 5 }
        let subtitles = events.compactMap { event -> String? in if case .transcript(let track, let text, _, _) = event.payload, track == .translation { return text }; return nil }.joined()
        try require(subtitles == "您好", "delta text or equal timestamp was lost")
        try require(events.filter { $0.elapsedMS == 200 }.count == 2, "elapsed treated as identifier")
        transport.onSend = { message, fixture in
            if message["type"] as? String == "session.close" {
                fixture.push(["type": "session.output_transcript.delta", "event_id": "tail", "delta": "。"])
                fixture.push(["type": "session.closed", "event_id": "closed"])
            }
        }
        let result = await session.finish()
        try require(result.reason == .protocolClosed && !result.tailMayBeIncomplete, "OpenAI did not await session.closed")
        try require(events.contains { if case .transcript(_, "。", _, _) = $0.payload { return true }; return false }, "draining tail lost")
        let sends = transport.sent.count
        _ = await session.finish()
        try require(transport.sent.count == sends, "session.close sent twice")
        do { try await session.sendAudio(Data([0, 0])); throw CheckFailure(reason: "audio sent after close") }
        catch InterpretationFailure.cancelled { }
        try require(transport.closed, "socket left open")
    }

    @MainActor static func failures() async throws {
        let missing = MockRealtimeTransport.openAI(transcription: false)
        let invalid = OpenAIInterpretationSession(transportFactory: { missing }, handshakeTimeout: 0.1, finishTimeout: 0.01)
        do { try await invalid.start(configuration: .init(provider: .openAI, modelID: "gpt-realtime-translate", targetLanguageCode: "zh"), apiKey: "fixture"); throw CheckFailure(reason: "missing transcription handshake accepted") }
        catch InterpretationFailure.protocolViolation { }
        let silent = MockRealtimeTransport()
        let timeout = GoogleInterpretationSession(transportFactory: { silent }, handshakeTimeout: 0.01, finishTimeout: 0.01)
        do { try await timeout.start(configuration: .init(provider: .google, modelID: "gemini-3.5-live-translate-preview", targetLanguageCode: "zh-Hans"), apiKey: "fixture"); throw CheckFailure(reason: "handshake did not time out") }
        catch InterpretationFailure.handshakeTimeout { }
        try require(silent.closed, "timeout leaked socket")
        let cancelledTransport = MockRealtimeTransport()
        let cancelled = GoogleInterpretationSession(transportFactory: { cancelledTransport }, handshakeTimeout: 1, finishTimeout: 0.01)
        let connecting = Task { try await cancelled.start(configuration: .init(provider: .google, modelID: "gemini-3.5-live-translate-preview", targetLanguageCode: "en"), apiKey: "fixture") }
        try await wait { cancelledTransport.request != nil }
        connecting.cancel()
        do { try await connecting.value; throw CheckFailure(reason: "cancelled start succeeded") }
        catch InterpretationFailure.cancelled { }
        try require(cancelledTransport.closed, "cancelled handshake leaked socket")
        for code in ["invalid_api_key", "model_not_found", "rate_limit_exceeded", "server_error"] {
            let transport = MockRealtimeTransport()
            transport.onConnect = { $0.push(["type": "error", "error": ["code": code, "message": "secret-sk-do-not-display https://host/?key=secret"]]) }
            let session = OpenAIInterpretationSession(transportFactory: { transport }, handshakeTimeout: 0.1, finishTimeout: 0.01)
            do { try await session.start(configuration: .init(provider: .openAI, modelID: "gpt-realtime-translate", targetLanguageCode: "zh"), apiKey: "fixture"); throw CheckFailure(reason: "provider failure accepted") }
            catch let error as InterpretationFailure {
                try require(!error.localizedDescription.contains("secret"), "raw provider failure leaked")
            }
        }
        let reentrant = MockRealtimeTransport.google()
        let session = GoogleInterpretationSession(transportFactory: { reentrant }, handshakeTimeout: 0.1, finishTimeout: 0.01)
        session.onEvent = { event in if case .closed = event.payload { session.abort() } }
        try await session.start(configuration: .init(provider: .google, modelID: "gemini-3.5-live-translate-preview", targetLanguageCode: "en"), apiKey: "fixture")
        session.abort()
        for invalidAudio in [["sample_rate": 48_000], ["sample_rate": "24000"], ["channels": 2], ["format": "opus"]] as [[String: Any]] {
            let transport = MockRealtimeTransport.openAI()
            let session = OpenAIInterpretationSession(transportFactory: { transport }, handshakeTimeout: 0.1, finishTimeout: 0.01)
            var failure: InterpretationFailure?
            session.onEvent = { if case .failure(let reason) = $0.payload { failure = reason } }
            try await session.start(configuration: .init(provider: .openAI, modelID: "gpt-realtime-translate", targetLanguageCode: "zh"), apiKey: "fixture")
            var event = invalidAudio
            event["type"] = "session.output_audio.delta"
            event["event_id"] = "bad-format"
            event["delta"] = Data([0, 0]).base64EncodedString()
            transport.push(event)
            try await wait { failure != nil }
            try require(failure == .audioFormat && transport.closed, "invalid output PCM accepted")
        }
        let noCloseAck = MockRealtimeTransport.openAI()
        let drain = OpenAIInterpretationSession(transportFactory: { noCloseAck }, handshakeTimeout: 0.1, finishTimeout: 0.01)
        try await drain.start(configuration: .init(provider: .openAI, modelID: "gpt-realtime-translate", targetLanguageCode: "en"), apiKey: "fixture")
        async let first = drain.finish()
        async let second = drain.finish()
        let results = await [first, second]
        try require(results.allSatisfy { $0.reason == .timedOut && $0.tailMayBeIncomplete }, "close timeout falsely complete")
        try require(noCloseAck.sent.filter { $0["type"] as? String == "session.close" }.count == 1, "concurrent finish duplicated close")
    }

    @MainActor static func wait(_ predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            if predicate() { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        throw CheckFailure(reason: "fixture event timeout")
    }

    @MainActor static func sharedLease() async throws {
        let googleConfig = InterpretationSessionConfiguration(provider: .google, modelID: InterpretationProvider.google.defaultModelID, targetLanguageCode: "zh-Hans")
        let openConfig = InterpretationSessionConfiguration(provider: .openAI, modelID: InterpretationProvider.openAI.defaultModelID, targetLanguageCode: "zh")
        let activeTransport = MockRealtimeTransport.google()
        let active = GoogleInterpretationSession(transportFactory: { activeTransport }, handshakeTimeout: 0.1, finishTimeout: 0.01)
        try await active.start(configuration: googleConfig, apiKey: "fixture")
        for config in [googleConfig, openConfig] {
            let blockedTransport = MockRealtimeTransport()
            do {
                try await InterpretationSessionFactory.testConnection(configuration: config, apiKey: "fixture", sessionFactory: { provider in
                    if provider == .google { return GoogleInterpretationSession(transportFactory: { blockedTransport }) }
                    return OpenAIInterpretationSession(transportFactory: { blockedTransport })
                })
                throw CheckFailure(reason: "parallel translation test acquired connection")
            } catch InterpretationFailure.serviceBusy { }
            try require(blockedTransport.request == nil && !activeTransport.closed, "lease rejection opened or stopped a connection")
        }
        active.abort()
        let testTransport = MockRealtimeTransport.openAI()
        let originalSend = testTransport.onSend
        testTransport.onSend = { message, fixture in
            originalSend?(message, fixture)
            if message["type"] as? String == "session.close" { fixture.push(["type": "session.closed"]) }
        }
        try await InterpretationSessionFactory.testConnection(configuration: openConfig, apiKey: "fixture", sessionFactory: { _ in
            OpenAIInterpretationSession(transportFactory: { testTransport }, handshakeTimeout: 0.1, finishTimeout: 0.01)
        })
        try require(testTransport.closed && testTransport.sent.last?["type"] as? String == "session.close", "connection test failed normal close")
        let incomplete = MockRealtimeTransport.openAI()
        do {
            try await InterpretationSessionFactory.testConnection(configuration: openConfig, apiKey: "fixture", sessionFactory: { _ in
                OpenAIInterpretationSession(transportFactory: { incomplete }, handshakeTimeout: 0.1, finishTimeout: 0.01)
            })
            throw CheckFailure(reason: "test passed without session.closed")
        } catch InterpretationFailure.finishTimeout { }
    }

    @MainActor static func sendDrainBarrier() async throws {
        let transport = MockRealtimeTransport.openAI()
        transport.holdAudioSend = true
        let active = OpenAIInterpretationSession(transportFactory: { transport }, handshakeTimeout: 0.1, finishTimeout: 0.1)
        try await active.start(configuration: .init(provider: .openAI, modelID: InterpretationProvider.openAI.defaultModelID, targetLanguageCode: "zh"), apiKey: "fixture")
        let upload = Task { @MainActor in try await active.sendAudio(Data(repeating: 0, count: 9600)) }
        try await wait { transport.audioSendWaiter != nil }
        transport.onSend = { message, fixture in
            if message["type"] as? String == "session.close" { fixture.push(["type": "session.closed"]) }
        }
        let close = Task { @MainActor in await active.finish() }
        await Task.yield(); await Task.yield()
        try require(!transport.sent.contains { $0["type"] as? String == "session.close" }, "close overtook in-flight upload")
        do { try await active.sendAudio(Data([0, 0])); throw CheckFailure(reason: "upload admitted after finish barrier") }
        catch InterpretationFailure.cancelled { }
        let waiter = transport.audioSendWaiter; transport.audioSendWaiter = nil; waiter?.resume()
        try await upload.value
        let result = await close.value
        try require(result.reason == .protocolClosed && transport.sent.filter { $0["type"] as? String == "session.input_audio_buffer.append" }.count == 1, "upload repeated during close")
    }

    @MainActor static func loopback(port: String) async throws {
        let transport = URLSessionRealtimeTransport()
        let url = URL(string: "ws://127.0.0.1:\(port)/translation-fixture")!
        var request = URLRequest(url: url)
        request.setValue("fixture-local-only", forHTTPHeaderField: "x-test-credential")
        try await transport.connect(request: request)
        defer { transport.close() }
        try await transport.send(Data("{\"fixture\":true}".utf8))
        let data = try await transport.receive()
        let response = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        try require(response?["echo"] as? String == "{\"fixture\":true}", "native transport loopback did not echo")
        print("native URLSessionWebSocketTask loopback passed")
    }
}
