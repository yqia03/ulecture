import Foundation

enum InterpretationProvider: String, Codable, CaseIterable, Sendable {
    case google, openAI
    var defaultModelID: String { self == .google ? "gemini-3.5-live-translate-preview" : "gpt-realtime-translate" }
    var inputFormat: InterpretationPCMFormat { InterpretationPCMFormat(sampleRate: self == .google ? 16_000 : 24_000) }
    var inputChunkMilliseconds: Int { self == .google ? 100 : 200 }
}

enum InterpretationMode: String, Codable, CaseIterable, Sendable {
    case googleOnline, openAIOnline, localSpeechText
    var provider: InterpretationProvider? {
        switch self { case .googleOnline: return .google; case .openAIOnline: return .openAI; case .localSpeechText: return nil }
    }
}

/// All PCM crossing this interface is signed 16-bit little-endian interleaved data.
struct InterpretationPCMFormat: Equatable, Codable, Sendable {
    var sampleRate: Int
    var channels: Int = 1
    var bytesPerFrame: Int { channels * 2 }
    var bytesPerSecond: Int { sampleRate * bytesPerFrame }
    static let translatedAudio = InterpretationPCMFormat(sampleRate: 24_000)
}

struct InterpretationSessionConfiguration: Equatable, Codable, Sendable {
    var provider: InterpretationProvider
    var modelID: String
    var targetLanguageCode: String
    var inputTranscription: Bool = true

    /// Model syntax is only a preflight. Unknown IDs still need a real protocol handshake.
    func validated() throws -> Self {
        guard modelID.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$", options: .regularExpression) != nil else {
            throw InterpretationFailure.invalidConfiguration
        }
        let model = modelID.lowercased()
        switch provider {
        case .google:
            if model.hasPrefix("gpt-") || model.hasPrefix("o1") || model.hasPrefix("o3") ||
                (model.hasPrefix("gemini-") && !model.contains("translate")) { throw InterpretationFailure.incompatibleModel }
        case .openAI:
            if model.hasPrefix("gemini-") || model.hasPrefix("o1") || model.hasPrefix("o3") || model.hasPrefix("o4") ||
                (model.hasPrefix("gpt-") && !model.hasPrefix("gpt-realtime-translate")) { throw InterpretationFailure.incompatibleModel }
        }
        guard targetLanguageCode.range(of: "^[A-Za-z]{2,3}(-[A-Za-z0-9]{2,8})*$", options: .regularExpression) != nil else {
            throw InterpretationFailure.unsupportedLanguage
        }
        // Google documents Chinese scripts; OpenAI documents Chinese but its exact
        // zh acceptance still needs an account smoke test. Never send script tags there.
        if provider == .openAI {
            let supported = ["en", "es", "fr", "de", "it", "pt", "ru", "ja", "ko", "zh", "hi", "vi", "id"]
            guard supported.contains(targetLanguageCode) else { throw InterpretationFailure.unsupportedLanguage }
        }
        return self
    }
}

enum InterpretationFailure: String, Error, Codable, CaseIterable, LocalizedError, Sendable {
    case invalidConfiguration, incompatibleModel, unsupportedLanguage, missingCredential
    case authentication, modelUnavailable, rateLimited, handshakeTimeout, finishTimeout, connectionLost
    case protocolViolation, audioFormat, invalidAudio, bufferOverflow, cancelled, sessionExpired, serviceUnavailable, serviceBusy
    var errorCode: String { rawValue }
    var isRetryable: Bool {
        [.rateLimited, .handshakeTimeout, .finishTimeout, .connectionLost, .serviceUnavailable, .sessionExpired].contains(self)
    }
    // Never expose provider messages, URLs or NSError descriptions containing credentials.
    var errorDescription: String? { "interpretation.\(rawValue)" }
    static func fromTransport(_ error: Error) -> Self {
        if let failure = error as? Self { return failure }
        if error is CancellationError { return .cancelled }
        return .connectionLost
    }
    static func fromProvider(code: String?, type: String?) -> Self {
        switch (code ?? "").lowercased() {
        case "invalid_api_key", "unauthenticated", "permission_denied", "authentication_error", "401", "403": return .authentication
        case "model_not_found", "model_not_available", "not_found", "404": return .modelUnavailable
        case "rate_limit_exceeded", "resource_exhausted", "insufficient_quota", "429": return .rateLimited
        case "session_expired": return .sessionExpired
        case "unavailable", "internal", "server_error", "500", "503": return .serviceUnavailable
        default: return type == "server_error" ? .serviceUnavailable : .protocolViolation
        }
    }
}

enum InterpretationTranscriptTrack: String, Codable, Sendable { case source, translation }
struct InterpretationReportedUsage: Equatable, Sendable {
    var inputTokens: Int?
    var outputTokens: Int?
    var totalTokens: Int?
    // Unknown until verified for this model; consumers must not blindly sum snapshots.
    var isCumulative: Bool? = nil
}
struct InterpretationFinishResult: Equatable, Sendable {
    enum Reason: String, Sendable { case protocolClosed, generationBoundary, timedOut, transportClosed, aborted, failed }
    var reason: Reason
    var tailMayBeIncomplete: Bool
}
struct InterpretationSessionEvent: Sendable {
    enum Payload: Sendable {
        case ready(sessionID: String?, expiresAt: Date?)
        case transcript(track: InterpretationTranscriptTrack, text: String, isFinal: Bool?, languageCode: String?)
        case audio(Data, InterpretationPCMFormat)
        case usage(InterpretationReportedUsage)
        case interrupted
        case connectionWillClose(seconds: Double?)
        case closed(InterpretationFinishResult)
        case failure(InterpretationFailure)
    }
    var eventID: String?
    var sequence: UInt64
    var elapsedMS: Int?
    var receivedAt: Date
    var payload: Payload
}

/// Frame-aligned PCM framing; deliberately has no VAD or silence suppression.
struct InterpretationPCMChunker {
    let format: InterpretationPCMFormat
    let chunkMilliseconds: Int
    private(set) var pending = Data()
    var chunkByteCount: Int { format.bytesPerSecond * chunkMilliseconds / 1000 }
    init(format: InterpretationPCMFormat, chunkMilliseconds: Int) {
        precondition(format.sampleRate > 0 && format.channels > 0 && chunkMilliseconds > 0)
        self.format = format; self.chunkMilliseconds = chunkMilliseconds
        precondition(chunkByteCount > 0 && chunkByteCount % format.bytesPerFrame == 0)
    }
    mutating func append(_ bytes: Data) -> [Data] {
        pending.append(bytes)
        var chunks: [Data] = []
        while pending.count >= chunkByteCount {
            chunks.append(Data(pending.prefix(chunkByteCount)))
            pending.removeFirst(chunkByteCount)
        }
        return chunks
    }
    mutating func flush() throws -> Data? {
        guard pending.count % format.bytesPerFrame == 0 else { throw InterpretationFailure.audioFormat }
        guard !pending.isEmpty else { return nil }
        defer { pending.removeAll(keepingCapacity: true) }
        return pending
    }
    mutating func reset() { pending.removeAll(keepingCapacity: true) }
}
