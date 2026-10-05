import SwiftUI
import AppKit

struct InterpretationView: View {
    @ObservedObject var controller: InterpretationController
    let language: String
    @Environment(\.colorScheme) private var scheme
    @State private var showsCaptionSettings = false
    @State private var historyVisibleCount = 200
    private var palette: AppPalette { AppPalette(dark: scheme == .dark) }
    private var audio: AudioCaptureSession { controller.capture }
    private var ended: Bool { controller.record?.state == "ended" }
    private func t(_ key: String) -> String { InterpretationOnlineText.text(key, language: language) }
    private func config<T>(_ key: WritableKeyPath<AudioConfiguration, T>) -> Binding<T> {
        Binding(get: { audio.configuration[keyPath: key] }, set: { value in
            var next = audio.configuration; next[keyPath: key] = value
            Task { await controller.configure(next) }
        })
    }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                header
                if let error = controller.displayError {
                    HStack(alignment: .top) {
                        Image(systemName: "exclamationmark.circle").foregroundStyle(.orange)
                        Text(t(error)).textSelection(.enabled)
                        Spacer()
                        if controller.hasUnsavedContent { Button(t("retrySave")) { Task { await controller.retryUnsaved() } } }
                    }.font(.callout).padding(14).background(palette.subtle, in: RoundedRectangle(cornerRadius: 10))
                }
                modeControls
                GroupBox { inputControls } label: { Label(t("source"), systemImage: "waveform") }
                GroupBox { sessionControls } label: { Label(t("standalone"), systemImage: "captions.bubble") }
                if controller.mode.provider != nil { onlineControls }
                else if let cloud = controller.cloud { cloudControls(cloud) }
                if controller.selected != nil {
                    if controller.mode.provider != nil { onlineTranscripts } else { transcriptContent }
                }
            }.padding(24).frame(maxWidth: 1050).frame(maxWidth: .infinity)
        }
        .background(palette.subtle).groupBoxStyle(QuietGroupBoxStyle()).buttonStyle(QuietButtonStyle())
        .onAppear { controller.subtitles.language = language; Task { await controller.reloadSessions() } }
        .onChange(of: language) { _, value in controller.subtitles.language = value }
        .onChange(of: controller.selected?.id) { _, _ in historyVisibleCount = 200 }
    }
    private var modeControls: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker(t("interpretationMode"), selection: Binding(get: { controller.mode }, set: { value in Task { await controller.setMode(value) } })) {
                ForEach(InterpretationMode.allCases, id: \.self) { Text(t($0.rawValue)).tag($0) }
            }.disabled(controller.modeLocked || controller.hasActiveCapture || controller.busy || controller.readOnly)
            Text(t(controller.mode.provider == nil ? "legacyAIService" : "onlineNoModel")).font(.caption).foregroundStyle(.secondary)
        }
    }
    private var onlineControls: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                if let provider = controller.mode.provider {
                    Text((provider == .google ? "Google · " : "OpenAI · ") + (controller.online.runtime?.modelID ?? controller.interpretationSettings.profile(for: provider).modelID))
                        .font(.callout).textSelection(.enabled)
                    Text(t(provider == .google ? "onlineGoogleCaveat" : "onlineOpenAICaveat")).font(.caption).foregroundStyle(.secondary)
                }
                Toggle(t("onlineVoice"), isOn: Binding(get: { controller.online.speechEnabled }, set: { controller.online.speechEnabled = $0 }))
                HStack {
                    Text(t("onlineVolume"))
                    Slider(value: Binding(get: { controller.online.volume }, set: { controller.online.volume = $0 }), in: 0...1)
                    Text("\(Int(controller.online.volume * 100))%").monospacedDigit()
                }
                Text(t("onlineMuteHelp")).font(.caption).foregroundStyle(.secondary)
                Text(t("onlineScriptHelp")).font(.caption).foregroundStyle(.secondary)
                if controller.online.playbackSkipped { Text(t("onlinePlaybackSkipped")).font(.caption).foregroundStyle(.orange) }
                if controller.online.tailMayBeIncomplete { Text(t("onlineIncompleteClose")).font(.caption).foregroundStyle(.orange) }
                InterpretationUsageView(records: controller.online.usage, language: language)
            }.frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label(t("interpretationService"), systemImage: "network") }
    }
    private var onlineTranscripts: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("onlineIndependentTracks")).font(.caption).foregroundStyle(.secondary)
            if controller.online.captions.count > historyVisibleCount { Button(t("showOlderTranscript")) { historyVisibleCount += 200 } }
            ForEach(["source", "translation"], id: \.self) { track in
                GroupBox(t(track == "source" ? "onlineSource" : "onlineTarget")) {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        let rows = Array(controller.online.captions.reversed().lazy.filter { $0.track == track }.prefix(historyVisibleCount)).reversed()
                        if rows.isEmpty { Text(t("captionWaiting")).foregroundStyle(.secondary) }
                        ForEach(rows) { row in
                            VStack(alignment: .leading, spacing: 4) {
                                Text("≈ " + time(row.receivedAtMS)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                                Text(row.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            if !controller.gaps.isEmpty {
                DisclosureGroup(t("gap") + " (\(controller.gaps.count))") {
                    ForEach(controller.gaps) { gap in Text(time(gap.startMS) + " · " + t(gap.reason)).font(.caption).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }
        }
    }
    private var header: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                VStack(alignment: .leading, spacing: 6) {
                    Text(t("standalone")).font(.system(size: 27, weight: .semibold))
                    Text(controller.selected?.title ?? t("noSession")).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                }
                Spacer()
                Button { Task { await controller.newSession() } } label: { Label(t("newInterpretation"), systemImage: "plus") }
                    .disabled(controller.hasActiveCapture || controller.busy || controller.hasUnsavedContent || controller.readOnly)
            }
            if !controller.sessions.isEmpty {
                Picker(t("sessions"), selection: Binding(get: { controller.selected?.id ?? "" }, set: { id in Task { await controller.selectSession(id) } })) {
                    Text("—").tag("")
                    ForEach(controller.sessions) { Text($0.title).tag($0.id) }
                }.disabled(controller.hasActiveCapture || controller.busy || controller.hasUnsavedContent)
            }
            if let item = controller.selected {
                ViewThatFits(in: .horizontal) {
                    HStack { location; Spacer(); association(item) }
                    VStack(alignment: .leading, spacing: 8) { location; association(item) }
                }
            }
        }
    }
    private var location: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                Label(t("transcriptAutoSaveTXT"), systemImage: "doc.text").font(.caption).foregroundStyle(.secondary)
                Button { Task { await controller.revealTranscriptInFinder(kind: .source) } } label: { Label(t("sourceTXT"), systemImage: "doc.text") }
                    .disabled(controller.transcriptFileURL == nil)
                    .accessibilityIdentifier("interpretation.showTranscriptInFinder")
                Button { Task { await controller.revealTranscriptInFinder(kind: .bilingual) } } label: { Label(t("bilingualTXT"), systemImage: "doc.on.doc") }
                    .disabled(controller.transcriptFileURL == nil)
                    .accessibilityIdentifier("interpretation.showBilingualTranscriptInFinder")
            }
            Text(controller.saveLocation?.path ?? t("transcriptLocationMissing"))
                .font(.caption).foregroundStyle(.secondary).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
    }
    private func association(_ item: WorkspaceItem) -> some View {
        Menu {
            ForEach(controller.courses) { course in Button(course.title) { Task { await controller.associateCourse(course.id) } } }
        } label: {
            Label(item.courseID.flatMap { id in controller.courses.first { $0.id == id }?.title } ?? t("associateCourse"), systemImage: "link")
        }.disabled(controller.hasActiveCapture || controller.busy || controller.hasUnsavedContent || controller.readOnly || controller.courses.isEmpty || item.courseID != nil)
    }
    private var inputControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(t("source"), selection: config(\.source)) {
                Text(t("microphone")).tag(AudioSource.microphone)
                Text(t("systemAudio")).tag(AudioSource.system)
            }
            if audio.configuration.source == .microphone {
                HStack {
                    Picker(t("device"), selection: Binding(get: { audio.configuration.deviceID.map(String.init) ?? "" }, set: { value in
                        var next = audio.configuration; next.deviceID = UInt32(value); Task { await controller.configure(next) }
                    })) {
                        Text("—").tag("")
                        ForEach(audio.devices) { Text($0.name).tag(String($0.id)) }
                        if let id = audio.configuration.deviceID, !audio.devices.contains(where: { $0.id == id }) { Text(t("deviceUnavailable")).tag(String(id)) }
                    }
                    Button { audio.refreshDevices() } label: { Image(systemName: "arrow.clockwise") }.help(t("refresh"))
                }
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 24) { languages.fixedSize(horizontal: true, vertical: false); Toggle(t("saveRecording"), isOn: config(\.saveRecording)).toggleStyle(.switch).fixedSize() }
                VStack(alignment: .leading, spacing: 12) { languages; Toggle(t("saveRecording"), isOn: config(\.saveRecording)).toggleStyle(.switch) }
            }
            Text(t(controller.mode.provider != nil ? "onlineAutoLanguage" : "configurationPauses")).font(.caption).foregroundStyle(.secondary)
        }.disabled(controller.busy || ended || controller.readOnly || audio.draining)
    }
    private var languages: some View {
        ViewThatFits(in: .horizontal) {
            HStack { sourceLanguagePicker.fixedSize(); targetLanguagePicker.fixedSize() }
            VStack(alignment: .leading, spacing: 12) { sourceLanguagePicker; targetLanguagePicker }
        }
    }
    private var sourceLanguagePicker: some View {
        Picker(t(controller.mode.provider == nil ? "mainLanguage" : "onlineSourceHint"), selection: config(\.language)) { Text("English").tag("en"); Text("日本語").tag("ja") }
    }
    private var targetLanguagePicker: some View {
        Picker(t("targetChinese"), selection: Binding(get: { controller.targetLanguage }, set: { value in Task { await controller.configure(audio.configuration, targetLanguage: value) } })) {
            Text("简体中文").tag("zh-Hans"); Text("繁體中文").tag("zh-Hant")
        }.disabled(controller.mode.provider != nil && controller.modeLocked)
    }
    private var sessionControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            ViewThatFits(in: .horizontal) { HStack { captureButtons; Spacer(); captionButtons }; VStack(alignment: .leading, spacing: 10) { captureButtons; captionButtons } }
            HStack {
                Circle().fill(audio.phase == .capturing ? Color.green : Color.secondary.opacity(0.4)).frame(width: 7, height: 7)
                Text(t(controller.mode.provider != nil ? "online." + controller.online.state.rawValue : audio.status)).font(.callout).textSelection(.enabled)
                if audio.draining || controller.busy { ProgressView().controlSize(.small) }
            }
            if controller.mode.provider != nil,
               audio.requiresRestartAfterStopFailure || ["online.captureFailed", "online.captureInterrupted"].contains(controller.online.errorCode ?? "") {
                Text(t(audio.status)).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
            }
            ProgressView(value: max(0, min(1, (audio.level + 80) / 80))).accessibilityLabel(t("source"))
            if let position = audio.playbackPosition {
                HStack {
                    Text(time(Int64(position * 1000))).monospacedDigit()
                    Button(t(audio.playbackPaused ? "resumePlayback" : "pausePlayback")) {
                        if audio.playbackPaused { do { try audio.resumePlayback() } catch { controller.error = error.localizedDescription } }
                        else { audio.pausePlayback() }
                    }
                    Button(t("stopPlayback")) { audio.stopPlayback() }
                }
            }
        }
    }
    private var captureButtons: some View {
        HStack {
            Button { Task { await controller.start() } } label: { Label(t((audio.phase == .paused || (controller.mode.provider != nil && controller.online.state == .paused)) ? "resume" : "startInterpretation"), systemImage: "play.fill") }
                .disabled(controller.hasActiveCapture || controller.busy || ended || controller.readOnly || controller.hasUnsavedContent || audio.requiresRestartAfterStopFailure)
            Button { Task { await controller.pause() } } label: { Label(t("pause"), systemImage: "pause.fill") }
                .disabled(!controller.hasActiveCapture)
            Button(t("endInterpretation")) { Task { await controller.end() } }
                .disabled(controller.selected == nil || controller.busy || ended || controller.readOnly || audio.draining)
        }
    }
    private var captionButtons: some View {
        HStack {
            Button(t(controller.subtitles.isVisible ? "hideCaptions" : "showCaptions")) { controller.subtitles.toggle() }
            Button { showsCaptionSettings = true } label: { Image(systemName: "slider.horizontal.3") }.help(t("captionSettings"))
                .popover(isPresented: $showsCaptionSettings) { SubtitlePreferencesView(controller: controller.subtitles, language: language) }
        }
    }
    private func cloudControls(_ cloud: CloudController) -> some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack { translationButtons(cloud); Spacer(); speechButtons(cloud) }
                    VStack(alignment: .leading, spacing: 10) { translationButtons(cloud); speechButtons(cloud) }
                }
                HStack {
                    Text(t(cloud.queueStatus))
                    Text("\(cloud.completedCount) " + t("saved") + " · \(cloud.pendingCount) " + t("translationWaiting"))
                }.font(.caption).foregroundStyle(.secondary)
                if let errorCode = cloud.queueErrorCode { Text(StatusLocalizer.cloudStatus(errorCode, language: language)).font(.caption).foregroundStyle(.orange) }
                Text(t(cloud.speech.status)).font(.caption).foregroundStyle(.secondary)
                if cloud.speech.skippedCount > 0 { Text(t("speechSkipped") + " (\(cloud.speech.skippedCount))").font(.caption).foregroundStyle(.secondary) }
                HStack {
                    if !cloud.speech.voices.isEmpty {
                        Picker(t("speech"), selection: Binding(get: { cloud.speech.selectedVoiceID ?? "" }, set: { cloud.speech.selectedVoiceID = $0 })) {
                            ForEach(cloud.speech.voices) { Text($0.name + " · " + $0.language).tag($0.id) }
                        }
                    }
                    Button(t("refreshVoices")) { cloud.speech.refreshVoices() }
                }
                Text(t("speechHelp")).font(.caption).foregroundStyle(.secondary)
            }
        } label: { Label(t("translationControls"), systemImage: "character.bubble") }
    }
    private func translationButtons(_ cloud: CloudController) -> some View {
        Button(t(cloud.state.translationUserPaused ? "translationResume" : "translationPaused")) { Task { await controller.setTranslationPaused(!cloud.state.translationUserPaused) } }.disabled(controller.readOnly)
    }
    private func speechButtons(_ cloud: CloudController) -> some View {
        HStack {
            Toggle(t("enableVoice"), isOn: Binding(get: { cloud.speech.enabled }, set: controller.setSpeechEnabled)).toggleStyle(.switch).disabled(audio.phase != .capturing)
            Button(t("stopVoice")) { controller.stopSpeech() }.disabled(!cloud.speech.enabled)
        }
    }
    private var transcriptContent: some View {
        GroupBox {
            LazyVStack(alignment: .leading, spacing: 18) {
                if controller.transcripts.isEmpty && controller.audio.provisional.isEmpty { Text(t("captionWaiting")).foregroundStyle(.secondary).padding(.vertical, 16) }
                if controller.transcripts.count > historyVisibleCount { Button(t("showOlderTranscript")) { historyVisibleCount += 200 } }
                ForEach(controller.transcripts.suffix(historyVisibleCount)) { row in transcriptRow(row) }
                if !controller.audio.provisional.isEmpty {
                    Text(t("provisional") + " · " + controller.audio.provisional).italic().foregroundStyle(.secondary).textSelection(.enabled)
                }
                if !controller.gaps.isEmpty {
                    DisclosureGroup(t("gap") + " (\(controller.gaps.count))") {
                        ForEach(controller.gaps) { gap in
                            Text(time(gap.startMS) + " – " + (gap.endMS.map(time) ?? "…") + " · " + t(gap.reason)).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        } label: { Label(t("transcript"), systemImage: "text.bubble") }
    }
    private func transcriptRow(_ row: TranscriptRecord) -> some View {
        let job = controller.translation(for: row)
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(time(row.startMS) + " – " + time(row.endMS)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString([row.text, job?.translation?.text].compactMap { $0 }.joined(separator: "\n"), forType: .string) } label: { Image(systemName: "doc.on.doc") }.help(t("copy"))
                Button { controller.play(from: row.startMS) } label: { Image(systemName: "play.circle") }.help(t("playFromHere"))
                    .disabled(controller.hasActiveCapture || !controller.recordings.contains { $0.startMS <= row.startMS && row.startMS < $0.endMS })
            }
            Text(row.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let translated = job?.translation?.text { Text(translated).textSelection(.enabled).foregroundStyle(.secondary) }
            else {
                HStack {
                    Text(job.map { t($0.errorCode ?? $0.status.rawValue) } ?? t("translationWaiting")).font(.caption).foregroundStyle(.secondary)
                    if let job, job.status == .needsAttention || job.status == .retryWaiting { Button(t("retryTranslation")) { Task { await controller.retryTranslation(job.id) } }.disabled(controller.readOnly) }
                }
            }
            Divider()
        }
    }
    private func time(_ value: Int64) -> String { let s = max(0, value) / 1000; return String(format: "%02lld:%02lld:%02lld", s / 3600, (s % 3600) / 60, s % 60) }
}
