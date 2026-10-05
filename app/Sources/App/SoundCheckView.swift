import SwiftUI

/// Explicit, short microphone/system-audio check. The host owns this controller
/// and must stop it before starting a classroom, switching libraries or exiting.
/// This view never installs library, translation, recording or speech callbacks.
struct SoundCheckView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: AppPreferences
    @ObservedObject var probe: AudioController
    @State private var source: AudioSource = .microphone
    @State private var deviceID = ""
    @State private var language = "en"
    @State private var confirmed: [String] = []
    @State private var startTask: Task<Void, Never>?
    @State private var transition = false

    private var checking: Bool { [.starting, .capturing].contains(probe.phase) }
    private var classroomActive: Bool { [.starting, .capturing].contains(model.audio.phase) || model.audio.draining }
    private var interpretationActive: Bool { model.interpretation?.hasActiveCapture == true }
    private var anotherCaptureActive: Bool { classroomActive || interpretationActive }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.t("soundCheck")).font(.headline)
            Text(model.t("soundCheckHelp")).font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                Picker(model.t("source"), selection: $source) {
                    Text(model.t("microphone")).tag(AudioSource.microphone)
                    Text(model.t("systemAudio")).tag(AudioSource.system)
                }
                if source == .microphone {
                    Picker(model.t("device"), selection: $deviceID) {
                        Text("— " + model.t("device") + " —").tag("")
                        ForEach(probe.devices) { device in Text(device.name).tag(String(device.id)) }
                    }
                    Button(model.t("refresh")) { probe.refreshDevices() }.controlSize(.small)
                }
                Picker(model.t("mainLanguage"), selection: $language) {
                    Text("English").tag("en")
                    Text("日本語").tag("ja")
                }
            }.frame(maxWidth: 480, alignment: .leading).disabled(checking || probe.draining || transition)
            HStack {
                Button(model.t("soundCheckStart"), action: start)
                    .disabled(checking || probe.draining || transition || model.busy || anotherCaptureActive || !(model.models.ready || model.models.resourcesAvailable) || model.models.busy)
                Button(model.t("soundCheckStop"), action: stop)
                    .disabled(!checking && !probe.draining && !transition)
                if probe.draining { ProgressView().controlSize(.small) }
            }
            if !(model.models.ready || model.models.resourcesAvailable) { Text(model.t("prepare")).font(.caption).foregroundStyle(.secondary) }
            if classroomActive { Text(model.t("soundCheckClassActive")).font(.caption).foregroundStyle(.secondary) }
            else if interpretationActive { Text(model.detail("另一个音频会话正在启动、采集或停止；请先暂停并等待保存完成。")).font(.caption).foregroundStyle(.secondary) }
            ProgressView(value: max(0, min(1, (probe.level + 80) / 80)))
                .accessibilityLabel(model.t("source"))
            HStack {
                Text(model.detail(probe.status)).font(.caption)
                Spacer()
                if probe.phase == .capturing, let deadline = probe.captureDeadline {
                    TimelineView(.periodic(from: .now, by: 1)) { context in
                        Text("\(max(0, Int(ceil(deadline.timeIntervalSince(context.date))))) / 15 s")
                            .font(.caption.monospacedDigit())
                    }
                }
            }
            Text(model.t("soundCheckTemporary")).font(.caption2).foregroundStyle(.secondary)
            if confirmed.isEmpty && probe.provisional.isEmpty { Text(model.t("soundCheckWaiting")).font(.caption).foregroundStyle(.secondary) }
            ForEach(Array(confirmed.enumerated()), id: \.offset) { _, text in Text(text).font(.callout).textSelection(.enabled) }
            if !probe.provisional.isEmpty {
                Text(model.t("provisional") + " · " + probe.provisional).font(.callout).italic().foregroundStyle(.secondary)
            }
        }
        .onAppear {
            probe.refreshDevices()
            source = probe.configuration.source; deviceID = probe.configuration.deviceID.map(String.init) ?? ""
            language = probe.configuration.language
            bindTemporaryCallbacks()
        }
        .onDisappear {
            startTask?.cancel()
            // Synchronous input rejection precedes navigation. The host additionally
            // awaits pause during lifecycle transitions so the bounded tail drains.
            if checking { probe.stopImmediately(reason: model.t("soundCheckStopped")) }
            probe.onConfirmed = nil; probe.onGap = nil; probe.onRecording = nil; probe.onPhaseChanged = nil
            confirmed.removeAll()
        }
        .onReceive(probe.$devices) { _ in
            if deviceID.isEmpty { deviceID = probe.configuration.deviceID.map(String.init) ?? "" }
        }
    }
    private func bindTemporaryCallbacks() {
        probe.onConfirmed = { row in
            confirmed.append(row.text)
            if confirmed.count > 3 { confirmed.removeFirst(confirmed.count - 3) }
        }
        probe.onGap = nil; probe.onRecording = nil; probe.onPhaseChanged = nil
    }
    private func start() {
        guard !checking, !probe.draining, !transition, !model.busy, !anotherCaptureActive, (model.models.ready || model.models.resourcesAvailable), !model.models.busy else { return }
        transition = true; model.audio.stopPlayback(); confirmed.removeAll(); bindTemporaryCallbacks()
        startTask?.cancel()
        let chosen = AudioConfiguration(source: source, deviceID: UInt32(deviceID), language: language, saveRecording: false)
        startTask = Task { @MainActor in
            defer { transition = false }
            probe.selectSession(ended: false)
            await probe.configure(chosen)
            guard !Task.isCancelled, !anotherCaptureActive else { return }
            do {
                // Unique ephemeral identity. No library or cloud can receive these facts.
                try await probe.start(sessionID: "sound-check-" + UUID().uuidString, elapsedOffset: 0, recordingDirectory: nil, maximumCaptureDuration: 15)
            } catch {
                if !(error is CancellationError), !Task.isCancelled { model.report(error) }
            }
        }
    }
    private func stop() {
        startTask?.cancel()
        probe.stopImmediately(reason: model.t("soundCheckStopped"))
    }
}
