import Foundation
import Combine

enum InterpretationCredentialSource: String, Codable, CaseIterable { case independent, mainAI }

struct InterpretationServiceProfile: Codable, Equatable {
    var provider: InterpretationProvider
    var modelID: String
    var credentialSource: InterpretationCredentialSource = .independent
    var version = 1
    var credentialReference: String { "classroom.interpretation." + (provider == .google ? "geminiDeveloper" : "openAI") }
}

/// Secrets are transient and cannot be encoded, logged or put into session facts.
struct InterpretationAuthorization: CustomDebugStringConvertible {
    let configuration: InterpretationSessionConfiguration
    let profileVersion: Int
    fileprivate let secret: String
    var debugDescription: String { "InterpretationAuthorization(\(configuration.provider.rawValue), redacted)" }
    @MainActor func start(_ session: InterpretationSession) async throws {
        try await session.start(configuration: configuration, apiKey: secret)
    }
}

typealias InterpretationConnectionTester = @MainActor (InterpretationSessionConfiguration, String) async throws -> Void

@MainActor final class InterpretationServiceSettings: ObservableObject {
    @Published private(set) var selectedProvider: InterpretationProvider
    @Published private(set) var profiles: [InterpretationProvider: InterpretationServiceProfile]
    @Published private(set) var statuses: [InterpretationProvider: CloudCredentialStatus] = [:]
    @Published private(set) var errors: [InterpretationProvider: InterpretationFailure] = [:]
    @Published private(set) var mainAIProvider: CloudProvider
    private let credentials: CloudCredentialStore
    private let mainAI: CloudServiceSettings
    private let defaults: UserDefaults
    private let tester: InterpretationConnectionTester
    private let storageKey = "ulecture.interpretation-settings.v1"
    private var knownSaved: Set<InterpretationProvider>
    private var mainSubscription: AnyCancellable?
    private var testVersions: [InterpretationProvider: Int] = [:]
    private struct Record: Codable {
        var selectedProvider: InterpretationProvider
        var profiles: [InterpretationProvider: InterpretationServiceProfile]
        var knownSaved: Set<InterpretationProvider>
    }

    init(mainAI: CloudServiceSettings, credentials: CloudCredentialStore = KeychainCredentialStore(), defaults: UserDefaults = .standard, tester: @escaping InterpretationConnectionTester = { configuration, key in
        try await InterpretationSessionFactory.testConnection(configuration: configuration, apiKey: key)
    }) {
        self.mainAI = mainAI; self.credentials = credentials; self.defaults = defaults; self.tester = tester
        mainAIProvider = mainAI.effectiveConfiguration.provider
        let saved = defaults.data(forKey: storageKey).flatMap { try? JSONDecoder().decode(Record.self, from: $0) }
        selectedProvider = saved?.selectedProvider ?? .google
        profiles = Dictionary(uniqueKeysWithValues: InterpretationProvider.allCases.map { provider in
            let profile = saved?.profiles[provider]
            return (provider, profile?.provider == provider ? profile! : InterpretationServiceProfile(provider: provider, modelID: provider.defaultModelID))
        })
        knownSaved = saved?.knownSaved ?? []
        for provider in InterpretationProvider.allCases { statuses[provider] = knownSaved.contains(provider) ? .savedUnverified : .unconfigured }
        // Opening settings neither reads secret values nor sends requests.
        mainSubscription = mainAI.$configuration.dropFirst().sink { [weak self] configuration in
            guard let self else { return }
            if self.mainAIProvider != configuration.provider { self.mainAIProvider = configuration.provider }
            for provider in InterpretationProvider.allCases where self.profile(for: provider).credentialSource == .mainAI {
                self.testVersions[provider, default: 0] += 1
                self.setStatus(.savedUnverified, for: provider)
                self.setError(nil, for: provider)
            }
        }
    }

    var status: CloudCredentialStatus { status(for: selectedProvider) }
    var lastError: InterpretationFailure? { errors[selectedProvider] }
    var selectedModel: String { profile(for: selectedProvider).modelID }
    func profile(for provider: InterpretationProvider) -> InterpretationServiceProfile { profiles[provider]! }
    func status(for provider: InterpretationProvider) -> CloudCredentialStatus { statuses[provider] ?? .unconfigured }
    func lastError(for provider: InterpretationProvider) -> InterpretationFailure? { errors[provider] }

    /// Stable UI reason codes; provider branding alone never establishes compatibility.
    func mainAIReuseReason(for provider: InterpretationProvider) -> String? {
        let current = mainAIProvider
        guard current == .geminiDeveloper || current == .openAI else { return "mainAIUnsupportedProvider" }
        guard current == cloudProvider(provider) else { return "mainAIProviderMismatch" }
        return nil
    }
    func selectProvider(_ provider: InterpretationProvider) {
        guard selectedProvider != provider else { return }
        selectedProvider = provider; persist()
    }
    func updateModel(_ modelID: String, for provider: InterpretationProvider? = nil) throws {
        let provider = provider ?? selectedProvider
        let model = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        _ = try InterpretationSessionConfiguration(provider: provider, modelID: model, targetLanguageCode: provider == .google ? "zh-Hans" : "zh").validated()
        var profile = profile(for: provider)
        guard profile.modelID != model else { return }
        profile.modelID = model; profile.version += 1; profiles[provider] = profile
        invalidate(provider); persist()
    }
    func setCredentialSource(_ source: InterpretationCredentialSource, for provider: InterpretationProvider? = nil) throws {
        let provider = provider ?? selectedProvider
        guard source != .mainAI || mainAIReuseReason(for: provider) == nil else { throw InterpretationFailure.invalidConfiguration }
        var profile = profile(for: provider)
        guard source != profile.credentialSource else { return }
        profile.credentialSource = source; profile.version += 1; profiles[provider] = profile
        invalidate(provider); persist(); refreshCredentialStatus(for: provider)
    }
    func saveCredential(_ input: String, for provider: InterpretationProvider? = nil) throws {
        let provider = provider ?? selectedProvider, profile = profile(for: provider)
        guard profile.credentialSource == .independent else { throw InterpretationFailure.invalidConfiguration }
        let secret = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !secret.isEmpty else { throw InterpretationFailure.missingCredential }
        guard secret.utf8.count <= 16_384, !secret.contains("\n"), !secret.contains("\r") else { throw InterpretationFailure.invalidConfiguration }
        do { try credentials.save(secret, reference: profile.credentialReference) }
        catch { throw InterpretationFailure.authentication }
        knownSaved.insert(provider); changedCredential(provider); setStatus(.savedUnverified, for: provider)
    }
    func removeCredential(for provider: InterpretationProvider? = nil) throws {
        let provider = provider ?? selectedProvider, profile = profile(for: provider)
        guard profile.credentialSource == .independent else { throw InterpretationFailure.invalidConfiguration }
        do { try credentials.remove(reference: profile.credentialReference) }
        catch { throw InterpretationFailure.authentication }
        knownSaved.remove(provider); changedCredential(provider); setStatus(.unconfigured, for: provider)
    }
    func refreshCredentialStatus(for provider: InterpretationProvider? = nil) {
        let provider = provider ?? selectedProvider, profile = profile(for: provider)
        do {
            let present: Bool
            if profile.credentialSource == .mainAI {
                guard mainAIReuseReason(for: provider) == nil else { setStatus(.unconfigured, for: provider); return }
                present = try mainAI.hasInterpretationCredential(for: cloudProvider(provider))
            } else {
                present = try credentials.contains(reference: profile.credentialReference)
                if present { knownSaved.insert(provider) } else { knownSaved.remove(provider) }
                persist()
            }
            if !present { setStatus(.unconfigured, for: provider) }
            else if ![.checking, .requestSucceeded, .failed].contains(status(for: provider)) { setStatus(.savedUnverified, for: provider) }
        } catch { setError(.authentication, for: provider); setStatus(.failed, for: provider) }
    }
    func authorize(provider: InterpretationProvider? = nil, targetLanguageCode: String? = nil, inputTranscription: Bool = true) throws -> InterpretationAuthorization {
        let provider = provider ?? selectedProvider, profile = profile(for: provider)
        let config = try InterpretationSessionConfiguration(provider: provider, modelID: profile.modelID, targetLanguageCode: targetLanguageCode ?? (provider == .google ? "zh-Hans" : "zh"), inputTranscription: inputTranscription).validated()
        let secret: String
        do {
            if profile.credentialSource == .mainAI {
                guard mainAIReuseReason(for: provider) == nil else { throw InterpretationFailure.invalidConfiguration }
                secret = try mainAI.interpretationCredential(for: cloudProvider(provider))
            } else {
                guard let value = try credentials.read(reference: profile.credentialReference), !value.isEmpty else { throw InterpretationFailure.missingCredential }
                secret = value
            }
        } catch { throw Self.safeFailure(error) }
        return InterpretationAuthorization(configuration: config, profileVersion: profile.version, secret: secret)
    }
    func testConnection(provider: InterpretationProvider? = nil) async {
        let provider = provider ?? selectedProvider
        guard status(for: provider) != .checking else { return }
        testVersions[provider, default: 0] += 1
        let attempt = testVersions[provider]!, profile = profile(for: provider)
        let mainVersion = mainAI.effectiveConfiguration.version
        let authorization: InterpretationAuthorization
        do { authorization = try authorize(provider: provider) }
        catch { setError(Self.safeFailure(error), for: provider); setStatus(.failed, for: provider); return }
        setError(nil, for: provider); setStatus(.checking, for: provider)
        var failure: InterpretationFailure?
        do { try await tester(authorization.configuration, authorization.secret) }
        catch { failure = Self.safeFailure(error) }
        guard testVersions[provider] == attempt, self.profile(for: provider) == profile,
              profile.credentialSource != .mainAI || mainAI.effectiveConfiguration.version == mainVersion else { return }
        setError(failure, for: provider); setStatus(failure == nil ? .requestSucceeded : .failed, for: provider)
    }
    private func changedCredential(_ provider: InterpretationProvider) {
        var profile = profile(for: provider); profile.version += 1; profiles[provider] = profile
        invalidate(provider); persist()
    }
    private func invalidate(_ provider: InterpretationProvider) {
        testVersions[provider, default: 0] += 1; setError(nil, for: provider)
        setStatus(knownSaved.contains(provider) || profile(for: provider).credentialSource == .mainAI ? .savedUnverified : .unconfigured, for: provider)
    }
    private func setStatus(_ value: CloudCredentialStatus, for provider: InterpretationProvider) { if statuses[provider] != value { statuses[provider] = value } }
    private func setError(_ value: InterpretationFailure?, for provider: InterpretationProvider) { if errors[provider] != value { errors[provider] = value } }
    private func cloudProvider(_ provider: InterpretationProvider) -> CloudProvider { provider == .google ? .geminiDeveloper : .openAI }
    private func persist() {
        let record = Record(selectedProvider: selectedProvider, profiles: profiles, knownSaved: knownSaved)
        if let data = try? JSONEncoder().encode(record), data != defaults.data(forKey: storageKey) { defaults.set(data, forKey: storageKey) }
    }
    private static func safeFailure(_ error: Error) -> InterpretationFailure {
        if let error = error as? InterpretationFailure { return error }
        if let failure = error as? CloudFailure {
            switch failure { case .missingCredential: return .missingCredential; case .invalidConfiguration: return .invalidConfiguration; case .authentication, .permission: return .authentication; default: break }
        }
        return InterpretationFailure.fromTransport(error)
    }
}
