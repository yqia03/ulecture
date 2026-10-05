import Foundation
import Combine

private final class InterpretationFixtureCredentials: CloudCredentialStore {
    var values = [String: String](), reads = 0, metadataReads = 0
    func save(_ value: String, reference: String) { values[reference] = value }
    func read(reference: String) -> String? { reads += 1; return values[reference] }
    func remove(reference: String) { values[reference] = nil }
    func contains(reference: String) -> Bool { metadataReads += 1; return values[reference] != nil }
}

@MainActor private final class InterpretationHandshakeProbe {
    var configs = [InterpretationSessionConfiguration](), keys = [String]()
    var suspend = false
    var continuation: CheckedContinuation<Void, Error>?
    func test(_ config: InterpretationSessionConfiguration, key: String) async throws {
        configs.append(config); keys.append(key)
        if suspend { try await withCheckedThrowingContinuation { continuation = $0 } }
    }
}

@main enum InterpretationSettingsChecks {
    @MainActor static func main() async throws {
        let suite = "ulecture.interpretation-settings-checks." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = InterpretationFixtureCredentials(), probe = InterpretationHandshakeProbe()
        let ai = CloudServiceSettings(credentials: credentials, defaults: defaults)
        let settings = InterpretationServiceSettings(mainAI: ai, credentials: credentials, defaults: defaults, tester: { try await probe.test($0, key: $1) })
        var checks = [String]()
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { throw InterpretationFailure.protocolViolation }; checks.append(label)
        }
        try check(credentials.reads == 0 && credentials.metadataReads == 0 && probe.configs.isEmpty, "construction reads no secret and sends no request")
        try ai.saveCredential("fixture-ai-secret")
        try settings.saveCredential("fixture-google-secret", for: .google)
        try settings.saveCredential("fixture-openai-secret", for: .openAI)
        try check(Set(credentials.values.keys).count == 3, "main AI and both interpretation providers have isolated Keychain references")
        await settings.testConnection(provider: .google)
        await settings.testConnection(provider: .openAI)
        try check(probe.keys == ["fixture-google-secret", "fixture-openai-secret"], "protocol handshakes use each provider's own saved key")
        try check(probe.configs.map(\.modelID) == [InterpretationProvider.google.defaultModelID, InterpretationProvider.openAI.defaultModelID], "translation models never inherit chat presets")
        var publications = 0
        let subscription = settings.objectWillChange.sink { publications += 1 }
        settings.refreshCredentialStatus(for: .google); settings.refreshCredentialStatus(for: .google)
        try check(publications == 0, "unchanged credential metadata does not republish UI state")
        try settings.setCredentialSource(.mainAI, for: .google)
        await settings.testConnection(provider: .google)
        try check(probe.keys.last == "fixture-ai-secret" && probe.configs.last?.modelID == InterpretationProvider.google.defaultModelID, "explicit reuse borrows only matching provider key")
        try ai.updateModel("gemini-chat-custom")
        try check(settings.profile(for: .google).modelID == InterpretationProvider.google.defaultModelID && settings.status(for: .google) == .savedUnverified, "main chat model changes never replace interpretation model or retain handshake success")
        try ai.selectProvider(.deepSeek)
        try check(settings.mainAIReuseReason(for: .google) == "mainAIUnsupportedProvider", "Chat Completions providers are visibly incompatible with realtime reuse")
        do { _ = try settings.authorize(provider: .google); throw CloudFailure.malformedResponse } catch InterpretationFailure.invalidConfiguration { }
        try check(probe.configs.count == 3, "incompatible source cannot dispatch a hidden fallback")
        try settings.setCredentialSource(.independent, for: .google)
        try settings.removeCredential(for: .google)
        try check(credentials.values["classroom.geminiDeveloper"] == "fixture-ai-secret" && credentials.values["classroom.interpretation.openAI"] == "fixture-openai-secret", "removing interpretation credential preserves main AI and other provider")
        try settings.saveCredential("fixture-google-secret-2", for: .google)
        probe.suspend = true
        let task = Task { await settings.testConnection(provider: .google) }
        while probe.continuation == nil { await Task.yield() }
        try settings.updateModel("gemini-custom-translate-preview", for: .google)
        probe.continuation?.resume(); probe.continuation = nil
        await task.value
        try check(settings.status(for: .google) == .savedUnverified, "late handshake cannot verify an edited model")
        let restored = InterpretationServiceSettings(mainAI: ai, credentials: credentials, defaults: defaults, tester: { try await probe.test($0, key: $1) })
        try check(restored.profile(for: .google).modelID == "gemini-custom-translate-preview" && restored.profile(for: .google).credentialSource == .independent, "provider profiles survive settings restart")
        let bytes = defaults.data(forKey: "ulecture.interpretation-settings.v1")!
        try check(!String(decoding: bytes, as: UTF8.self).contains("fixture-"), "settings persist no key values")
        withExtendedLifetime(subscription) {}
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks, "realServiceRequests": 0, "realKeychainReads": 0], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
