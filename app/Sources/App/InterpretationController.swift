import Foundation
import AppKit
import AVFoundation
import Combine

private struct InterpretationMarker: Codable { var sessionID: String; var createdAt = Date() }

@MainActor final class InterpretationController: ObservableObject {
    let audio: AudioController
    let online: InterpretationOnlineRun
    let interpretationSettings: InterpretationServiceSettings
    @Published private(set) var mode: InterpretationMode = .localSpeechText
    var capture: AudioCaptureSession { mode == .localSpeechText ? audio : online.capture }
    var modeLocked: Bool { (record?.state != "draft" && record != nil) || online.runtime?.startedAt != nil }
    var displayError: String? { error ?? (mode.provider != nil ? online.errorCode : nil) }
    let subtitles: SubtitlePanelController
    let settings: CloudServiceSettings
    @Published private(set) var sessions: [WorkspaceItem] = []
    @Published private(set) var selected: WorkspaceItem?
    @Published private(set) var record: ClassroomRecord?
    @Published private(set) var transcripts: [TranscriptRecord] = []
    @Published private(set) var gaps: [TimelineGap] = []
    @Published private(set) var recordings: [RecordingRecord] = []
    @Published private(set) var cloud: CloudController?
    @Published private(set) var busy = false
    @Published var error: String?
    var onLibraryChange: (() -> Void)?
    private let library: LibraryStore
    private let cloudSession: URLSession?
    private var subscriptions = Set<AnyCancellable>(), cloudSubscriptions = Set<AnyCancellable>()
    private var cloudAuthorized = false
    private var pendingTranscripts: [String: TranscriptRecord] = [:]
    private var pendingGaps: [String: TimelineGap] = [:]
    private var pendingRecordings: [String: AudioRecording] = [:]
    private var pendingRecord: ClassroomRecord?
    private var pendingEnd = false
    private var draftTargetLanguage = "zh-Hans"
    private var displayedProvisionalID: String?
    private var factTask: Task<Void, Never>?
    private var factCount = 0
    private func enqueueFact(_ operation: @escaping @MainActor () async -> Void) {
        objectWillChange.send()
        let previous = factTask; factCount += 1
        factTask = Task { [weak self] in
            await previous?.value; await operation()
            guard let self else { return }; self.objectWillChange.send(); self.factCount -= 1
            if self.factCount == 0 { self.factTask = nil }
        }
        // Publish the tail before stop can synchronously admit a phase fact.
        if factCount == 64, [.starting, .capturing].contains(capture.phase) {
            error = "sessionSaveFailed"; capture.stopImmediately(reason: "storage-backpressure")
        }
    }
    private func drainFacts() async { while let pending = factTask { await pending.value } }
    var hasActiveCapture: Bool { [.starting, .capturing].contains(capture.phase) || capture.draining || online.isActive }
    var hasUnsavedContent: Bool { factCount > 0 || online.hasUnsavedContent || !pendingTranscripts.isEmpty || !pendingGaps.isEmpty || !pendingRecordings.isEmpty || pendingRecord != nil || cloud?.hasPendingPersistence == true || cloud?.lastError == .persistence }
    var readOnly: Bool { library.isReadOnly }
    @Published private(set) var courses: [WorkspaceItem] = []
    @Published private(set) var saveLocation: URL?
    var transcriptFileURL: URL? { saveLocation?.appendingPathComponent("transcript.txt") }
    var targetLanguage: String { record?.targetLanguage ?? draftTargetLanguage }

    init(library: LibraryStore, models: ModelManager, settings: CloudServiceSettings, backend: AudioCaptureBackend = HardwareAudioCaptureBackend(), coordinator: CaptureSessionCoordinator? = nil, defaults: UserDefaults = .standard, cloudSession: URLSession? = nil, interpretationSettings: InterpretationServiceSettings? = nil,
         onlineBackend: AudioCaptureBackend? = nil,
         sessionFactory: @escaping @MainActor (InterpretationProvider) -> InterpretationSession = { InterpretationSessionFactory.make(provider: $0) },
         onlinePlayer: InterpretationAudioPlaying? = nil) {
        self.library = library; self.settings = settings; self.cloudSession = cloudSession
        audio = AudioController(modelManager: models, backend: backend, coordinator: coordinator)
        let onlineSettings = interpretationSettings ?? InterpretationServiceSettings(mainAI: settings, defaults: defaults)
        self.interpretationSettings = onlineSettings
        online = InterpretationOnlineRun(library: library, capture: AudioCaptureSession(backend: onlineBackend ?? backend, coordinator: coordinator), settings: onlineSettings, factory: sessionFactory, player: onlinePlayer)
        subtitles = SubtitlePanelController(defaults: defaults)
        subtitles.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        audio.objectWillChange.sink { [weak self] in
            self?.objectWillChange.send()
        }.store(in: &subscriptions)
        audio.$captionProvisional.removeDuplicates().sink { [weak self] value in self?.displayProvisional(value) }.store(in: &subscriptions)
        settings.$configuration.dropFirst().sink { [weak self] value in Task { await self?.cloud?.configure(value) } }.store(in: &subscriptions)
        audio.onConfirmed = { [weak self] value in
            guard let self, self.mode == .localSpeechText else { return }
            // A recognition final replaces its draft in this event turn. Disk
            // persistence remains separately acknowledged by the ordered queue.
            if let provisionalID = value.replacesProvisionalID {
                self.subtitles.removeFragment(provisionalID)
                if self.displayedProvisionalID == provisionalID { self.displayedProvisionalID = nil }
            }
            self.subtitles.updateFragment(CaptionFragment(id: value.id, revision: value.revision, order: Int64(value.start * 1000), text: value.text))
            if let translated = self.subtitles.translationBuffer.fragments.first(where: { $0.id == value.id }), translated.sourceRevision != value.revision { self.subtitles.removeFragment(value.id, translation: true) }
            self.enqueueFact { [weak self] in await self?.acceptTranscript(value) }
        }
        audio.onGap = { [weak self] value in self?.enqueueFact { [weak self] in await self?.acceptGap(value) } }
        audio.onRecording = { [weak self] value in self?.enqueueFact { [weak self] in await self?.acceptRecording(value) } }
        audio.onPhaseChanged = { [weak self] value in self?.enqueueFact { [weak self] in await self?.phaseChanged(value) } }
        online.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        online.capture.objectWillChange.sink { [weak self] in
            guard let self, self.mode.provider != nil else { return }; self.objectWillChange.send()
        }.store(in: &subscriptions)
        online.onCaptionUpdated = { [weak self] row in self?.displayOnlineCaption(row) }
        online.capture.onGap = { [weak self] value in self?.enqueueFact { [weak self] in await self?.acceptGap(value) } }
        online.capture.onRecording = { [weak self] value in self?.enqueueFact { [weak self] in await self?.acceptRecording(value) } }
        online.capture.onPhaseChanged = { [weak self] phase in self?.online.capturePhaseChanged(phase); self?.enqueueFact { [weak self] in await self?.phaseChanged(phase) } }
        Task { await reloadSessions() }
    }
    func setMode(_ value: InterpretationMode) async {
        guard !readOnly, !busy, !hasActiveCapture, !hasUnsavedContent, value != mode else { return }
        guard !modeLocked else { error = "onlineNewSessionRequired"; return }
        let configuration = capture.configuration
        mode = value; error = nil
        capture.selectSession(ended: false); await capture.configure(configuration); await drainFacts()
        if let id = selected?.id {
            do {
                if let provider = value.provider {
                    var runtime = InterpretationRuntimeRecord(sessionID: id)
                    runtime.mode = value.rawValue; runtime.provider = provider.rawValue
                    runtime.modelID = interpretationSettings.profile(for: provider).modelID
                    runtime.sourceLanguage = configuration.language; runtime.subtitleLanguage = targetLanguage
                    runtime.targetLanguage = provider == .google ? targetLanguage : "zh"
                    try library.saveInterpretationRuntime(runtime)
                } else { try library.removeRecord(collection: "interpretation-runtime", id: id) }
                await selectSession(id)
            } catch { self.error = "sessionSaveFailed" }
        }
    }
    private func startOnline() async {
        guard !busy, !hasActiveCapture, var value = record, value.state != "ended", !hasUnsavedContent else { return }
        do {
            try library.checkWritable(); guard saveLocation != nil else { throw LibraryError.message("transcriptLocationMissing") }
            if value.timelineMilliseconds > 0, capture.sessionID != value.id {
                let end = value.timelineMilliseconds + Int64(max(0, Date().timeIntervalSince(value.updatedAt)) * 1000)
                let gap = TimelineGap(classroomID: value.id, epochID: nil, startMS: value.timelineMilliseconds, endMS: end, reason: "recovered-interruption-wall-clock-estimate")
                try library.withTransaction {
                    try library.saveGap(gap)
                    value.timelineMilliseconds = end; value.updatedAt = Date(); try library.saveClassroom(value)
                }
                gaps.append(gap); record = value
            }
        }
        catch { self.error = "sessionSaveFailed"; return }
        error = nil
        await online.start(sessionID: value.id, mode: mode, sourceLanguage: capture.configuration.language, targetLanguage: targetLanguage,
                           offset: Double(value.timelineMilliseconds) / 1000, recordingDirectory: value.recordingEnabled ? recordingDirectory() : nil)
    }
    func reloadSessions() async {
        do {
            let library = self.library, selectedID = selected?.id
            let result = try await Task.detached { () -> ([WorkspaceItem], [WorkspaceItem], URL?) in
                let markers = try library.records(collection: "interpretation-sessions", as: InterpretationMarker.self)
                let ids = Set(markers.map(\.sessionID)), items = try library.items()
                let sessions = items.filter { ids.contains($0.id) }.sorted { $0.createdAt > $1.createdAt }
                let directory = try selectedID.flatMap { id in try sessions.first(where: { $0.id == id }).flatMap { try library.transcriptStore?.directory(for: $0) } }
                return (sessions, items.filter { $0.kind == .course }, directory)
            }.value
            if sessions != result.0 { sessions = result.0 }; if courses != result.1 { courses = result.1 }
            if selected?.id == selectedID, let id = selectedID { selected = sessions.first { $0.id == id }; saveLocation = result.2 }
            onLibraryChange?()
        } catch { self.error = error.localizedDescription }
    }
    func newSession(title: String = "") async {
        guard !hasActiveCapture, !busy else { error = "pauseBeforeSwitch"; return }
        guard !hasUnsavedContent else { error = "sessionSaveFailed"; return }
        do {
            let name = title.isEmpty ? "ULecture · " + DateFormatter.localizedString(from: Date(), dateStyle: .medium, timeStyle: .short) : title
            let item = try library.withTransaction {
                let item = try library.createStandaloneSession(title: name)
                var draft = ClassroomRecord(id: item.id)
                draft.inputSource = capture.configuration.source.rawValue
                draft.inputDeviceID = capture.configuration.deviceID.map(String.init)
                draft.mainLanguage = capture.configuration.language
                draft.recordingEnabled = capture.configuration.saveRecording
                draft.targetLanguage = targetLanguage
                try library.saveClassroom(draft)
                if let provider = mode.provider {
                    var runtime = InterpretationRuntimeRecord(sessionID: item.id)
                    runtime.mode = mode.rawValue; runtime.provider = provider.rawValue
                    runtime.modelID = interpretationSettings.profile(for: provider).modelID
                    runtime.sourceLanguage = draft.mainLanguage; runtime.subtitleLanguage = draft.targetLanguage
                    runtime.targetLanguage = provider == .google ? draft.targetLanguage : "zh"
                    try library.saveInterpretationRuntime(runtime)
                }
                try library.putRecord(collection: "interpretation-sessions", id: item.id, ownerID: item.id, value: InterpretationMarker(sessionID: item.id))
                return item
            }
            await reloadSessions(); await selectSession(item.id)
        } catch { self.error = error.localizedDescription }
    }
    func selectSession(_ id: String) async {
        guard !hasActiveCapture, !busy else { error = "pauseBeforeSwitch"; return }
        guard !hasUnsavedContent else { error = "sessionSaveFailed"; return }
        busy = true; defer { busy = false }
        do {
            await reloadSessions()
            guard let item = sessions.first(where: { $0.id == id }) else { return }
            let library = self.library
            let snapshot = try await Task.detached {
                (try library.classroom(id: id), try library.transcripts(classroomID: id),
                 try library.records(collection: "gaps", ownerID: id, as: TimelineGap.self), try library.recordings(classroomID: id),
                 try library.record(collection: "cloud-state", id: id, as: CloudState.self), try library.transcriptStore?.directory(for: item))
            }.value
            guard let stored = snapshot.0 else { return }
            capture.stopPlayback(); await cloud?.shutdown()
            guard !hasUnsavedContent else { error = "sessionSaveFailed"; return }
            cloudSubscriptions.removeAll(); cloudAuthorized = false
            try await online.load(sessionID: id)
            mode = online.runtime.flatMap { InterpretationMode(rawValue: $0.mode) } ?? .localSpeechText
            selected = item; record = stored; pendingEnd = false
            subtitles.resetCaptions(); displayedProvisionalID = nil
            transcripts = snapshot.1; gaps = snapshot.2; recordings = snapshot.3; saveLocation = snapshot.5
            capture.selectSession(ended: stored.state == "ended")
            var configuration = AudioConfiguration(source: stored.inputSource == "system" ? .system : .microphone, deviceID: stored.inputDeviceID.flatMap(UInt32.init), language: stored.mainLanguage, saveRecording: stored.recordingEnabled)
            // An explicitly new session can use the currently selected device;
            // an unavailable saved device never falls back silently.
            if stored.state == "draft", configuration.deviceID == nil { configuration.deviceID = capture.configuration.deviceID }
            if stored.state != "ended" { await capture.configure(configuration); await drainFacts() }
            await drainFacts()
            if mode.provider != nil {
                cloud = nil
                if !library.isReadOnly { await recoverRecordings() }
                refreshCaptions(); return
            }
            var state = snapshot.4 ?? CloudState(classID: id)
            state.translationUserPaused = stored.translationUserPaused
            let next = CloudController(state: state, configuration: settings.configuration, session: cloudSession, monitorNetwork: !library.isReadOnly)
            next.credentialResolver = { [weak self] config in
                guard let self, self.cloudAuthorized, !self.library.isReadOnly else { return nil }
                return try self.settings.credential(for: config)
            }
            next.onPersist = { [weak self] state in
                guard let self else { throw LibraryError.message("Library closed") }
                guard !self.library.isReadOnly else { return }
                do {
                    let library = self.library
                    try await Task.detached { try library.withTransaction {
                        try library.putRecord(collection: "cloud-state", id: id, ownerID: id, value: state)
                        if var record = try library.classroom(id: id) { record.translationUserPaused = state.translationUserPaused; try library.saveClassroom(record) }
                    } }.value
                    if self.selected?.id == id { self.record?.translationUserPaused = state.translationUserPaused }
                } catch { self.storageFailed(error); throw error }
            }
            next.onSavedTranslation = { [weak self] value in self?.displayTranslation(value) }
            next.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cloudSubscriptions)
            next.speech.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &cloudSubscriptions)
            cloud = next
            if !library.isReadOnly {
                for row in transcripts { try await next.enqueueSavedSegment(segment(row), targetLanguage: stored.targetLanguage, historical: true) }
                await recoverRecordings()
            }
            refreshCaptions()
        } catch { self.error = error.localizedDescription }
    }
    func configure(_ configuration: AudioConfiguration, targetLanguage: String? = nil) async {
        guard !readOnly, !busy else { return }
        guard record?.state != "ended" else { error = "sessionEnded"; return }
        busy = true; defer { busy = false }
        if let targetLanguage, mode.provider != nil, modeLocked, targetLanguage != self.targetLanguage { error = "onlineNewSessionRequired"; return }
        if mode.provider != nil, hasActiveCapture { await online.pause() }
        if let targetLanguage { draftTargetLanguage = targetLanguage == "zh-Hant" ? "zh-Hant" : "zh-Hans" }
        stopSpeech()
        await capture.configure(configuration); await drainFacts()
        guard !capture.requiresRestartAfterStopFailure else { return }
        guard var value = record else { return }
        guard value.state != "ended" else { error = "sessionEnded"; return }
        value.inputSource = configuration.source.rawValue; value.inputDeviceID = configuration.deviceID.map(String.init)
        value.mainLanguage = configuration.language == "ja" ? "ja" : "en"; value.recordingEnabled = configuration.saveRecording
        if targetLanguage != nil {
            if value.targetLanguage != draftTargetLanguage { subtitles.resetTranslations() }
            value.targetLanguage = draftTargetLanguage
        }
        // Preserve the saved pause/interruption anchor while editing a session
        // that has not resumed. A configuration edit is not captured time.
        await saveRecord(value)
        for row in transcripts where mode == .localSpeechText { do { try await cloud?.enqueueSavedSegment(segment(row), targetLanguage: value.targetLanguage, historical: true) } catch { self.error = error.localizedDescription } }
        refreshCaptions()
    }
    func start() async {
        if selected == nil { await newSession() }
        if mode.provider != nil { await startOnline(); return }
        guard !busy, !hasActiveCapture, var value = record else { return }
        guard value.state != "ended" else { error = "sessionEnded"; return }
        guard !hasUnsavedContent else { error = "sessionSaveFailed"; return }
        busy = true; defer { busy = false }
        do {
            try library.checkWritable()
            guard saveLocation != nil else { throw LibraryError.message("transcriptLocationMissing") }
            value = try library.classroom(id: value.id) ?? value
            var offset = Double(value.timelineMilliseconds) / 1000
            if ["interrupted", "paused", "capturing", "preparing"].contains(value.state), value.timelineMilliseconds > 0, audio.sessionID != value.id {
                let end = value.timelineMilliseconds + Int64(max(0, Date().timeIntervalSince(value.updatedAt)) * 1000)
                let gap = TimelineGap(classroomID: value.id, epochID: nil, startMS: value.timelineMilliseconds, endMS: end, reason: "recovered-interruption-wall-clock-estimate")
                try library.saveGap(gap); gaps.append(gap); offset = Double(end) / 1000; value.timelineMilliseconds = end
            }
            value.state = "preparing"; value.updatedAt = Date(); try library.saveClassroom(value); record = value
            cloudAuthorized = true; error = nil
            let directory = value.recordingEnabled ? recordingDirectory() : nil
            try await audio.start(sessionID: value.id, elapsedOffset: offset, recordingDirectory: directory)
            guard audio.phase == .capturing else { return }
            await cloud?.setClassActive(true); await cloud?.pump()
        } catch { self.error = error.localizedDescription; if var value = record, value.state != "ended" { value.state = "paused"; await saveRecord(value) } }
    }
    func pause() async { if mode.provider != nil { await online.pause(); await drainFacts(); return }; stopSpeech(); await cloud?.setClassActive(false); await audio.pause(reason: "user-paused"); await drainFacts() }
    func end() async {
        if mode.provider != nil {
            guard !busy, record != nil else { return }
            busy = true; pendingEnd = true; defer { busy = false }
            await online.end(); await drainFacts()
            guard online.state == .ended, !hasUnsavedContent else { error = "sessionSaveFailed"; return }
            if var value = record { value.state = "ended"; value.updatedAt = Date(); await saveRecord(value); if pendingRecord == nil { pendingEnd = false } }
            return
        }
        guard !busy, record != nil else { return }; busy = true; pendingEnd = true; defer { busy = false }
        stopSpeech(); await cloud?.setClassActive(false); await audio.end(); await drainFacts()
        await cloud?.waitForPersistence()
        guard audio.phase == .ended, !hasUnsavedContent else { error = audio.requiresRestartAfterStopFailure ? audio.status : "sessionSaveFailed"; return }
        if var value = record { value.state = "ended"; value.updatedAt = Date(); await saveRecord(value); if pendingRecord == nil { pendingEnd = false } }
    }
    func setTranslationPaused(_ paused: Bool) async {
        guard !readOnly, mode == .localSpeechText else { return }
        if !paused { cloudAuthorized = true }
        await cloud?.setUserPaused(paused)
    }
    func retryTranslation(_ id: String) async { guard mode == .localSpeechText, !readOnly else { return }; cloudAuthorized = true; await cloud?.retry(jobID: id) }
    func stopSpeech() { if mode.provider != nil { online.speechEnabled = false }; cloud?.stopSpeech() }
    func setSpeechEnabled(_ enabled: Bool) { enabled ? cloud?.speech.enable() : cloud?.speech.stop() }
    func associateCourse(_ id: String) async {
        guard !hasActiveCapture, !hasUnsavedContent, let session = selected else { error = "pauseBeforeSwitch"; return }
        do { let library = self.library; try await Task.detached { try library.associateStandaloneSession(id: session.id, courseID: id) }.value; await reloadSessions() }
        catch { self.error = error.localizedDescription }
    }
    func translation(for row: TranscriptRecord) -> CloudTranslationJob? {
        cloud?.state.jobs.last { $0.segment.id == row.id && $0.segment.revision == row.revision && $0.targetLanguage == targetLanguage && $0.status != .obsolete }
    }
    private func segment(_ row: TranscriptRecord) -> CloudSegment { CloudSegment(id: row.id, classID: row.classroomID, revision: row.revision, text: row.text, language: row.language, startMS: row.startMS, endMS: row.endMS, confirmedAt: row.confirmedAt) }
    private func saveRecord(_ value: ClassroomRecord) async {
        record = value
        do { let library = self.library; try await Task.detached { try library.saveClassroom(value) }.value; pendingRecord = nil }
        catch { pendingRecord = value; storageFailed(error) }
    }
    private func phaseChanged(_ phase: AudioPhase) async {
        guard [.capturing, .paused, .ended].contains(phase), var value = record, capture.sessionID == value.id else { return }
        value.state = phase == .capturing ? "capturing" : "paused"
        value.timelineMilliseconds = max(value.timelineMilliseconds, Int64(capture.currentOffset * 1000)); value.updatedAt = Date()
        if phase != .capturing { await cloud?.setClassActive(false) }
        await saveRecord(value)
    }
    private func acceptTranscript(_ value: AudioTranscript) async {
        guard mode == .localSpeechText else { return }
        let row = TranscriptRecord(id: value.id, classroomID: value.sessionID, epochID: value.epochID, startMS: Int64(value.start * 1000), endMS: Int64(value.end * 1000), text: value.text, language: value.language, revision: value.revision, confirmedAt: value.confirmedAt)
        do {
            let library = self.library; try await Task.detached { try library.saveTranscript(row) }.value; pendingTranscripts[row.id] = nil
            if let index = transcripts.firstIndex(where: { $0.id == row.id }) { transcripts[index] = row } else { transcripts.append(row) }
        } catch { pendingTranscripts[row.id] = row; storageFailed(error); return }
        // A full translation queue does not make a durable source transcript
        // unsaved. It remains on disk and can be reconciled after retry.
        do { try await cloud?.enqueueSavedSegment(segment(row), targetLanguage: targetLanguage) }
        catch { self.error = error.localizedDescription }
        if let provisionalID = value.replacesProvisionalID { subtitles.removeFragment(provisionalID); if displayedProvisionalID == provisionalID { displayedProvisionalID = nil } }
        displayTranscript(row)
    }
    private func acceptGap(_ value: AudioGap) async {
        let gap = TimelineGap(id: value.id, classroomID: value.sessionID, epochID: value.epochID, startMS: Int64(value.start * 1000), endMS: Int64(value.end * 1000), reason: value.reason)
        do { let library = self.library; try await Task.detached { try library.saveGap(gap) }.value; pendingGaps[gap.id] = nil; if !gaps.contains(where: { $0.id == gap.id }) { gaps.append(gap) } }
        catch { pendingGaps[gap.id] = gap; storageFailed(error) }
    }
    private func recordingDirectory() -> URL? { saveLocation?.appendingPathComponent("recording-staging", isDirectory: true) }
    private func acceptRecording(_ value: AudioRecording) async {
        guard let directory = recordingDirectory() else { pendingRecordings[value.id] = value; storageFailed(LibraryError.message("transcriptLocationMissing")); return }
        do {
            let source = directory.appendingPathComponent(value.filename)
            let library = self.library
            let saved = try await Task.detached {
                if try library.record(collection: "recording-receipts", id: value.id, as: String.self) == nil {
                    try library.withTransaction {
                        _ = try library.importRecording(from: source, classroomID: value.sessionID, epochID: value.epochID, startMS: Int64(value.start * 1000), endMS: Int64(value.end * 1000))
                        try library.putRecord(collection: "recording-receipts", id: value.id, ownerID: value.sessionID, value: "committed")
                    }
                }
                try? FileManager.default.removeItem(at: source)
                return try library.recordings(classroomID: value.sessionID)
            }.value
            pendingRecordings[value.id] = nil; recordings = saved
        } catch { pendingRecordings[value.id] = value; storageFailed(error) }
    }
    private func recoverRecordings() async {
        guard let item = selected, let directory = recordingDirectory(), let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return }
        for url in files where url.pathExtension == "caf" {
            do {
                guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { continue }
                let fields = url.deletingPathExtension().lastPathComponent.split(separator: "_").map(String.init)
                guard fields.count == 3, UUID(uuidString: fields[0]) != nil, let offset = Int64(fields[1]), offset >= 0, UUID(uuidString: fields[2]) != nil else { continue }
                let file = try AVAudioFile(forReading: url); guard file.length > 0, file.fileFormat.sampleRate > 0 else { continue }
                let start = Double(offset) / 1000
                await acceptRecording(AudioRecording(id: fields[2], sessionID: item.id, epochID: fields[0], filename: url.lastPathComponent, start: start, end: start + Double(file.length) / file.fileFormat.sampleRate, frames: file.length, verified: true))
            } catch { self.error = error.localizedDescription }
        }
    }
    private func storageFailed(_ failure: Error) {
        error = failure.localizedDescription; stopSpeech()
        if mode.provider != nil { online.handlePersistenceFailure() }
        else if [.starting, .capturing].contains(capture.phase) { capture.stopImmediately(reason: "storage-failure") }
    }
    func retryUnsaved() async {
        guard !busy else { return }
        busy = true; defer { busy = false }
        if hasActiveCapture { await pause() }
        await drainFacts()
        // Retries share the admitted fact queue. A newer callback cannot race
        // an older retained revision's receipt and then be cleared by it.
        enqueueFact { [weak self] in await self?.retryPendingFacts() }
        await drainFacts()
        if !hasUnsavedContent, pendingEnd, mode.provider != nil {
            await online.end(); await drainFacts()
        }
        if !hasUnsavedContent, pendingEnd, capture.phase == .ended, (mode.provider == nil || online.state == .ended), var value = record {
            value.state = "ended"; await saveRecord(value)
            if pendingRecord == nil { pendingEnd = false }
        }
        if !hasUnsavedContent { error = nil }; refreshCaptions()
    }
    private func retryPendingFacts() async {
        do {
            let library = self.library
            try await Task.detached { try library.checkWritable() }.value
            await online.retrySave()
            if let pendingRecord {
                try await Task.detached { try library.saveClassroom(pendingRecord) }.value
                if self.pendingRecord == pendingRecord { self.pendingRecord = nil }
            }
            for row in Array(pendingTranscripts.values) {
                try await Task.detached { try library.saveTranscript(row) }.value
                if pendingTranscripts[row.id]?.revision == row.revision { pendingTranscripts[row.id] = nil }
            }
            for gap in Array(pendingGaps.values) { try await Task.detached { try library.saveGap(gap) }.value; pendingGaps[gap.id] = nil }
            for recording in Array(pendingRecordings.values) { await acceptRecording(recording) }
            await cloud?.resumeAfterPersistenceRepair()
            if let id = selected?.id {
                let snapshot = try await Task.detached {
                    (try library.transcripts(classroomID: id), try library.records(collection: "gaps", ownerID: id, as: TimelineGap.self))
                }.value
                transcripts = snapshot.0; gaps = snapshot.1
                for row in transcripts where mode == .localSpeechText { try await cloud?.enqueueSavedSegment(segment(row), targetLanguage: targetLanguage, historical: true) }
            }
        } catch { storageFailed(error) }
    }
    func play(from milliseconds: Int64) {
        guard let row = recordings.first(where: { $0.startMS <= milliseconds && milliseconds < $0.endMS }) else { error = "recordingNotAvailable"; return }
        do { try capture.playRecording(url: library.attachmentURL(assetID: row.assetID), from: Double(milliseconds - row.startMS + row.fileStartMS) / 1000) }
        catch { self.error = error.localizedDescription }
    }
    func revealTranscriptInFinder(kind: TranscriptTextKind = .source) async {
        guard let selected, let store = library.transcriptStore else { error = "transcriptLocationMissing"; return }
        do {
            let writable = !readOnly
            let url = try await Task.detached {
                if writable { try store.synchronizeTextFile(for: selected) }
                let url = try store.fileURL(for: selected, kind: kind)
                guard FileManager.default.isReadableFile(atPath: url.path) else { throw LibraryError.message("transcriptLocationMissing") }
                return url
            }.value
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch { self.error = error.localizedDescription }
    }
    private func displayTranscript(_ row: TranscriptRecord) {
        subtitles.updateFragment(CaptionFragment(id: row.id, revision: row.revision, order: row.startMS, text: row.text))
        if let current = subtitles.translationBuffer.fragments.first(where: { $0.id == row.id }), current.sourceRevision != row.revision { subtitles.removeFragment(row.id, translation: true) }
    }
    private func displayTranslation(_ value: CloudTranslation) {
        guard value.classID == selected?.id, value.targetLanguage == targetLanguage,
              let row = transcripts.first(where: { $0.id == value.segmentID && $0.revision == value.sourceRevision }) else { return }
        subtitles.updateFragment(CaptionFragment(id: row.id, revision: value.dispatch.version, order: row.startMS,
            text: value.text, sourceRevision: value.sourceRevision), translation: true)
    }
    private func displayProvisional(_ value: AudioProvisional?) {
        guard mode == .localSpeechText else { return }
        if displayedProvisionalID != value?.id, let old = displayedProvisionalID { subtitles.removeFragment(old) }
        displayedProvisionalID = value?.id
        if let value { subtitles.updateFragment(CaptionFragment(id: value.id, revision: value.revision, order: Int64(value.start * 1000), text: value.text, state: .provisional)) }
    }
    private func displayOnlineCaption(_ row: InterpretationCaptionRecord) {
        let state: CaptionFragment.State = row.isFinal ? .confirmed : row.completionBasis == "interrupted" ? .interrupted : .partial
        subtitles.updateFragment(CaptionFragment(id: row.id, revision: row.revision, order: Int64(clamping: row.sequence), text: row.text, state: state), translation: row.track == "translation")
    }
    func refreshCaptions(provisional: String? = nil) {
        if mode.provider != nil {
            for track in ["source", "translation"] { for row in online.captions.lazy.filter({ $0.track == track }).suffix(256) { displayOnlineCaption(row) } }
            return
        }
        // Rehydrate a bounded tail on selection/recovery. Streaming callbacks
        // update individual fragments and do not scan full history per delta.
        if let provisional {
            subtitles.updateFragment(CaptionFragment(id: "diagnostic-provisional", revision: 0, order: .max, text: provisional, state: .provisional)); return
        }
        for row in transcripts.suffix(256) { displayTranscript(row) }
        let current = Dictionary(transcripts.map { ($0.id, $0.revision) }, uniquingKeysWith: max)
        let translated = (cloud?.state.jobs ?? []).filter { $0.status == .completed && current[$0.segment.id] == $0.segment.revision && $0.translation?.targetLanguage == targetLanguage }.sorted { $0.segment.startMS < $1.segment.startMS }.suffix(256)
        for job in translated { if let value = job.translation { displayTranslation(value) } }
        displayProvisional(audio.captionProvisional)
    }
    func prepareForExit() async -> Bool {
        stopSpeech(); capture.stopPlayback(); if mode.provider != nil { await online.pause() } else { await audio.pause(reason: "application-closed") }
        await drainFacts()
        guard !capture.requiresRestartAfterStopFailure else { return false }
        await cloud?.shutdown(); guard !hasUnsavedContent else { return false }
        subtitles.dispose(); return true
    }
}
