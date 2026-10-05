import Foundation
import CryptoKit

enum CloudProvider: String, Codable, CaseIterable, Identifiable {
    case openAI, geminiDeveloper, deepSeek, openAICompatible, googleCloudStandard, googleCloudExpress
    // Keep old Google Cloud dispatches readable without treating their keys as
    // Gemini Developer credentials. AI Studio uses the Developer API.
    static let selectable: [CloudProvider] = [.geminiDeveloper, .deepSeek, .openAICompatible, .openAI]
    var isSelectable: Bool { Self.selectable.contains(self) }
    var usesChatCompletions: Bool { self == .deepSeek || self == .openAICompatible }
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .openAI: return "OpenAI"
        case .geminiDeveloper: return "Google Gemini · AI Studio"
        case .deepSeek: return "DeepSeek"
        case .openAICompatible: return "OpenAI 兼容 API"
        case .googleCloudStandard: return "Google Cloud · Standard"
        case .googleCloudExpress: return "Google Cloud · Express（旧配置）"
        }
    }
    var credentialLabel: String { self == .googleCloudStandard ? "OAuth access token / service-account JSON" : "API key" }
}

struct CloudConfiguration: Codable, Equatable {
    var provider: CloudProvider = .geminiDeveloper
    var projectID: String = ""
    var location: String = "global"
    var version: Int = 1
    var model: String? = nil
    var baseURL: String? = nil
    var credentialScope: String? = nil
    // This is a reference only. No credential values enter Codable records.
    var credentialReference: String {
        let scope = credentialScope.map { $0 + "." } ?? ""
        let endpoint = provider == .openAICompatible ? "." + cloudHash(resolvedBaseURL) : ""
        return "classroom.\(scope)\(provider.rawValue)\(endpoint)"
    }
    var resolvedModel: String {
        let value = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return value.isEmpty ? CloudModelPreset.current(for: provider).model : value
    }
    var resolvedBaseURL: String {
        let value = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let supplied = value.isEmpty ? "https://api.openai.com/v1" : value
        guard var parts = URLComponents(string: supplied) else { return supplied }
        parts.scheme = parts.scheme?.lowercased(); parts.host = parts.host?.lowercased()
        while parts.path.hasSuffix("/") { parts.path.removeLast() }
        if (parts.scheme == "https" && parts.port == 443) || (parts.scheme == "http" && parts.port == 80) { parts.port = nil }
        return parts.string ?? supplied
    }
    func validated() throws -> Self {
        try Self.validateModel(resolvedModel, provider: provider)
        if let credentialScope, credentialScope.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) == nil { throw CloudFailure.invalidConfiguration }
        if provider == .openAICompatible {
            let supplied = baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !supplied.contains(where: { $0.isWhitespace || $0.isNewline }),
                  let parts = URLComponents(string: resolvedBaseURL), let host = parts.host, !host.isEmpty,
                  parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
                  parts.port.map({ (1...65535).contains($0) }) ?? true,
                  parts.scheme == "https" || (parts.scheme == "http" && ["localhost", "127.0.0.1", "::1", "[::1]"].contains(host)),
                  parts.url != nil else { throw CloudFailure.invalidConfiguration }
        }
        if provider == .googleCloudStandard {
            guard projectID.range(of: "^[a-z][a-z0-9-]{4,61}[a-z0-9]$", options: .regularExpression) != nil,
                  location.range(of: "^[a-z][a-z0-9-]{1,30}$", options: .regularExpression) != nil else { throw CloudFailure.invalidConfiguration }
        }
        var result = self
        result.model = resolvedModel
        if provider == .openAICompatible { result.baseURL = resolvedBaseURL }
        return result
    }
    static func validateModel(_ model: String, provider: CloudProvider) throws {
        guard !model.isEmpty, model.utf8.count <= 256, !model.contains(where: { $0.isWhitespace || $0.isNewline }),
              model.unicodeScalars.allSatisfy({ !CharacterSet.controlCharacters.contains($0) }) else { throw CloudFailure.invalidConfiguration }
        if !provider.usesChatCompletions && provider != .openAI {
            guard model.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$", options: .regularExpression) != nil else { throw CloudFailure.invalidConfiguration }
        }
    }
}

struct CloudModelPreset: Codable, Equatable {
    let model: String
    let version: String
    let reviewedOn: String
    let reviewBefore: String
    let accountVerified: Bool
    var retiredOn: String? = nil
    static func current(for provider: CloudProvider) -> CloudModelPreset {
        let model: String
        switch provider {
        case .openAI, .openAICompatible: model = "gpt-5.4-mini-2026-03-17"
        case .deepSeek: model = "deepseek-flash"
        case .geminiDeveloper: model = "gemini-3.8-flash"
        case .googleCloudExpress: model = "gemini-3.5-flash"
        case .googleCloudStandard: model = "gemini-3.5-flash-lite"
        }
        return CloudModelPreset(model: model, version: "2026-10-01.1", reviewedOn: "2026-10-01", reviewBefore: "2026-10-15", accountVerified: false)
    }
    static func current(for configuration: CloudConfiguration) -> CloudModelPreset {
        let preset = current(for: configuration.provider)
        return CloudModelPreset(model: configuration.resolvedModel, version: preset.version, reviewedOn: preset.reviewedOn, reviewBefore: preset.reviewBefore, accountVerified: false)
    }
    // A maintenance review date is not a provider shutdown date. Older saved
    // snapshots have no retiredOn and must not stop working after two weeks.
    var reviewDue: Bool { Self.date(reviewBefore).map { Date() >= $0 } ?? true }
    var isExpired: Bool { retiredOn.flatMap(Self.date).map { Date() >= $0 } ?? false }
    private static func date(_ value: String) -> Date? { let f = ISO8601DateFormatter(); return f.date(from: value + "T00:00:00Z") }
}

struct CloudSegment: Codable, Identifiable, Equatable {
    var id: String
    var classID: String
    var revision: Int
    var text: String
    var language: String
    var startMS: Int64
    var endMS: Int64
    var confirmedAt: Date
}

enum CloudJobStatus: String, Codable { case waitingConfiguration, waitingNetwork, queued, running, retryWaiting, saving, completed, needsAttention, obsolete }
struct CloudDispatch: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var version: Int
    var configuration: CloudConfiguration
    var preset: CloudModelPreset
    var sentAt: Date
}
struct CloudUsage: Codable, Identifiable, Equatable {
    var id: String
    var provider: CloudProvider
    var model: String
    var inputTokens: Int?
    var outputTokens: Int?
    var status: String // providerReported, unknown, responseLost
    var at: Date
    var costLabel: String { "费用未知；用量并非账单或硬性预算上限" }
}
struct CloudTranslation: Codable, Identifiable, Equatable {
    var id: String
    var segmentID: String
    var classID: String
    var sourceRevision: Int
    var targetLanguage: String
    var text: String
    var dispatch: CloudDispatch
    var savedAt: Date
    var historical: Bool
}
struct CloudTranslationJob: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var segment: CloudSegment
    var targetLanguage: String
    var status: CloudJobStatus = .waitingConfiguration
    var historical: Bool = false
    var attempts: Int = 0
    var dispatchVersion: Int = 0
    var dispatches: [CloudDispatch] = []
    var nextAttemptAt: Date?
    var errorCode: String?
    var translation: CloudTranslation?
    var terminology: ClassroomTerminologySnapshot? = nil
    // nil identifies pre-terminology checkpoints; they retain their original
    // no-glossary behavior. Only new, never-dispatched jobs may capture a table.
    var terminologyFrozen: Bool? = false
}

struct ClassroomTerminologySnapshot: Codable, Equatable {
    var scopeID: String
    var revision: Int
    var terms: [TranslationTerm]
    var promptVersion: String = "classroom-terminology-1"
    func validated() throws -> Self {
        guard !scopeID.isEmpty, revision > 0, terms.count <= 5000, promptVersion == "classroom-terminology-1" else { throw CloudFailure.invalidConfiguration }
        let checked = try terms.map { try $0.validated() }
        guard checked.allSatisfy({ $0.scopeID == scopeID && $0.enabled }), Set(checked.map(\.conflictKey)).count == checked.count else { throw CloudFailure.invalidConfiguration }
        return self
    }
}

enum SummarySourceKind: String, Codable { case pdf, transcript, note }
struct SummarySource: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var kind: SummarySourceKind
    var entityID: String
    var version: Int
    var text: String
    var page: Int? = nil
    var startMS: Int64? = nil
    var endMS: Int64? = nil
    var hash: String { cloudHash(text) }
    var isValid: Bool {
        guard !entityID.isEmpty, version > 0, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        switch kind {
        case .pdf: return (page ?? 0) > 0
        case .transcript: return startMS != nil && endMS != nil && startMS! >= 0 && endMS! >= startMS!
        case .note: return true
        }
    }
}
struct SummarySnapshot: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var classID: String
    var createdAt: Date = Date()
    var targetLanguage: String = "zh-Hans"
    var sources: [SummarySource]
    var excluded: [String] = []
    var hash: String { cloudHash(sources.map { $0.hash }.joined(separator: "\n")) }
}
struct SummaryClaim: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var text: String
    var referenceIDs: [String]
}
struct SummaryCoverageSpan: Codable, Equatable {
    var sourceID: String
    var startCharacter: Int
    var characterCount: Int
}
struct SummaryChunkCoverage: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var spans: [SummaryCoverageSpan]
    var status: String = "pending"
}
struct CloudSummary: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var snapshot: SummarySnapshot
    var dispatch: CloudDispatch
    var dispatches: [CloudDispatch]? = nil
    var claims: [SummaryClaim] = []
    var chunks: [SummaryChunkCoverage] = []
    var completedChunkIDs: [String] = []
    var missingChunkIDs: [String] = []
    var invalidReferenceCount: Int = 0
    var status: String = "running"
    var errorCode: String?
    var createdAt: Date = Date()
    var markdown: String {
        "# AI 生成总结\n\n" + claims.map { "- " + $0.text + ($0.referenceIDs.isEmpty ? "（无可核实引用）" : " " + $0.referenceIDs.map { "[来源 \($0)]" }.joined(separator: " ")) }.joined(separator: "\n\n")
    }
    func source(for referenceID: String) -> SummarySource? { snapshot.sources.first { $0.id == referenceID && $0.isValid } }
}
struct CloudState: Codable, Equatable {
    var classID: String
    var translationUserPaused: Bool = false
    var jobs: [CloudTranslationJob] = []
    var summaries: [CloudSummary] = []
    var usage: [CloudUsage] = []
    var isolatedLateResponses: Int = 0
    var terminologySelection: ClassroomTerminologySnapshot? = nil
}
func cloudHash(_ text: String) -> String { SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined() }

enum CloudFailure: String, Error, Codable, LocalizedError {
    case missingCredential, invalidConfiguration, expiredPreset, network, authentication, permission, quota, rateLimited, unavailable, malformedResponse, cancelled, persistence, queueFull, noMaterials, responseTooLarge, incompatibleCheckpoint
    var errorDescription: String? {
        switch self {
        case .missingCredential: return "尚未保存当前服务的 API Key"
        case .invalidConfiguration: return "服务、模型或 API 地址设置无效"
        case .expiredPreset: return "模型已停用，请更新应用预设后重试"
        case .network: return "连接失败，原文保留；有限重试后需手动处理"
        case .authentication: return "凭据无效或已过期，请在设置中替换"
        case .permission: return "服务拒绝访问，请核对权限及地区资格"
        case .quota: return "额度或计费不可用，请查看服务账户"
        case .rateLimited: return "请求受限，正在等待有限重试"
        case .unavailable: return "当前服务或模型暂不可用"
        case .malformedResponse: return "响应缺失、被截断或无法与来源可靠对应"
        case .cancelled: return "已取消；已发送的请求仍可能计费"
        case .persistence: return "结果未能保存；已停止派发，保留内存草稿供恢复"
        case .queueFull: return "待翻译队列已达上限；原文保留，处理后可补译"
        case .noMaterials: return "没有可用的已保存课堂文字资料"
        case .responseTooLarge: return "材料或响应超出本次处理上限，未处理范围已保留"
        case .incompatibleCheckpoint: return "此任务使用旧处理版本；已有结果保留，请新建翻译任务"
        }
    }
    var isRetryable: Bool { [.network, .rateLimited, .unavailable].contains(self) }
}
struct CloudRequestError: Error { var failure: CloudFailure; var retryAfter: TimeInterval? = nil }
