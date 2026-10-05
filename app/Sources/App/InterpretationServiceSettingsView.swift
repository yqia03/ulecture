import SwiftUI

struct InterpretationServiceSettingsView: View {
    @ObservedObject var settings: InterpretationServiceSettings
    var language: String
    @State private var key = ""
    @State private var modelID = ""
    @State private var error: String?
    @State private var testTask: Task<Void, Never>?
    private var provider: InterpretationProvider { settings.selectedProvider }
    private var profile: InterpretationServiceProfile { settings.profile(for: provider) }
    private var changed: Bool { modelID.trimmingCharacters(in: .whitespacesAndNewlines) != profile.modelID }
    private func t(_ key: String) -> String { InterpretationOnlineText.text(key, language: language) }
    private func c(_ key: String) -> String { CloudViewText.t(key, language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(c("service"), selection: Binding(get: { provider }, set: { value in
                testTask?.cancel(); key = ""; error = nil; settings.selectProvider(value); load()
            })) { Text("Google AI Studio").tag(InterpretationProvider.google); Text("OpenAI").tag(InterpretationProvider.openAI) }
            Toggle(t("onlineUseMainKey"), isOn: Binding(get: { profile.credentialSource == .mainAI }, set: { useMain in
                testTask?.cancel()
                do { try settings.setCredentialSource(useMain ? .mainAI : .independent); error = nil; key = "" }
                catch { self.error = error.localizedDescription }
            })).disabled(profile.credentialSource != .mainAI && settings.mainAIReuseReason(for: provider) != nil)
            Text(t("onlineKeyOnly")).font(.caption).foregroundStyle(.secondary)
            if let reason = settings.mainAIReuseReason(for: provider) { Text(t(reason)).font(.caption).foregroundStyle(.secondary) }
            HStack {
                TextField(t("onlineModel"), text: $modelID).textFieldStyle(.roundedBorder).accessibilityIdentifier("interpretation.model")
                Menu(c("modelPresets")) { Button(provider.defaultModelID) { modelID = provider.defaultModelID } }
            }
            Button(t("onlineSaveModel")) {
                do { testTask?.cancel(); try settings.updateModel(modelID); error = nil; load() }
                catch { self.error = error.localizedDescription }
            }.disabled(!changed)
            Text(t("onlineModelHelp")).font(.caption).foregroundStyle(.secondary)
            if profile.credentialSource == .independent {
                SecureField(c("key"), text: $key).textFieldStyle(.roundedBorder).accessibilityIdentifier("interpretation.key")
                HStack {
                    Button(c("saveKey")) {
                        testTask?.cancel()
                        do { try settings.saveCredential(key); key = ""; error = nil } catch { self.error = error.localizedDescription }
                    }.disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || changed)
                    Button(c("remove")) {
                        testTask?.cancel()
                        do { try settings.removeCredential(); key = ""; error = nil } catch { self.error = error.localizedDescription }
                    }.disabled(settings.status == .unconfigured)
                }
            }
            HStack {
                Button(t("onlineProtocolTest")) { testTask?.cancel(); testTask = Task { await settings.testConnection() } }
                    .disabled(changed || !key.isEmpty || settings.status == .checking || settings.status == .unconfigured)
                    .accessibilityIdentifier("interpretation.test")
                if settings.status == .checking { ProgressView().controlSize(.small) }
                Text(settings.status == .requestSucceeded ? t("onlineHandshakePassed") : c(settings.status.rawValue)).font(.callout)
            }
            if let code = error ?? settings.lastError?.localizedDescription { Text(t(code)).font(.callout).foregroundStyle(.orange).textSelection(.enabled) }
            Text(t("onlineTestHelp")).font(.caption).foregroundStyle(.secondary)
            Text(t(provider == .google ? "onlineGoogleCaveat" : "onlineOpenAICaveat")).font(.caption).foregroundStyle(.secondary)
            Link(provider == .google ? "Google AI Studio" : "OpenAI API", destination: URL(string: provider == .google ? "https://aistudio.google.com/api-keys" : "https://platform.openai.com/api-keys")!)
        }
        .accessibilityIdentifier("settings.interpretationService")
        .onAppear { load() }
        .onDisappear { key = ""; testTask?.cancel() }
    }
    private func load() { settings.refreshCredentialStatus(); modelID = settings.selectedModel }
}

struct InterpretationUsageView: View {
    let records: [InterpretationUsageRecord]
    let language: String
    private func t(_ key: String) -> String { InterpretationOnlineText.text(key, language: language) }
    var body: some View {
        DisclosureGroup(t("onlineUsage")) {
            VStack(alignment: .leading, spacing: 6) {
                Text(t("onlineUploaded") + ": " + seconds(records.reduce(0) { $0 + $1.uploadedSeconds }))
                Text(t("onlineGenerated") + ": " + seconds(records.reduce(0) { $0 + $1.generatedSeconds }))
                Text(t("onlinePlayed") + ": " + seconds(records.reduce(0) { $0 + $1.playedSeconds }))
                if !records.isEmpty {
                    Text(t("onlineEstimatedCost") + ": " + (records.allSatisfy { $0.estimatedCostUSD != nil }
                        ? String(format: "%.4f", records.reduce(0) { $0 + ($1.estimatedCostUSD ?? 0) }) : t("onlineCostUnknown")))
                }
                Text(t("onlineUsageHelp")).foregroundStyle(.secondary)
            }.font(.caption).padding(.top, 8).frame(maxWidth: .infinity, alignment: .leading)
        }
    }
    private func seconds(_ value: Double) -> String { String(format: "%.1f s", value) }
}
