import SwiftUI
import AVFoundation

struct SetupView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: AppPreferences
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(alignment: .firstTextBaseline) {
                    Text(model.t("setup")).font(.system(size: 26, weight: .semibold)); Spacer()
                    Button(model.t("hideSetup")) { prefs.hideSetup = true; model.route = "workspace" }.buttonStyle(.link)
                }
                setupCard("workspace", icon: "folder") {
                    Text(model.t("projectFoldersHelp")).foregroundStyle(.secondary)
                }
                setupCard("offline", icon: "waveform") {
                    Text(model.t("modelHelp")).foregroundStyle(.secondary)
                    Text(model.detail(model.models.status)).font(.callout).textSelection(.enabled)
                    if model.models.busy { ProgressView(value: model.models.progress); Button(model.t("cancel")) { model.models.cancel() } }
                    else {
                        ViewThatFits(in: .horizontal) {
                            HStack { modelActions }
                            VStack(alignment: .leading, spacing: 8) { modelActions }
                        }
                    }

                }
                setupCard("permission", icon: "mic") {
                    Text(model.t("permissionHelp")).foregroundStyle(.secondary)
                    Text("\(model.t("microphone")): \(microphonePermission)").font(.callout)
                    Text("\(model.t("systemAudio")): \(model.t(model.audio.systemAudioAuthorized ? "ready" : "pendingValidation"))").font(.callout)
                    SoundCheckView(probe: model.probe)
                }
                setupCard("optionalCloud", icon: "network") {
                    Text(model.t("cloudHelp")).foregroundStyle(.secondary)
                    Text(CloudViewText.providerName(model.cloudConfiguration.provider, prefs.resolvedLanguage)).font(.callout)
                    Text(CloudViewText.t(model.cloudService.status.rawValue, prefs.resolvedLanguage)).font(.caption).foregroundStyle(.secondary)
                    Button(model.t("settings")) { model.route = "settings" }
                }
                ConversionResourceView(language: prefs.resolvedLanguage)
                    .padding(20).frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppPalette(dark: prefs.dark).canvas, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppPalette(dark: prefs.dark).border))

            }.padding(32).frame(maxWidth: 880, alignment: .leading).frame(maxWidth: .infinity)
        }
    }
    @ViewBuilder var modelActions: some View {
        if model.models.resourceState == .ready {
            Label(model.t("offlineModelReady"), systemImage: "checkmark.circle.fill")
        } else {
            Button(model.t("downloadOfflineModel")) { Task { await model.models.download() } }
        }
    }
    var microphonePermission: String {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return model.t("ready")
        case .notDetermined: return model.t("pendingValidation")
        default: return model.t("error")
        }
    }
    func setupCard<Content: View>(_ key: String, icon: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) { Label(model.t(key), systemImage: icon).font(.headline); content() }
            .padding(20).frame(maxWidth: .infinity, alignment: .leading).background(AppPalette(dark: prefs.dark).canvas, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(AppPalette(dark: prefs.dark).border))
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: AppPreferences
    @State private var usage: [CloudUsage] = []
    @State private var interpretationUsage: [InterpretationUsageRecord] = []
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                Text(model.t("settings")).font(.system(size: 26, weight: .semibold))
                GroupBox(model.t("general")) {
                    VStack(alignment: .leading, spacing: 14) {
                        Picker(model.t("language"), selection: $prefs.language) {
                            Text(model.t("followSystem")).tag("system"); Text("简体中文").tag("zh-Hans"); Text("繁體中文").tag("zh-Hant"); Text("English").tag("en"); Text("日本語").tag("ja")
                        }.frame(maxWidth: 420)
                        Button(model.t("restoreSetup")) { prefs.hideSetup = false; model.route = "setup" }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox(model.t("workspace")) { ProjectSettingsView() }
                GroupBox(model.t("backup")) { BackupSettingsView() }
                GroupBox(CloudViewText.t("aiService", prefs.resolvedLanguage)) {
                    ProviderSettingsView(settings: model.cloudService, language: prefs.resolvedLanguage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("settings.aiService")
                }
                GroupBox(CloudViewText.t("textTranslationService", prefs.resolvedLanguage)) {
                    ProviderSettingsView(settings: model.textTranslationService, language: prefs.resolvedLanguage, allowsSharedService: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("settings.textTranslationService")
                }
                GroupBox(CloudViewText.t("documentTranslationService", prefs.resolvedLanguage)) {
                    ProviderSettingsView(settings: model.documentTranslationService, language: prefs.resolvedLanguage, allowsSharedService: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .accessibilityIdentifier("settings.documentTranslationService")
                }
                GroupBox(InterpretationOnlineText.text("interpretationService", language: prefs.resolvedLanguage)) {
                    InterpretationServiceSettingsView(settings: model.interpretationService, language: prefs.resolvedLanguage)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox(CloudViewText.t("allServiceUsage", prefs.resolvedLanguage)) {
                    VStack(alignment: .leading, spacing: 12) {
                        CloudUsageView(usage: usage)
                        InterpretationUsageView(records: interpretationUsage, language: prefs.resolvedLanguage)
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
                GroupBox(model.t("help")) {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("ULecture \(Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.1.0") · macOS 14+ · Apple Silicon")
                        Text(model.t("productSummary"))
                        Text(model.t("modelHelp")).font(.callout).foregroundStyle(.secondary)
                        Text(model.t("licensePending")).font(.caption)
                        HStack {
                            Link(model.t("userGuide"), destination: URL(string: "https://github.com/yqia03/ulecture/blob/main/docs/ulecture/user-guide.md")!)
                            Link(model.t("privacy"), destination: URL(string: "https://github.com/yqia03/ulecture/blob/main/PRIVACY.md")!)
                            Link("GitHub", destination: URL(string: "https://github.com/yqia03/ulecture")!)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }.padding(32).frame(maxWidth: 880, alignment: .leading).frame(maxWidth: .infinity)
        }
        .onAppear { refreshUsage() }
        .onChange(of: model.usageRevision) { _, _ in refreshUsage() }
    }
    private func refreshUsage() {
        var all = model.serviceSettings.state.usage + model.cloudService.usage + model.textTranslationService.usage + model.documentTranslationService.usage
        do {
            let states = try model.library?.records(collection: "cloud-state", as: CloudState.self) ?? []
            all += states.flatMap(\.usage)
            usage = all
            interpretationUsage = try model.library?.interpretationUsage() ?? []
        } catch { model.report(error) }
    }

}
