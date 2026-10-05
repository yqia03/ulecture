import Foundation
import Combine

@main struct ServiceIsolationChecks {
    @MainActor static func main() async throws {
        var checks: [String] = []
        func check(_ value: @autoclosure () -> Bool, _ label: String) throws {
            guard value() else { throw NSError(domain: "ServiceIsolationChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            checks.append(label)
        }
        let suite = "ulecture.service-isolation." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        let credentials = FeatureCredentials()
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FeatureNetwork.self]
        let session = URLSession(configuration: config)
        defer { defaults.removePersistentDomain(forName: suite); session.invalidateAndCancel() }
        FeatureNetwork.reset { _ in throw URLError(.unsupportedURL) }
        let ai = CloudServiceSettings(credentials: credentials, session: session, defaults: defaults)
        let text = CloudServiceSettings(credentials: credentials, session: session, defaults: defaults, scope: "textTranslation", sharedService: ai)
        let document = CloudServiceSettings(credentials: credentials, session: session, defaults: defaults, scope: "documentTranslation", sharedService: ai)
        try check(ai.configuration.provider == .geminiDeveloper && text.configuration.provider == .geminiDeveloper && document.configuration.provider == .geminiDeveloper, "new settings use Google AI Studio Developer API")
        try check(!text.usesSharedService && !document.usesSharedService && credentials.reads == 0 && credentials.metadataReads == 0 && FeatureNetwork.count == 0, "translation services default to independent without credential reads or network")
        try ai.saveCredential("fixture-ai"); try ai.updateModel("gemini-ai-custom")
        do { _ = try text.authorize(); throw CloudFailure.malformedResponse } catch CloudFailure.missingCredential { }
        do { _ = try document.authorize(); throw CloudFailure.malformedResponse } catch CloudFailure.missingCredential { }
        try check(text.status == .unconfigured && document.status == .unconfigured, "main AI key is never an implicit translation fallback")
        try text.saveCredential("fixture-text"); try text.updateModel("gemini-text-custom")
        try document.saveCredential("fixture-document"); try document.updateModel("gemini-document-custom")
        try check(Set([ai.configuration.credentialReference, text.configuration.credentialReference, document.configuration.credentialReference]).count == 3 && credentials.values.count == 3, "same provider has distinct keychain accounts for all three services")
        func reply(_ request: URLRequest) throws -> FeatureNetwork.Reply {
            let json: [String: Any] = ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": "{\"ok\":true}"]]]]], "usageMetadata": ["promptTokenCount": 2, "candidatesTokenCount": 3]]
            return FeatureNetwork.Reply(data: try JSONSerialization.data(withJSONObject: json))
        }
        FeatureNetwork.reset { try reply($0) }
        for settings in [ai, text, document] { await settings.testConnection() }
        let requests = FeatureNetwork.requests
        try check(requests.map { $0.value(forHTTPHeaderField: "x-goog-api-key") ?? "" } == ["fixture-ai", "fixture-text", "fixture-document"], "connection tests send each service's own key at the real HTTP boundary")
        try check(requests.map { $0.url!.path }.elementsEqual(["gemini-ai-custom", "gemini-text-custom", "gemini-document-custom"].map { "/v1beta/models/\($0):generateContent" }), "each service sends its selected model to AI Studio")
        try check([ai, text, document].allSatisfy { $0.status == .requestSucceeded }, "each service has independent verification state")
        var publications = 0
        let subscription = text.objectWillChange.sink { publications += 1 }
        text.refreshCredentialStatus(); text.refreshCredentialStatus()
        try check(publications == 0, "unchanged key presence refresh does not redraw settings")
        withExtendedLifetime(subscription) { }
        let oldIndependent = try text.authorize()
        text.setUsesSharedService(true)
        let shared = try text.authorize()
        try check(shared.dispatch.configuration == ai.configuration && text.selectedModel == ai.selectedModel && text.effectiveStatus == ai.status, "explicit follow AI choice binds model key provider and status")
        try ai.updateModel("gemini-new-ai")
        try check(text.selectedModel == "gemini-new-ai" && document.selectedModel == "gemini-document-custom", "AI changes affect opted-in text service only")
        _ = try await text.perform(shared, instruction: "Return JSON", input: "old request")
        _ = try await text.perform(oldIndependent, instruction: "Return JSON", input: "old independent request")
        try check(FeatureNetwork.requests.suffix(2).map { $0.value(forHTTPHeaderField: "x-goog-api-key") ?? "" } == ["fixture-ai", "fixture-text"], "already-authorized dispatches preserve their original key through sharing changes")
        try check(ai.status == .savedUnverified, "stale authorization cannot verify an edited shared model")
        let savedText = CloudServiceSettings(credentials: credentials, session: session, defaults: defaults, scope: "textTranslation", sharedService: ai)
        try check(savedText.usesSharedService && savedText.selectedModel == ai.selectedModel, "explicit sharing choice persists across restart")
        savedText.setUsesSharedService(false)
        try check(savedText.selectedModel == "gemini-text-custom" && savedText.configuration.credentialReference == text.configuration.credentialReference, "turning sharing off restores the independent model and key")
        try savedText.removeCredential()
        try check(credentials.values[ai.configuration.credentialReference] == "fixture-ai" && credentials.values[document.configuration.credentialReference] == "fixture-document", "removing text key cannot delete AI or document keys")
        do { _ = try document.credential(for: ai.configuration); throw CloudFailure.malformedResponse } catch CloudFailure.invalidConfiguration { }
        try check(true, "a foreign credential scope is rejected")
        try document.selectProvider(.deepSeek); try document.updateModel("deepseek-custom"); try document.saveCredential("fixture-deepseek")
        try document.selectProvider(.geminiDeveloper)
        try check(document.selectedModel == "gemini-document-custom", "switching providers preserves each provider's model settings")
        try document.selectProvider(.openAICompatible)
        try document.updateOptions(model: "vendor/custom-model", baseURL: "https://one.example/v1/")
        try document.saveCredential("fixture-compatible")
        let oldReference = document.configuration.credentialReference
        try document.updateBaseURL("https://two.example/v1")
        try check(document.status == .unconfigured && document.configuration.credentialReference != oldReference, "changing compatible endpoint never reuses another endpoint's key")
        do { _ = try document.authorize(); throw CloudFailure.malformedResponse } catch CloudFailure.missingCredential { }
        try document.updateBaseURL("https://one.example/v1")
        try check(document.status == .savedUnverified && document.configuration.credentialReference == oldReference, "returning to a normalized endpoint rediscovers its own key")
        let restored = CloudServiceSettings(credentials: credentials, session: session, defaults: defaults, scope: "documentTranslation", sharedService: ai)
        try check(restored.selectedModel == "vendor/custom-model" && restored.configuration.baseURL == document.configuration.baseURL && !restored.usesSharedService, "independent provider model endpoint and scope survive restart")
        for key in ["ulecture.cloud-settings.v1", "ulecture.cloud-settings.textTranslation.v1", "ulecture.cloud-settings.documentTranslation.v1"] {
            try check(!(defaults.data(forKey: key).map { String(decoding: $0, as: UTF8.self).contains("fixture-") } ?? true), "\(key) persists no credential values")
        }
        let migrationSuite = suite + ".migration", migrationDefaults = UserDefaults(suiteName: migrationSuite)!
        defer { migrationDefaults.removePersistentDomain(forName: migrationSuite) }
        let oldRecord = Data("{\"configuration\":{\"provider\":\"googleCloudExpress\",\"projectID\":\"\",\"location\":\"global\",\"version\":4},\"knownSaved\":[\"googleCloudExpress\"]}".utf8)
        migrationDefaults.set(oldRecord, forKey: "ulecture.cloud-settings.v1")
        let beforeReads = credentials.reads
        let migrated = CloudServiceSettings(credentials: credentials, session: session, defaults: migrationDefaults)
        try check(migrated.configuration.provider == .geminiDeveloper && migrated.status == .unconfigured && migrated.legacyConfiguration?.provider == .googleCloudExpress && credentials.reads == beforeReads, "Express settings migrate to unconfigured AI Studio without reusing or reading Express key")
        let developerRecord = Data("{\"configuration\":{\"provider\":\"geminiDeveloper\",\"projectID\":\"\",\"location\":\"global\",\"version\":2},\"knownSaved\":[\"geminiDeveloper\"]}".utf8)
        migrationDefaults.set(developerRecord, forKey: "ulecture.cloud-settings.v1")
        let developer = CloudServiceSettings(credentials: credentials, session: session, defaults: migrationDefaults)
        try check(developer.configuration.provider == .geminiDeveloper && developer.configuration.credentialReference == "classroom.geminiDeveloper", "existing AI Studio key reference remains compatible")
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks, "realCredentialReads": 0, "realProviderRequests": 0], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
