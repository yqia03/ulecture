import Foundation

/// User choices are stored separately from immutable extracted facts. Empty
/// bounds mean unrestricted; nil version means the current saved note at send.
struct AssistantSourceScope: Codable, Equatable, Identifiable {
    let documentID: String
    let kind: AssistantSourceKind
    var startTime = ""
    var endTime = ""
    var version: Int? = nil
    var sourceHash: String? = nil
    var id: String { kind.rawValue + ":" + documentID }
    func transcriptRange() throws -> (start: Int64?, end: Int64?) {
        let start = try Self.milliseconds(startTime), end = try Self.milliseconds(endTime)
        guard start == nil || end == nil || end! > start! else { throw DocumentFailure.message("invalidTranscriptRange") }
        return (start, end)
    }
    static func milliseconds(_ input: String) throws -> Int64? {
        let input = input.trimmingCharacters(in: .whitespacesAndNewlines)
        if input.isEmpty { return nil }
        let pieces = input.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...3).contains(pieces.count), pieces.allSatisfy({ !$0.isEmpty && $0.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) }) else { throw DocumentFailure.message("invalidTranscriptRange") }
        var seconds = 0.0
        for (index, piece) in pieces.enumerated() {
            guard let value = Double(piece), value.isFinite, value >= 0,
                  index == pieces.count - 1 || value.rounded(.down) == value,
                  pieces.count == 1 || index == 0 || value < 60 else { throw DocumentFailure.message("invalidTranscriptRange") }
            seconds = seconds * 60 + value
        }
        // A generous, exact conversion bound also rejects overflow/Infinity.
        guard seconds.isFinite, seconds <= 315_576_000 else { throw DocumentFailure.message("invalidTranscriptRange") }
        return Int64((seconds * 1000).rounded())
    }
}
struct AssistantNoteVersion: Identifiable {
    let version: Int
    let sourceHash: String
    let savedAt: Date
    var id: Int { version }
}
struct AssistantSourceDetails {
    var versions: [AssistantNoteVersion] = []
    var firstMS: Int64? = nil
    var lastMS: Int64? = nil
    var error: String? = nil
}
