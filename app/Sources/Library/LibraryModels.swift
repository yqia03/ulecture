import Foundation

enum WorkspaceKind: String, Codable, CaseIterable { case course, folder, classroom, pdf, note }

struct WorkspaceItem: Codable, Identifiable, Hashable {
    var id: String
    var parentID: String?
    var courseID: String?
    var classroomID: String?
    var kind: WorkspaceKind
    var title: String
    var createdAt: Date
    var updatedAt: Date
    var deletedAt: Date?
    var assetID: String?
    var deletionGroup: String?
    /// Presentation order is independent from physical names and persisted across launches.
    var sortRank: Double?
}

struct ClassroomRecord: Codable, Identifiable, Equatable {
    var id: String
    var mainLanguage: String = "en"
    var targetLanguage: String = "zh-Hans"
    var state: String = "draft"
    var translationUserPaused: Bool = false
    var timelineMilliseconds: Int64 = 0
    var recordingEnabled: Bool = false
    var inputSource: String = "microphone"
    var inputDeviceID: String? = nil
    var updatedAt: Date = Date()
}

struct TranscriptRecord: Codable, Identifiable {
    var id: String
    var classroomID: String
    var epochID: String
    var startMS: Int64
    var endMS: Int64
    var text: String
    var language: String
    var revision: Int = 1
    var confirmedAt: Date = Date()
}

struct NoteRevision: Codable, Identifiable {
    var id: String
    var noteID: String
    var classroomID: String?
    var version: Int
    var markdown: String
    var savedAt: Date
}

struct PDFTextPage: Codable, Identifiable {
    var id: String { "\(assetID):\(version):\(pageNumber)" }
    var assetID: String
    var version: Int
    var pageNumber: Int
    var text: String
    var status: String
    var limitation: String = "仅提取文字；图片、扫描内容和图表未分析。"
}

struct ManagedAttachment: Codable, Identifiable {
    var id: String
    var ownerID: String
    var relativePath: String
    var originalName: String
    var mediaType: String
    var byteCount: Int64
    var sha256: String
    var createdAt: Date
}

struct TimelineGap: Codable, Identifiable {
    var id: String = UUID().uuidString
    var classroomID: String
    var epochID: String?
    var startMS: Int64
    var endMS: Int64?
    var reason: String
}

struct RecordingRecord: Codable, Identifiable {
    var id: String
    var classroomID: String
    var epochID: String
    var assetID: String
    var startMS: Int64
    var endMS: Int64
    var fileStartMS: Int64 = 0
    var integrity: String = "verified"
}

struct SessionAttachmentLocation: Codable {
    var assetID: String
    var sessionID: String
    var relativePath: String
}

enum LibraryError: LocalizedError {
    case message(String)
    var errorDescription: String? { switch self { case .message(let message): return message } }
}

struct LibraryBackupManifest: Codable {
    var format: String = "uway-portable-library"
    var version: Int = 1
    var exportedAt: Date
    var sourceLibraryID: String
    var rootItemID: String
    var items: [WorkspaceItem]
    var records: [PortableRecord]
    var attachments: [ManagedAttachment]
    var notice: String = "包含所选范围文字和受管附件；不含模型、账户凭据或原文件路径。恢复后云请求需重新由用户确认服务。"
}

struct PortableRecord: Codable {
    var collection: String
    var id: String
    var ownerID: String
    var json: String
}
