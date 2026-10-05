import SwiftUI

struct ProviderSettingsView: View {
    @ObservedObject var settings: CloudServiceSettings
    var language: String = "en"
    var allowsSharedService = false
    @State private var key = ""
    @State private var model = ""
    @State private var baseURL = ""
    @State private var error: CloudFailure?
    @State private var testTask: Task<Void, Never>?
    private func t(_ key: String) -> String { CloudViewText.t(key, language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if allowsSharedService {
                Toggle(t("useAIService"), isOn: Binding(get: { settings.usesSharedService }, set: { value in
                    key = ""; error = nil; testTask?.cancel(); testTask = nil
                    settings.setUsesSharedService(value)
                    settings.refreshCredentialStatus()
                    loadOptions()
                })).accessibilityIdentifier("provider.useSharedService")
                Text(t(settings.usesSharedService ? "sharedServiceHelp" : "independentServiceHelp")).font(.caption).foregroundStyle(.secondary)
            }
            if settings.usesSharedService {
                Text(CloudViewText.providerName(settings.effectiveConfiguration.provider, language) + " · " + settings.selectedModel).font(.callout).textSelection(.enabled)
                statusView
            } else {
                independentSettings
            }
        }
        .task { settings.refreshCredentialStatus(); loadOptions() }
        .onDisappear { key = "" }
    }
    private var independentSettings: some View {
        VStack(alignment: .leading, spacing: 16) {
            Picker(t("service"), selection: Binding(get: { settings.configuration.provider }, set: selectProvider)) {
                ForEach(CloudProvider.selectable) { Text(CloudViewText.providerName($0, language)).tag($0) }
            }.accessibilityIdentifier("provider.selection")
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    TextField(t("model"), text: $model).textFieldStyle(.roundedBorder).accessibilityIdentifier("provider.model")
                    Menu(t("modelPresets")) {
                        ForEach(modelPresets, id: \.self) { value in Button(value) { model = value } }
                    }.fixedSize()
                }
                if settings.configuration.provider == .openAICompatible {
                    TextField(t("baseURL"), text: $baseURL).textFieldStyle(.roundedBorder).accessibilityIdentifier("provider.baseURL")
                    Text(t("baseURLHelp")).font(.caption).foregroundStyle(.secondary)
                }
                HStack {
                    Button(t("saveOptions"), action: saveOptions).disabled(!optionsChanged || model.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("provider.saveOptions")
                    Text(t("modelHelp")).font(.caption).foregroundStyle(.secondary)
                }
            }
            SecureField(t("key"), text: $key).textFieldStyle(.roundedBorder).accessibilityIdentifier("provider.key")
            HStack {
                Button(t("saveKey")) { do { try settings.saveCredential(key); key = ""; error = nil } catch { self.error = cloudFailure(error) } }
                    .disabled(optionsChanged || key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty).accessibilityIdentifier("provider.save")
                Button(t("remove")) { do { try settings.removeCredential(); key = ""; error = nil } catch { self.error = cloudFailure(error) } }.disabled(optionsChanged || settings.status == .unconfigured)
                Spacer()
                Button(t("test")) { testTask = Task { await settings.testConnection() } }.disabled(optionsChanged || !key.isEmpty || settings.status == .checking || settings.status == .unconfigured).accessibilityIdentifier("provider.test")
            }
            if optionsChanged { Text(t("saveOptionsFirst")).font(.caption).foregroundStyle(.secondary) }
            else if !key.isEmpty { Text(t("saveKeyFirst")).font(.caption).foregroundStyle(.secondary) }
            statusView
            Text(t("savedHelp")).font(.caption).foregroundStyle(.secondary)
            if settings.legacyConfiguration != nil { Text(t("legacy")).font(.caption).foregroundStyle(.secondary) }
            Divider()
            CloudServiceGuide(provider: settings.configuration.provider, language: language)
        }
    }
    private var statusView: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(t(settings.effectiveStatus.rawValue), systemImage: settings.effectiveStatus == .requestSucceeded ? "checkmark.circle" : "key").font(.callout).accessibilityIdentifier("provider.status")
            if let failure = error ?? settings.effectiveLastError { Text(CloudViewText.failure(failure, language)).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        }
    }
    private var modelPresets: [String] {
        let current = CloudModelPreset.current(for: settings.configuration.provider).model
        return settings.configuration.provider == .deepSeek ? [current, "deepseek-v4-pro"] : [current]
    }
    private var optionsChanged: Bool {
        model.trimmingCharacters(in: .whitespacesAndNewlines) != settings.selectedModel ||
            (settings.configuration.provider == .openAICompatible && baseURL.trimmingCharacters(in: .whitespacesAndNewlines) != settings.configuration.resolvedBaseURL)
    }
    private func loadOptions() {
        model = settings.selectedModel
        baseURL = settings.configuration.resolvedBaseURL
    }
    private func selectProvider(_ selection: CloudProvider) {
        key = ""; error = nil; testTask?.cancel(); testTask = nil
        do { try settings.selectProvider(selection); settings.refreshCredentialStatus(); loadOptions() }
        catch { self.error = cloudFailure(error) }
    }
    private func saveOptions() {
        testTask?.cancel(); testTask = nil
        do {
            try settings.updateOptions(model: model, baseURL: settings.configuration.provider == .openAICompatible ? baseURL : nil)
            error = nil; loadOptions()
        } catch { self.error = cloudFailure(error) }
    }
}
