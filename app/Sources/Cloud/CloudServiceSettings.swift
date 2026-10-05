import Foundation
import Combine

enum CloudCredentialStatus: String, Codable {
    case unconfigured, savedUnverified, checking, requestSucceeded, failed
}

/// Deliberately not Codable: only dispatch metadata may enter persistent jobs.
struct CloudAuthorization: CustomDebugStringConvertible {
    let dispatch: CloudDispatch
    fileprivate let secret: String
    func subprocessInput(parameters: [String: Any]) throws -> Data {
        var request = parameters
        request["apiKey"] = secret
        return try JSONSerialization.data(withJSONObject: request, options: [.sortedKeys])
    }
    var debugDescription: String { "CloudAuthorization(\(dispatch.configuration.provider.rawValue), redacted)" }
}

@MainActor final class CloudServiceSettings: ObservableObject {
    @Published private(set) var configuration: CloudConfiguration
    @Published private(set) var status: CloudCredentialStatus = .unconfigured
    @Published private(set) var lastError: CloudFailure?
    @Published private(set) var usage: [CloudUsage] = []
    @Published private(set) var legacyConfiguration: CloudConfiguration?
    @Published private(set) var usesSharedService: Bool = false
    var onConfigurationChanged: ((CloudConfiguration) -> Void)?
    var onUsage: ((CloudUsage) -> Void)?
    private let credentials: CloudCredentialStore
    private let provider: CloudHTTPProvider
    private let defaults: UserDefaults
    private let storageKey: String
    private let scope: String?
    private let sharedService: CloudServiceSettings?
    private var sharedSubscription: AnyCancellable?
    private var knownSaved: Set<CloudProvider> = []
    private var providerConfigurations: [CloudProvider: CloudConfiguration] = [:]

    var effectiveConfiguration: CloudConfiguration { usesSharedService ? sharedService!.effectiveConfiguration : configuration }
    var effectiveStatus: CloudCredentialStatus { usesSharedService ? sharedService!.effectiveStatus : status }
    var effectiveLastError: CloudFailure? { usesSharedService ? sharedService!.effectiveLastError : lastError }
    var selectedModel: String { CloudModelPreset.current(for: effectiveConfiguration).model }

    private struct Record: Codable {
        var configuration: CloudConfiguration
        var knownSaved: Set<CloudProvider>
        var legacyConfiguration: CloudConfiguration?
        var usesSharedService: Bool? = nil
        var providerConfigurations: [CloudProvider: CloudConfiguration]? = nil
    }

    init(initialConfiguration: CloudConfiguration = CloudConfiguration(), credentials: CloudCredentialStore = KeychainCredentialStore(), session: URLSession? = nil, defaults: UserDefaults = .standard, scope: String? = nil, sharedService: CloudServiceSettings? = nil) {
        self.credentials = credentials; self.provider = CloudHTTPProvider(session: session); self.defaults = defaults
        self.scope = scope; self.sharedService = sharedService
        storageKey = scope.map { "ulecture.cloud-settings.\($0).v1" } ?? "ulecture.cloud-settings.v1"
        let saved = defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
        let original = saved?.configuration ?? initialConfiguration
        var current = original.provider.isSelectable ? original : CloudConfiguration(provider: .geminiDeveloper, version: original.version + 1)
        current.credentialScope = scope
        configuration = current
        legacyConfiguration = saved?.legacyConfiguration ?? (original.provider.isSelectable ? nil : original)
        knownSaved = saved?.knownSaved ?? []
        providerConfigurations = saved?.providerConfigurations ?? [:]
        usesSharedService = sharedService != nil && saved?.usesSharedService == true
        status = knownSaved.contains(configuration.provider) ? .savedUnverified : .unconfigured
        // Construction neither probes Keychain nor contacts a provider. Separate
        // scopes never copy or infer a key from the main AI configuration.
        sharedSubscription = sharedService?.objectWillChange.sink { [weak self] in
            guard let self, self.usesSharedService else { return }
            self.objectWillChange.send()
        }
    }

    func setUsesSharedService(_ enabled: Bool) {
        guard !enabled || sharedService != nil, enabled != usesSharedService else { return }
        usesSharedService = enabled
        persist(); onConfigurationChanged?(effectiveConfiguration)
    }

    func selectProvider(_ selection: CloudProvider) throws {
        guard selection.isSelectable, !usesSharedService else { throw CloudFailure.invalidConfiguration }
        guard selection != configuration.provider else { return }
        providerConfigurations[configuration.provider] = configuration
        var next = providerConfigurations[selection] ?? CloudConfiguration(provider: selection)
        next.version = configuration.version + 1; next.credentialScope = scope
        configuration = next
        status = knownSaved.contains(selection) ? .savedUnverified : .unconfigured
        lastError = nil; persist(); onConfigurationChanged?(configuration)
    }

    func updateModel(_ value: String) throws { try updateOptions(model: value, baseURL: configuration.baseURL ?? configuration.resolvedBaseURL) }
    func updateBaseURL(_ value: String) throws { try updateOptions(model: configuration.model ?? CloudModelPreset.current(for: configuration.provider).model, baseURL: value) }
    func updateOptions(model: String, baseURL: String?) throws {
        guard !usesSharedService else { throw CloudFailure.invalidConfiguration }
        var next = configuration
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CloudFailure.invalidConfiguration }
        next.model = trimmed
        next.baseURL = configuration.provider == .openAICompatible ? baseURL?.trimmingCharacters(in: .whitespacesAndNewlines) : nil
        next = try next.validated()
        guard next != configuration else { return }
        let endpointChanged = next.credentialReference != configuration.credentialReference
        next.version += 1; configuration = next
        lastError = nil
        if endpointChanged { status = .unconfigured; refreshCredentialStatus() }
        else { status = knownSaved.contains(configuration.provider) ? .savedUnverified : .unconfigured }
        provider.clearCredentialCache(); persist(); onConfigurationChanged?(configuration)
    }

    /// Metadata-only check; no secret is fetched to render settings.
    func refreshCredentialStatus() {
        if usesSharedService { sharedService?.refreshCredentialStatus(); return }
        do {
            if try credentials.contains(reference: configuration.credentialReference) { knownSaved.insert(configuration.provider) }
            else { knownSaved.remove(configuration.provider) }
            let next: CloudCredentialStatus
            if !knownSaved.contains(configuration.provider) { next = .unconfigured }
            else if status == .checking || status == .requestSucceeded || status == .failed { next = status }
            else { next = .savedUnverified }
            if status != next { status = next }
            persist()
        } catch {
            if lastError != .authentication { lastError = .authentication }
            if status != .failed { status = .failed }
        }
    }

    func saveCredential(_ input: String) throws {
        guard !usesSharedService else { throw CloudFailure.invalidConfiguration }
        _ = try configuration.validated()
        let secret = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { throw CloudFailure.missingCredential }
        guard secret.utf8.count <= 16_384, !secret.contains("\n"), !secret.contains("\r") else { throw CloudFailure.invalidConfiguration }
        try credentials.save(secret, reference: configuration.credentialReference)
        knownSaved.insert(configuration.provider); credentialsChanged()
        status = .savedUnverified; persist()
    }

    func removeCredential() throws {
        guard !usesSharedService else { throw CloudFailure.invalidConfiguration }
        try credentials.remove(reference: configuration.credentialReference)
        knownSaved.remove(configuration.provider); credentialsChanged()
        status = .unconfigured; persist()
    }

    private func credentialsChanged() {
        configuration.version += 1; lastError = nil
        provider.clearCredentialCache(); persist(); onConfigurationChanged?(configuration)
    }

    /// Used only by an authorized operation. No process-global/env/ADC fallback.
    func credential(for config: CloudConfiguration) throws -> String? {
        if usesSharedService { return try sharedService?.credential(for: config) }
        guard config.provider.isSelectable, config.provider == configuration.provider,
              config.credentialReference == configuration.credentialReference else { throw CloudFailure.invalidConfiguration }
        _ = try config.validated()
        guard let value = try credentials.read(reference: config.credentialReference), !value.isEmpty else {
            knownSaved.remove(config.provider); if status != .unconfigured { status = .unconfigured }; persist(); return nil
        }
        knownSaved.insert(config.provider)
        if status == .unconfigured { status = .savedUnverified }
        persist()
        return value
    }

    func authorize(version: Int = 1) throws -> CloudAuthorization {
        if usesSharedService { return try sharedService!.authorize(version: version) }
        _ = try configuration.validated()
        guard let secret = try credential(for: configuration) else { throw CloudFailure.missingCredential }
        let preset = CloudModelPreset.current(for: configuration)
        guard !preset.isExpired else { throw CloudFailure.expiredPreset }
        return CloudAuthorization(dispatch: CloudDispatch(version: version, configuration: configuration, preset: preset, sentAt: Date()), secret: secret)
    }

    /// Explicit key-only reuse by interpretation. Chat models, endpoints and
    /// request-success status are deliberately not inherited.
    func interpretationCredential(for provider: CloudProvider) throws -> String {
        guard provider == .geminiDeveloper || provider == .openAI,
              effectiveConfiguration.provider == provider else { throw CloudFailure.invalidConfiguration }
        guard let value = try credential(for: effectiveConfiguration) else { throw CloudFailure.missingCredential }
        return value
    }

    /// Key-only metadata lookup. A failed chat-model request says nothing about
    /// whether the same provider key can authenticate a translation handshake.
    func hasInterpretationCredential(for provider: CloudProvider) throws -> Bool {
        guard provider == .geminiDeveloper || provider == .openAI,
              effectiveConfiguration.provider == provider else { return false }
        if usesSharedService { return try sharedService!.hasInterpretationCredential(for: provider) }
        return try credentials.contains(reference: configuration.credentialReference)
    }

    func perform(_ authorization: CloudAuthorization, instruction: String, input: String, maxOutputTokens: Int = 4096, format: CloudResponseFormat = .json, priority: CloudRequestPriority = .interactive) async throws -> CloudTextResponse {
        do {
            let result = try await provider.perform(dispatch: authorization.dispatch, credential: authorization.secret, instruction: instruction, input: input, maxOutputTokens: maxOutputTokens, format: format, priority: priority)
            record(result.usage); updateStatus(for: authorization, failure: nil)
            return result
        } catch { recordFailure(authorization, error: error); throw error }
    }

    func stream(_ authorization: CloudAuthorization, instruction: String, input: String, maxOutputTokens: Int = 8192, onDelta: @escaping @MainActor (String) throws -> Void) async throws -> CloudTextResponse {
        do {
            let result = try await provider.stream(dispatch: authorization.dispatch, credential: authorization.secret, instruction: instruction, input: input, maxOutputTokens: maxOutputTokens, onDelta: onDelta)
            record(result.usage); updateStatus(for: authorization, failure: nil)
            return result
        } catch { recordFailure(authorization, error: error); throw error }
    }

    func testConnection() async {
        if usesSharedService { await sharedService?.testConnection(); return }
        let authorization: CloudAuthorization
        do { authorization = try authorize() }
        catch { lastError = cloudFailure(error); status = .failed; return }
        status = .checking; lastError = nil
        do {
            let result = try await perform(authorization, instruction: "Return only JSON {\"ok\":true}.", input: "Connection test", maxOutputTokens: 128)
            let data = try JSONSerialization.jsonObject(with: Data(result.text.utf8)) as? [String: Any]
            guard data?["ok"] as? Bool == true else { throw CloudFailure.malformedResponse }
        } catch { updateStatus(for: authorization, failure: cloudFailure(error)) }
    }

    private func updateStatus(for authorization: CloudAuthorization, failure: CloudFailure?) {
        if usesSharedService { sharedService?.updateStatus(for: authorization, failure: failure); return }
        guard authorization.dispatch.configuration == configuration else { return }
        let next: CloudCredentialStatus = failure == nil ? .requestSucceeded : .failed
        if status != next { status = next }
        if lastError != failure { lastError = failure }
    }
    func recordExternalUsage(_ authorization: CloudAuthorization, inputTokens: Int?, outputTokens: Int?, failure: CloudFailure? = nil) {
        record(CloudUsage(id: authorization.dispatch.id, provider: authorization.dispatch.configuration.provider, model: authorization.dispatch.preset.model, inputTokens: inputTokens, outputTokens: outputTokens, status: inputTokens == nil || outputTokens == nil ? "unknown" : "providerReported", at: Date()))
        updateStatus(for: authorization, failure: failure)
    }
    private func record(_ value: CloudUsage) { usage.append(value); onUsage?(value) }
    private func recordFailure(_ authorization: CloudAuthorization, error: Error) {
        record(CloudUsage(id: authorization.dispatch.id, provider: authorization.dispatch.configuration.provider, model: authorization.dispatch.preset.model, inputTokens: nil, outputTokens: nil, status: "unknown", at: Date()))
        updateStatus(for: authorization, failure: cloudFailure(error))
    }
    private func persist() {
        providerConfigurations[configuration.provider] = configuration
        let record = Record(configuration: configuration, knownSaved: knownSaved, legacyConfiguration: legacyConfiguration, usesSharedService: usesSharedService, providerConfigurations: providerConfigurations)
        if let data = try? JSONEncoder().encode(record), data != defaults.data(forKey: storageKey) { defaults.set(data, forKey: storageKey) }
    }
}

func cloudFailure(_ error: Error) -> CloudFailure {
    if error is CancellationError || (error as? URLError)?.code == .cancelled { return .cancelled }
    return (error as? CloudRequestError)?.failure ?? (error as? CloudFailure) ?? .network
}
