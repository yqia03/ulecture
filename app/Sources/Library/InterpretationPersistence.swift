import Foundation

/// Online interpretation facts use separate tracks. No credential, connection URL,
/// resumption token, or assumed source/translation pairing belongs in these records.
struct InterpretationRuntimeRecord: Codable, Equatable, Identifiable {
    var id: String { sessionID }
    var version = 1
    var sessionID: String
    var mode = "googleOnline"
    var provider = "google"
    var modelID = ""
    var sourceLanguage = "en"
    var targetLanguage = "zh"
    var subtitleLanguage = "zh-Hans"
    var state = "idle"
    var generation = 0
    var startedAt: Date? = nil
    var updatedAt = Date()
    var closeComplete: Bool? = nil
    var errorCode: String? = nil
}

struct InterpretationCaptionRecord: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var version = 1
    var sessionID: String
    var generation: Int
    var track: String // source / translation; independent and never implicitly paired
    var text: String
    var originalText: String? = nil
    var language: String
    var isFinal = false
    var completionBasis = "streaming" // provider / localBoundary / sessionClosed / interrupted
    var revision = 1
    var sequence: UInt64 = 0
    var providerItemReference: String? = nil
    var providerEventReference: String? = nil
    var receivedAtMS: Int64
    /// Raw provider metadata, whose alignment semantics may be unverified.
    /// It is never substituted for a caption's start/end display interval.
    var providerElapsedMS: Int64? = nil
    var startMS: Int64? = nil
    var endMS: Int64? = nil
    var timingSource = "unknown" // provider / estimated / receiveTime / unknown
}

struct InterpretationUsageObservation: Codable, Equatable {
    var sequence: UInt64
    var eventID: String? = nil
    var observedAt: Date
    var inputTokens: Int? = nil
    var outputTokens: Int? = nil
    var totalTokens: Int? = nil
    var isCumulative: Bool? = nil
}

struct InterpretationUsageRecord: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var version = 1
    var sessionID: String
    var generation: Int
    var provider: String
    var modelID: String
    var uploadedSeconds: Double = 0
    var generatedSeconds: Double = 0
    var playedSeconds: Double = 0
    var connectionSeconds: Double = 0
    var providerReportedInputSeconds: Double? = nil
    var providerReportedOutputSeconds: Double? = nil
    var inputTokens: Int? = nil
    var outputTokens: Int? = nil
    /// Preserve unclassified provider samples without assuming that they add.
    var observations: [InterpretationUsageObservation]? = nil
    var observationCount: Int? = nil
    var estimatedCostUSD: Double? = nil
    var priceVersion = "2026-10-01"
    var measurementSource = "observed" // observed / providerReported / unknown; never a bill
    var status = "running"
    var updatedAt = Date()
}

enum InterpretationRecordValidation {
    static let collections: Set<String> = ["interpretation-runtime", "interpretation-captions", "interpretation-usage"]
    static let opaqueFields: Set<String> = ["providerItemReference", "providerEventReference", "eventID", "modelID", "originalText"]

    static func runtime(_ value: InterpretationRuntimeRecord) throws {
        guard value.version == 1, UUID(uuidString: value.sessionID) != nil,
              ["googleOnline", "openAIOnline"].contains(value.mode), ["google", "openAI"].contains(value.provider),
              !value.modelID.isEmpty, value.modelID.utf8.count <= 256,
              !value.modelID.contains(where: { $0.isWhitespace || $0.isNewline }),
              ["en", "ja"].contains(value.sourceLanguage), !value.targetLanguage.isEmpty,
              ["zh-Hans", "zh-Hant"].contains(value.subtitleLanguage), value.generation >= 0,
              ["idle", "connecting", "running", "reconnecting", "pausing", "paused", "ending", "finishing", "ended", "failed", "interrupted"].contains(value.state),
              value.errorCode.map({ $0.utf8.count <= 128 && $0.range(of: "^[A-Za-z0-9._-]+$", options: .regularExpression) != nil }) ?? true
        else { throw LibraryError.message("interpretation.invalidRecord") }
    }

    static func caption(_ value: InterpretationCaptionRecord) throws {
        guard value.version == 1, UUID(uuidString: value.id) != nil, UUID(uuidString: value.sessionID) != nil,
              value.generation >= 0, ["source", "translation"].contains(value.track), value.revision > 0,
              !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.text.utf8.count <= 1_000_000,
              value.originalText.map({ $0.utf8.count <= 1_000_000 }) ?? true,
              !value.language.isEmpty, value.language.utf8.count <= 64, value.receivedAtMS >= 0,
              value.providerElapsedMS.map({ $0 >= 0 }) ?? true,
              ["provider", "estimated", "receiveTime", "unknown"].contains(value.timingSource),
              ["streaming", "provider", "localBoundary", "sessionClosed", "interrupted"].contains(value.completionBasis),
              value.startMS.map({ $0 >= 0 }) ?? true, value.endMS.map({ $0 >= (value.startMS ?? 0) }) ?? true,
              value.providerItemReference.map({ $0.utf8.count <= 1024 }) ?? true,
              value.providerEventReference.map({ $0.utf8.count <= 1024 }) ?? true,
              value.timingSource != "unknown" || (value.startMS == nil && value.endMS == nil)
        else { throw LibraryError.message("interpretation.invalidRecord") }
    }

    static func usage(_ value: InterpretationUsageRecord) throws {
        let seconds = [value.uploadedSeconds, value.generatedSeconds, value.playedSeconds, value.connectionSeconds] +
            [value.providerReportedInputSeconds, value.providerReportedOutputSeconds, value.estimatedCostUSD].compactMap { $0 }
        guard value.version == 1, UUID(uuidString: value.id) != nil, UUID(uuidString: value.sessionID) != nil,
              value.generation >= 0, ["google", "openAI"].contains(value.provider), !value.modelID.isEmpty,
              seconds.allSatisfy({ $0.isFinite && $0 >= 0 }), value.inputTokens.map({ $0 >= 0 }) ?? true,
              value.outputTokens.map({ $0 >= 0 }) ?? true,
              value.observations.map({ $0.count <= 128 && $0.allSatisfy { observation in
                  (observation.inputTokens.map { $0 >= 0 } ?? true) &&
                  (observation.outputTokens.map { $0 >= 0 } ?? true) &&
                  (observation.totalTokens.map { $0 >= 0 } ?? true) &&
                  (observation.eventID.map { $0.utf8.count <= 1024 } ?? true)
              } }) ?? true,
              value.observationCount.map({ $0 >= (value.observations?.count ?? 0) }) ?? true,
              ["observed", "providerReported", "unknown"].contains(value.measurementSource),
              ["running", "completed", "interrupted", "unknown"].contains(value.status)
        else { throw LibraryError.message("interpretation.invalidRecord") }
    }

    static func portable(_ record: PortableRecord, sessionExists: (String) -> Bool) throws {
        guard collections.contains(record.collection) else { return }
        guard sessionExists(record.ownerID) else { throw LibraryError.message("interpretation.invalidRecord") }
        let bytes = Data(record.json.utf8), decoder = JSONDecoder()
        switch record.collection {
        case "interpretation-runtime":
            let value = try decoder.decode(InterpretationRuntimeRecord.self, from: bytes)
            try runtime(value)
            guard value.id == record.id, value.sessionID == record.ownerID else { throw LibraryError.message("interpretation.invalidRecord") }
        case "interpretation-captions":
            let value = try decoder.decode(InterpretationCaptionRecord.self, from: bytes)
            try caption(value)
            guard value.id == record.id, value.sessionID == record.ownerID else { throw LibraryError.message("interpretation.invalidRecord") }
        default:
            let value = try decoder.decode(InterpretationUsageRecord.self, from: bytes)
            try usage(value)
            guard value.id == record.id, value.sessionID == record.ownerID else { throw LibraryError.message("interpretation.invalidRecord") }
        }
    }

    /// Imported runs are historical facts, never a command to reopen a socket.
    static func suspend(_ bytes: Data, collection: String) throws -> Data {
        if collection == "interpretation-runtime" {
            var value = try JSONDecoder().decode(InterpretationRuntimeRecord.self, from: bytes)
            if value.state != "ended" && value.state != "idle" {
                value.state = "interrupted"; value.closeComplete = false; value.errorCode = "restoredRequestOutcomeUnknown"
            }
            return try JSONEncoder().encode(value)
        }
        if collection == "interpretation-usage" {
            var value = try JSONDecoder().decode(InterpretationUsageRecord.self, from: bytes)
            if value.status == "running" { value.status = "interrupted" }
            return try JSONEncoder().encode(value)
        }
        return bytes
    }
}

extension LibraryStore {
    func interpretationRuntime(sessionID: String) throws -> InterpretationRuntimeRecord? {
        try record(collection: "interpretation-runtime", id: sessionID, as: InterpretationRuntimeRecord.self)
    }
    func saveInterpretationRuntime(_ value: InterpretationRuntimeRecord) throws {
        try InterpretationRecordValidation.runtime(value)
        try withTransaction {
            guard try item(id: value.sessionID)?.kind == .classroom else { throw LibraryError.message("interpretation.invalidRecord") }
            if let old = try interpretationRuntime(sessionID: value.sessionID) {
                guard value.generation >= old.generation else { return }
                guard old.state != "ended" || value.state == "ended" else { throw LibraryError.message("interpretation.sessionEnded") }
            }
            try putRecord(collection: "interpretation-runtime", id: value.id, ownerID: value.sessionID, value: value)
        }
    }
    func interpretationCaptions(sessionID: String) throws -> [InterpretationCaptionRecord] {
        try records(collection: "interpretation-captions", ownerID: sessionID, as: InterpretationCaptionRecord.self).sorted {
            if $0.receivedAtMS != $1.receivedAtMS { return $0.receivedAtMS < $1.receivedAtMS }
            if $0.sequence != $1.sequence { return $0.sequence < $1.sequence }
            return $0.id < $1.id
        }
    }
    func saveInterpretationCaption(_ value: InterpretationCaptionRecord) throws {
        try InterpretationRecordValidation.caption(value)
        try withTransaction {
            guard try item(id: value.sessionID)?.kind == .classroom else { throw LibraryError.message("interpretation.invalidRecord") }
            if let old = try record(collection: "interpretation-captions", id: value.id, as: InterpretationCaptionRecord.self) {
                guard old.sessionID == value.sessionID, old.generation == value.generation, old.track == value.track else { throw LibraryError.message("interpretation.invalidRecord") }
                if value.revision < old.revision { return }
                if value.revision == old.revision {
                    guard value == old else { throw LibraryError.message("interpretation.conflictingCaption") }
                    return
                }
                guard !old.isFinal || value.isFinal else { return }
            }
            try putRecord(collection: "interpretation-captions", id: value.id, ownerID: value.sessionID, value: value)
        }
    }
    func interpretationUsage(sessionID: String? = nil) throws -> [InterpretationUsageRecord] {
        try records(collection: "interpretation-usage", ownerID: sessionID, as: InterpretationUsageRecord.self).sorted { $0.updatedAt < $1.updatedAt }
    }
    func saveInterpretationUsage(_ value: InterpretationUsageRecord) throws {
        try InterpretationRecordValidation.usage(value)
        try withTransaction {
            guard try item(id: value.sessionID)?.kind == .classroom else { throw LibraryError.message("interpretation.invalidRecord") }
            if let old = try record(collection: "interpretation-usage", id: value.id, as: InterpretationUsageRecord.self) {
                guard old.sessionID == value.sessionID, old.generation == value.generation, old.provider == value.provider, old.modelID == value.modelID else { throw LibraryError.message("interpretation.invalidRecord") }
                if old.updatedAt > value.updatedAt { return }
            }
            try putRecord(collection: "interpretation-usage", id: value.id, ownerID: value.sessionID, value: value)
        }
    }
}
