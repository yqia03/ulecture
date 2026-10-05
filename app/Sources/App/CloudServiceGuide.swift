import SwiftUI

struct CloudServiceGuide: View {
    let provider: CloudProvider
    var language: String = "en"
    private func t(_ key: String) -> String { CloudViewText.t(key, language) }
    private var documentation: URL {
        let address: String
        switch provider {
        case .openAI: address = "https://developers.openai.com/api/docs/quickstart"
        case .deepSeek: address = "https://api-docs.deepseek.com/"
        case .openAICompatible: address = "https://developers.openai.com/api/reference/resources/chat/subresources/completions/methods/create"
        case .geminiDeveloper: address = "https://ai.google.dev/gemini-api/docs/api-key"
        case .googleCloudStandard: address = "https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/start/gcp-auth"
        case .googleCloudExpress: address = "https://docs.cloud.google.com/gemini-enterprise-agent-platform/models/start/express-mode/overview"
        }
        return URL(string: address)!
    }
    private var guideKey: String {
        switch provider {
        case .openAI: return "openaiGuide"
        case .deepSeek: return "deepseekGuide"
        case .openAICompatible: return "compatibleGuide"
        case .geminiDeveloper: return "geminiGuide"
        case .googleCloudStandard: return "standardGuide"
        case .googleCloudExpress: return "expressGuide"
        }
    }
    private var billing: URL? {
        switch provider {
        case .openAI: return URL(string: "https://platform.openai.com/settings/organization/billing/overview")
        case .deepSeek: return URL(string: "https://platform.deepseek.com/usage")
        case .geminiDeveloper: return URL(string: "https://ai.google.dev/gemini-api/docs/billing")
        case .googleCloudStandard, .googleCloudExpress: return URL(string: "https://console.cloud.google.com/billing")
        case .openAICompatible: return nil
        }
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(t("guide")).font(.headline)
            Text(t(guideKey)).font(.callout).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 16) {
                Link(t("official"), destination: documentation)
                if let billing { Link(t("billing"), destination: billing) }
                if provider == .openAI { Link(t("regions"), destination: URL(string: "https://developers.openai.com/api/docs/supported-countries")!) }
                if provider == .geminiDeveloper { Link(t("createAIStudioKey"), destination: URL(string: "https://aistudio.google.com/apikey")!) }
                if provider == .googleCloudExpress { Link(t("accountEligibility"), destination: URL(string: "https://cloud.google.com/resources/cloud-express-faqs")!) }
            }
            Text(t("usageHelp")).font(.caption).foregroundStyle(.secondary)
        }
    }
}
