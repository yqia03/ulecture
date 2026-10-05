import Foundation

enum AssistantSourceKind: String, Codable, CaseIterable { case pdf, transcript, note, annotation, text, speakerNotes }
enum AssistantIntent: String, Codable, CaseIterable { case question, explain, notes, summary, latestQuestion }
struct AssistantSourceOption: Identifiable, Equatable {
    var id: String { kind.rawValue + ":" + documentID }
    let documentID: String, title: String
    let kind: AssistantSourceKind
}
struct AssistantSource: Codable, Identifiable {
    let id: String
    let documentID: String, title: String
    let kind: AssistantSourceKind
    let version: Int
    let sourceHash: String
    let text: String
    var page: Int? = nil
    var blockID: String? = nil
    var annotationID: String? = nil
    var startMS: Int64? = nil
    var endMS: Int64? = nil
    var startCharacter = 0
    /// A slide-note source hashes the original presentation; its page opens the
    /// separately frozen converted PDF instead of treating notes as page text.
    var navigationHash: String? = nil
    /// Retains the original confirmed record even after the classroom text is
    /// revised; archive restoration can remap identity without inventing a row.
    var transcriptSnapshot: TranscriptRecord? = nil
    var ocr: AssistantOCRProvenance? = nil
    var contentHash: String { DocumentDisk.hash(Data(text.utf8)) }
}
struct AssistantSnapshot: Codable, Identifiable {
    let id: String
    let capturedAt: Date
    let sources: [AssistantSource]
    let exclusions: [String]
    let cutoffMS: Int64?
    let classroomEnded: Bool
    var requestedScopes: [AssistantSourceScope]? = nil
    var pdfCoverage: [AssistantPDFPageCoverage]? = nil
    var hash: String { DocumentDisk.hash((try? DocumentDisk.json(sources)) ?? Data()) }
}
struct AssistantChunk: Codable, Identifiable {
    let id: String
    let sourceIDs: [String]
    var text = ""
    var status = "waiting"
}
struct AssistantRun: Codable, Identifiable {
    var id = UUID().uuidString
    var createdAt = Date()
    var dispatches: [CloudDispatch] = []
    var chunks: [AssistantChunk] = []
    var text = ""
    var state = "preparing"
    var errorCode: String? = nil
    var invalidCitations: [String] = []
}
struct AssistantTurn: Codable, Identifiable {
    var id = UUID().uuidString
    let conversationID: String
    let question: String
    let intent: AssistantIntent
    let responseLanguage: String
    let snapshotID: String
    var history: [AssistantHistory] = []
    var createdAt = Date()
    var runs: [AssistantRun] = []
}
struct AssistantHistory: Codable { let turnID: String; let question: String; let answer: String }
struct AssistantConversation: Codable, Identifiable {
    let id: String
    let contextID: String
    var selectedSourceIDs: [String] = []
    var turnIDs: [String] = []
    var updatedAt = Date()
    var sourceScopes: [AssistantSourceScope]? = nil
    var ocrLanguage: String? = nil
}
enum AssistantCitation {
    static func identifiers(in text: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: "\\[S([0-9]+)\\]") else { return [] }
        let raw = text as NSString
        return Array(Set(expression.matches(in: text, range: NSRange(location: 0, length: raw.length)).map { "S" + raw.substring(with: $0.range(at: 1)) })).sorted()
    }
    static func invalid(in text: String, sources: [AssistantSource]) -> [String] {
        let valid = Set(sources.map(\.id)); return identifiers(in: text).filter { !valid.contains($0) }
    }
}
