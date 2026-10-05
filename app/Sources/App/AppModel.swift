import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers
import Combine

/// All session disk work shares one FIFO; UI actors never block on SQLite/TXT writes.
final class SessionDiskExecutor: @unchecked Sendable {
    static let shared = SessionDiskExecutor()
    private let queue = DispatchQueue(label: "local.ulecture.session-disk", qos: .utility)
    func run<Value>(_ work: @escaping () throws -> Value) async throws -> Value {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { do { continuation.resume(returning: try work()) } catch { continuation.resume(throwing: error) } }
        }
    }
}

@MainActor final class AppModel: ObservableObject {
    @Published var route = "setup"
    @Published var items: [WorkspaceItem] = [] { didSet { rebuildWorkspaceIndex() } }
    @Published var selectedID: String?
    @Published var error: String?
    @Published var notice: String?
    @Published var busy = false
    @Published var drafts: [String: String] = [:]
    @Published var saveStates: [String: String] = [:]
    @Published var classRecords: [String: ClassroomRecord] = [:]
    @Published var transcriptRows: [String: [TranscriptRecord]] = [:]
    @Published var recordingsByClass: [String: [RecordingRecord]] = [:]
    @Published var gapsByClass: [String: [TimelineGap]] = [:]
    @Published var pdfSelection: [String: String] = [:]
    @Published var pdfPages: [String: Int] = [:]
    @Published var classNoteIDs: [String: String] = [:]
    @Published var transcriptFocusIDs: [String: String] = [:]
    @Published var exportedURL: URL?
    @Published var transcriptExportItem: WorkspaceItem?
    @Published var usageRevision = 0
    @Published var activeClassID: String?
    @Published var sidebarVisible = true
    @Published var sourcePreview: SummarySource?
    // Only the assistant observes this selection; publishing it on AppModel
    // would rebuild navigation for every native text-selection change.
    var documentSelection: DocumentSelection? { didSet { assistant?.selection = documentSelection } }
    @Published var assistant: AIAssistantController?
    @Published var cloudConfiguration: CloudConfiguration
    let preferences = AppPreferences.shared
    let models: ModelManager
    let audio: AudioController
    let probe: AudioController
    let serviceSettings: CloudController
    let cloudService: CloudServiceSettings
    let textTranslationService: CloudServiceSettings
    let documentTranslationService: CloudServiceSettings
    let interpretationService: InterpretationServiceSettings
    let textTranslation: TextTranslationController
    let documentTranslation: DocumentTranslationController
    var cloudEnabledForRun = false
    private(set) var library: LibraryStore?
    var workspaceCatalog: WorkspaceCatalog?
    @Published var projectMounts: [ProjectMount] = [] { didSet { rebuildWorkspaceIndex() } }
    @Published var missingDocumentIDs = Set<String>()
    @Published var documentIDsByClass: [String: Set<String>] = [:]
    @Published var unavailableProjectIDs = Set<String>()
    @Published var legacyLibraryURL: URL?
    @Published var transcriptStorageReady = false
    @Published var interpretation: InterpretationController?
    var workspaceRefreshTask: Task<Void, Never>?
    var projectRefreshTask: Task<Void, Never>?
    lazy var workspaceDirectoryObserver = WorkspaceDirectoryObserver { [weak self] in self?.refreshProjects(reportErrors: false, showProgress: false) }
    var clouds: [String: CloudController] = [:]
    var subscriptions = Set<AnyCancellable>()
    var saveTasks: [String: Task<Void, Never>] = [:]
    #if AUDIO_TESTING
    var onTranscriptSavedForChecks: ((TranscriptRecord) -> Void)?
    #endif
    private var sessionWorkTail: Task<Void, Never>?
    private(set) var pendingSessionOperations = 0
    /// Each callback is admitted synchronously, then committed in arrival order.
    /// The tail is explicitly drained before pause/end, library changes and exit.
    func enqueueSessionWork(_ operation: @escaping @MainActor () async -> Void) {
        let previous = sessionWorkTail; pendingSessionOperations += 1
        sessionWorkTail = Task { [weak self] in
            await previous?.value; await operation()
            guard let self else { return }; self.pendingSessionOperations -= 1
            if self.pendingSessionOperations == 0 { self.sessionWorkTail = nil }
        }
        // Install the tail before stopping: stop may synchronously enqueue a
        // lifecycle checkpoint, which must follow this operation rather than
        // being overwritten by it.
        if pendingSessionOperations >= 64, [.capturing, .starting].contains(audio.phase) {
            audio.stopImmediately(reason: "storage-backpressure")
        }
    }
    func drainSessionWork() async { while let tail = sessionWorkTail { await tail.value } }
    var lastDeletedID: String?
    var pauseAnchors: [String: TimeInterval] = [:]
    var pendingTranscripts: [TranscriptRecord] = []
    var pendingRecordings: [AudioRecording] = []
    var pendingGaps: [AudioGap] = []
    var pendingClassRecords: [String: ClassroomRecord] = [:]
    @Published var pendingEndIDs = Set<String>()
    var isTestMode: Bool { CommandLine.arguments.contains("--ui-test-library") || CommandLine.arguments.contains("--ui-test-workspace") }

    init() {
        let args = CommandLine.arguments
        let testCache = args.firstIndex(of: "--model-cache").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        models = ModelManager(cacheDirectory: testCache)
        audio = AudioController(modelManager: models)
        probe = AudioController(modelManager: models)
        let initialConfiguration: CloudConfiguration
        if let data = AppPreferences.shared.defaults.data(forKey: "cloudConfiguration"), let config = try? JSONDecoder().decode(CloudConfiguration.self, from: data) { initialConfiguration = config }
        else { initialConfiguration = CloudConfiguration() }
        cloudService = CloudServiceSettings(initialConfiguration: initialConfiguration, defaults: AppPreferences.shared.defaults)
        textTranslationService = CloudServiceSettings(defaults: AppPreferences.shared.defaults, scope: "textTranslation", sharedService: cloudService)
        documentTranslationService = CloudServiceSettings(defaults: AppPreferences.shared.defaults, scope: "documentTranslation", sharedService: cloudService)
        interpretationService = InterpretationServiceSettings(mainAI: cloudService, defaults: AppPreferences.shared.defaults)
        cloudConfiguration = cloudService.configuration
        let testLibrary = (args.firstIndex(of: "--ui-test-library") ?? args.firstIndex(of: "--ui-test-workspace")).flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
        let toolRoot = (testLibrary ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("ULecture")).appendingPathComponent("TextTranslation")
        textTranslation = TextTranslationController(settings: textTranslationService, directory: toolRoot)
        documentTranslation = DocumentTranslationController(settings: documentTranslationService, directory: toolRoot.deletingLastPathComponent().appendingPathComponent("FileTranslation"))
        let settingsState = AppPreferences.shared.defaults.data(forKey: "serviceUsageState").flatMap { try? JSONDecoder().decode(CloudState.self, from: $0) } ?? CloudState(classID: "settings")
        serviceSettings = CloudController(state: settingsState, configuration: cloudService.configuration)
        cloudService.onConfigurationChanged = { [weak self] config in self?.applyCloudConfiguration(config) }
        cloudService.onUsage = { [weak self] _ in self?.usageRevision += 1 }
        textTranslationService.onUsage = { [weak self] _ in self?.usageRevision += 1 }
        documentTranslationService.onUsage = { [weak self] _ in self?.usageRevision += 1 }
        serviceSettings.onPersist = { [weak self] state in
            guard let self else { return }
            self.preferences.defaults.set(try JSONEncoder().encode(state), forKey: "serviceUsageState")
            self.usageRevision += 1
        }
        route = preferences.hideSetup ? "workspace" : "setup"
        models.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        // Capture meters/provisional strings are observed by the pane that draws
        // them. Only lifecycle changes need to refresh navigation and the toolbar.
        audio.$phase.removeDuplicates().dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        audio.$status.removeDuplicates().dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        audio.$configuration.removeDuplicates().dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        audio.$draining.removeDuplicates().dropFirst().sink { [weak self] _ in self?.objectWillChange.send() }.store(in: &subscriptions)
        serviceSettings.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        cloudService.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        textTranslationService.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        interpretationService.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        documentTranslationService.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        documentTranslation.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        textTranslation.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
        audio.onConfirmed = { [weak self] row in self?.acceptTranscript(row) }
        audio.onGap = { [weak self] gap in self?.acceptGap(gap) }
        audio.onRecording = { [weak self] recording in self?.enqueueSessionWork { [weak self] in _ = await self?.acceptRecording(recording) } }
        audio.onPhaseChanged = { [weak self] phase in self?.audioPhaseChanged(phase) }
        if let i = args.firstIndex(of: "--ui-test-library"), i + 1 < args.count {
            openLibrary(URL(fileURLWithPath: args[i + 1]), remember: false)
        } else {
            if let path = UserDefaults.standard.string(forKey: "libraryPath") { legacyLibraryURL = URL(fileURLWithPath: path) }
            openDefaultWorkspace()
        }
        if !isTestMode { Task { await models.restoreAtLaunch() } }
    }
    func t(_ key: String) -> String { preferences.t(key) }
    private var indexedItems: [String: WorkspaceItem] = [:]
    private var visibleSnapshot: [WorkspaceItem] = []
    private var childrenByParent: [String: [WorkspaceItem]] = [:]
    private func rebuildWorkspaceIndex() {
        indexedItems = Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { _, newer in newer })
        let unmounted = Set(projectMounts.filter { !$0.mounted }.map(\.id))
        visibleSnapshot = items.filter { $0.deletedAt == nil && !unmounted.contains($0.courseID ?? $0.id) && !($0.kind == .classroom && $0.courseID == nil) }
        childrenByParent = Dictionary(grouping: visibleSnapshot, by: { $0.parentID ?? "" }).mapValues { $0.sorted(by: WorkspaceCatalog.ordered) }
    }
    var selected: WorkspaceItem? { selectedID.flatMap { indexedItems[$0] } }
    var visibleItems: [WorkspaceItem] { visibleSnapshot }
    var selectedClassID: String? { selected.flatMap { $0.kind == .classroom ? $0.id : $0.classroomID } }
    var currentClass: ClassroomRecord? { selectedClassID.flatMap { classRecords[$0] } }
    var currentCloud: CloudController? { selectedClassID.flatMap { clouds[$0] } }
    func children(_ id: String?) -> [WorkspaceItem] { childrenByParent[id ?? ""] ?? [] }
    func report(_ error: Error) { self.error = error.localizedDescription }
    func reload() throws {
        guard let library else { return }
        let nextItems = try library.items(includeDeleted: true)
        var nextClassRecords = classRecords
        for item in nextItems where item.kind == .classroom {
            nextClassRecords[item.id] = try library.classroom(id: item.id)
        }
        // Read links once per catalog snapshot, never from a SwiftUI row body.
        let links = try library.records(collection: "session-document-links", as: SessionDocumentLink.self)
        var nextDocumentIDs: [String: Set<String>] = [:]
        for link in links { nextDocumentIDs[link.sessionID, default: []].insert(link.documentID) }
        for item in nextItems where item.kind != .classroom { if let sessionID = item.classroomID { nextDocumentIDs[sessionID, default: []].insert(item.id) } }
        if nextDocumentIDs != documentIDsByClass { documentIDsByClass = nextDocumentIDs }
        // Folder scans run in the background. Equal snapshots must not publish
        // changes or cause unrelated settings/editing views to redraw.
        if items != nextItems { items = nextItems }
        if classRecords != nextClassRecords { classRecords = nextClassRecords }
        if let workspaceCatalog {
            let nextMounts = try workspaceCatalog.mounts(includeUnmounted: true)
            if projectMounts != nextMounts { projectMounts = nextMounts }
            workspaceDirectoryObserver.observe(try workspaceCatalog.mounts().map(\.rootPath))
            let nextMissingIDs = Set(try library.records(collection: "document-locators", as: DocumentLocator.self).filter(\.missing).map(\.id))
            if missingDocumentIDs != nextMissingIDs { missingDocumentIDs = nextMissingIDs }
        }
    }
    func openLibrary(_ url: URL, remember: Bool = true, create: Bool = true) {
        if library?.rootURL.standardizedFileURL.resolvingSymlinksInPath().path == url.standardizedFileURL.resolvingSymlinksInPath().path { return }
        guard !busy, !audio.draining, audio.phase != .capturing && audio.phase != .starting else { error = t("pause") + " · " + t("changeLibrary"); return }
        guard flushDrafts(), !hasUnsavedFacts else { error = t("saveFailed"); return }
        if clouds.isEmpty { installLibrary(url, remember: remember, create: create); return }
        busy = true
        enqueueSessionWork { [weak self] in
            guard let self else { return }; defer { self.busy = false }
            for cloud in self.clouds.values { await cloud.shutdown() }
            guard self.pendingTranscripts.isEmpty, self.pendingRecordings.isEmpty, self.pendingGaps.isEmpty, self.pendingClassRecords.isEmpty,
                  !self.clouds.values.contains(where: { $0.hasPendingPersistence }) else { self.error = self.t("saveFailed"); return }
            self.installLibrary(url, remember: remember, create: create)
        }
    }
    private func installLibrary(_ url: URL, remember: Bool, create: Bool) {
        do {
            let next = try LibraryStore(rootURL: url, createIfMissing: create)
            probe.stopImmediately(reason: "configuration-change"); audio.stopPlayback()
            clouds.removeAll(); library = next; selectedID = nil; activeClassID = nil
            drafts.removeAll(); classRecords.removeAll(); transcriptRows.removeAll(); recordingsByClass.removeAll(); gapsByClass.removeAll(); classNoteIDs.removeAll(); transcriptFocusIDs.removeAll(); exportedURL = nil
            try reload(); configureAssistant(); recoverStagedRecordings(); usageRevision += 1
            if remember && !isTestMode { UserDefaults.standard.set(url.path, forKey: "libraryPath") }
            if !next.recoveryWarnings.isEmpty { notice = next.recoveryWarnings.joined(separator: "\n") }
        } catch { report(error) }
    }
    func openItem(_ item: WorkspaceItem) {
        selectedID = item.id; route = "workspace"
        documentSelection = nil
        Task { await assistant?.selectContext(itemID: item.id, classroomID: item.kind == .classroom ? item.id : item.classroomID) }
        if let classID = item.kind == .classroom ? item.id : item.classroomID {
            ensureCloud(classID)
            do {
                transcriptRows[classID] = try library?.transcripts(classroomID: classID) ?? []
                recordingsByClass[classID] = try library?.recordings(classroomID: classID) ?? []
                gapsByClass[classID] = try library?.records(collection: "gaps", ownerID: classID, as: TimelineGap.self) ?? []
            } catch { report(error) }
            if item.kind == .pdf { pdfSelection[classID] = item.id; preferences.panel = "pdf" }
            if item.kind == .note { classNoteIDs[classID] = item.id; preferences.panel = "notes" }
        }
        if item.kind == .note { loadDraft(item.id) }
    }
    func suitableParent(for kind: WorkspaceKind) -> String? {
        if kind == .course { return nil }
        guard let selected else { return nil }
        if [.classroom, .folder].contains(kind), let classID = selected.kind == .classroom ? selected.id : selected.classroomID { return items.first { $0.id == classID }?.parentID }
        if [.course, .folder, .classroom].contains(selected.kind) { return selected.id }
        return selected.parentID
    }
    func create(_ kind: WorkspaceKind, title: String, parentID: String? = nil) {
        if let workspaceCatalog {
            guard !busy else { return }
            if kind == .course { createCourse(title: title); return }
            guard let parent = parentID ?? selected?.courseID else { notice = t("chooseProjectFirst"); return }
            let noteTitle = title + " " + t("notes") + " " + String(UUID().uuidString.prefix(6))
            busy = true
            Task {
                defer { busy = false }
                do {
                    let result = try await Task.detached { () -> (WorkspaceItem, String?) in
                        let note = kind == .classroom ? try workspaceCatalog.create(kind: .note, title: noteTitle, parentID: parent) : nil
                        let item = try workspaceCatalog.create(kind: kind, title: title, parentID: parent)
                        if let note { try workspaceCatalog.link(documentID: note.id, sessionID: item.id) }
                        return (item, note?.id)
                    }.value
                    if let noteID = result.1 { classNoteIDs[result.0.id] = noteID }
                    try reload(); openItem(result.0)
                } catch { report(error); try? reload() }
            }
            return
        }
        guard let library else { openDefaultWorkspace(); return }
        do {
            let item = try library.withTransaction {
                let item = try library.createItem(kind: kind, title: title, parentID: kind == .course ? nil : parentID)
                if kind == .classroom {
                    _ = try library.createItem(kind: .note, title: t("notes"), parentID: item.id)
                    if var record = try library.classroom(id: item.id) {
                        record.inputDeviceID = audio.configuration.deviceID.map(String.init)
                        try library.saveClassroom(record)
                    }
                }
                return item
            }
            try reload(); openItem(item)
        } catch { report(error) }
    }
    func rename(_ item: WorkspaceItem, title: String) {
        if let workspaceCatalog { performProjectChange { try workspaceCatalog.rename(id: item.id, title: title) }; return }
        do { try library?.rename(id: item.id, title: title); try reload() } catch { report(error) }
    }
    func move(_ item: WorkspaceItem, to parentID: String?) {
        if let workspaceCatalog {
            guard let parentID else { error = t("chooseProjectFirst"); return }
            performProjectChange { try workspaceCatalog.move(id: item.id, parentID: parentID) }; return
        }
        do { try library?.move(id: item.id, parentID: parentID); try reload() } catch { report(error) }
    }
    func remove(_ item: WorkspaceItem) {
        guard let library, !busy else { return }
        let affected = Set(([item] + library.descendantsOf(item.id, in: items)).map(\.id))
        let sessionIDs = Set(items.filter { $0.kind == .classroom && (affected.contains($0.id) || item.kind == .course && $0.courseID == item.id) }.map(\.id))
        if item.kind == .course {
            if let id = audio.sessionID, sessionIDs.contains(id), [.starting, .capturing].contains(audio.phase) || audio.draining { error = t("pauseBeforeRemove"); return }
            if let interpretation, let id = interpretation.selected?.id, sessionIDs.contains(id), interpretation.hasActiveCapture { error = t("pauseBeforeRemove"); return }
        } else {
            for id in sessionIDs {
                if let record = try? library.classroom(id: id), ["capturing", "paused", "interrupted", "preparing"].contains(record.state) { error = t("endBeforeDelete"); return }
            }
        }
        guard !hasUnsavedFacts, interpretation?.hasUnsavedContent != true else { error = t("saveFailed"); return }
        busy = true
        Task {
            defer { busy = false }
            guard await DocumentEditingSessions.flushAll(), flushDrafts() else { error = t("saveFailed"); return }
            for id in sessionIDs { clouds[id]?.stopSpeech() }
            let catalog = workspaceCatalog
            do {
                try await Task.detached { if let catalog { try catalog.trash(id: item.id) } else { _ = try library.softDelete(id: item.id) } }.value
                lastDeletedID = item.kind == .course ? nil : item.id
                try reload()
                if affected.contains(selectedID ?? "") { selectedID = nil }
            } catch { report(error); try? reload() }
        }
    }
    func restore(_ itemID: String) {
        if let workspaceCatalog { performProjectChange { try workspaceCatalog.restore(id: itemID) }; lastDeletedID = nil; return }
        do { try library?.restore(id: itemID); try reload(); lastDeletedID = nil } catch { report(error) }
    }
    func importPDF(parentID: String?) {
        guard library != nil else { openDefaultWorkspace(); return }
        let panel = NSOpenPanel(); panel.allowedContentTypes = workspaceCatalog == nil ? [.pdf] : [UTType.pdf, .plainText, UTType(filenameExtension: "md") ?? .text, UTType(filenameExtension: "ppt") ?? .data, UTType(filenameExtension: "pptx") ?? .data, UTType(filenameExtension: "ulnote") ?? .package]; panel.allowsMultipleSelection = true
        panel.canChooseDirectories = workspaceCatalog != nil
        panel.prompt = t("importPDF")
        if panel.runModal() == .OK { importURLs(panel.urls, parentID: parentID) }
    }
    func importURLs(_ urls: [URL], parentID: String?, relativeTo: String? = nil, after: Bool = false) {
        guard let library, !busy else { return }
        if let workspaceCatalog {
            guard let parentID else { error = t("chooseProjectFirst"); return }
            performProjectChange {
                var anchor = relativeTo
                for url in urls {
                    let item = try workspaceCatalog.importDocument(from: url, parentID: parentID)
                    if let anchor { try workspaceCatalog.reorder(id: item.id, relativeTo: anchor, after: after) }
                    if after { anchor = item.id }
                }
            }; return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                let imported = try await Task.detached { try urls.map { try library.importPDF(from: $0, parentID: parentID) } }.value
                try reload(); if let item = imported.last { openItem(item) }
            } catch { report(error); try? reload() }
        }
    }
    func loadDraft(_ id: String) {
        guard drafts[id] == nil else { return }
        do { drafts[id] = try library?.noteRevision(noteID: id)?.markdown ?? ""; saveStates[id] = "saved" } catch { report(error) }
    }
    func editNote(_ id: String, value: String) {
        drafts[id] = value; saveStates[id] = "saving"; saveTasks[id]?.cancel()
        saveTasks[id] = Task { try? await Task.sleep(nanoseconds: 450_000_000); guard !Task.isCancelled else { return }; _ = saveDraft(id) }
    }
    @discardableResult func saveDraft(_ id: String) -> Bool {
        saveTasks[id]?.cancel(); saveTasks[id] = nil
        guard let library, let value = drafts[id] else { return true }
        do { _ = try library.saveNote(noteID: id, markdown: value); saveStates[id] = "saved"; return true }
        catch { saveStates[id] = "saveFailed"; storageFailed(error); return false }
    }
    @discardableResult func flushDrafts() -> Bool {
        var success = true
        for id in Array(drafts.keys) where saveStates[id] != "saved" { if !saveDraft(id) { success = false } }
        return success
    }
    func storageFailed(_ failure: Error) {
        report(failure)
        clouds.values.forEach { $0.stopSpeech() }
        if [.capturing, .starting].contains(audio.phase) { audio.stopImmediately(reason: "storage-failure") }
    }
    var hasUnsavedContent: Bool { pendingSessionOperations > 0 || !pendingClassRecords.isEmpty || !pendingTranscripts.isEmpty || !pendingRecordings.isEmpty || !pendingGaps.isEmpty || clouds.values.contains { $0.hasPendingPersistence } }
    var hasUnsavedFacts: Bool { hasUnsavedContent || !pendingEndIDs.isEmpty }
    func prepareForExit() async -> Bool {
        guard await DocumentEditingSessions.flushAll() else { error = t("saveFailed"); return false }
        guard await textTranslation.prepareForExit(), await documentTranslation.prepareForExit() else { error = t("saveFailed"); return false }
        if let assistant, !(await assistant.prepareForExit()) { error = t("saveFailed"); return false }
        if let interpretation, !(await interpretation.prepareForExit()) { error = t("saveFailed"); return false }
        await probe.pause(reason: "application-closed")
        audio.stopPlayback(); clouds.values.forEach { $0.stopSpeech() }
        await audio.pause(reason: "application-closed")
        await drainSessionWork()
        guard flushDrafts() else { error = t("saveFailed"); return false }
        for cloud in clouds.values { await cloud.shutdown() }
        guard !hasUnsavedFacts else { error = t("saveFailed"); return false }
        workspaceRefreshTask?.cancel()
        workspaceDirectoryObserver.stop()
        guard await models.unload() else { error = t("saveFailed"); return false }
        return true
    }
    func export(_ item: WorkspaceItem, backup: Bool) {
        guard let library, flushDrafts(), !busy else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = item.title + (backup ? (workspaceCatalog == nil ? ".uwaybackup" : ".ulbackup") : "-export")
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                guard await DocumentEditingSessions.flushAll(), flushDrafts(), !hasUnsavedFacts, assistant?.unsaved != true else { error = t("saveFailed"); return }
                let catalog = workspaceCatalog
                try await Task.detached {
                    if backup, let catalog { try WorkspaceArchive(catalog: catalog).backup(itemID: item.id, to: url) }
                    else if backup { try library.backup(itemID: item.id, to: url) }
                    else { try library.exportReadable(itemID: item.id, to: url) }
                }.value
                exportedURL = url; notice = t("exportDone") + "\n" + url.path
            } catch { report(error) }
        }
    }
    func restoreBackup() {
        guard let library, !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = t("restoreBackup")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let destination: URL?
        if workspaceCatalog != nil {
            let target = NSOpenPanel(); target.canChooseDirectories = true; target.canChooseFiles = false; target.canCreateDirectories = true; target.prompt = t("restoreLocation")
            guard target.runModal() == .OK, let root = target.url else { return }; destination = root
        } else { destination = nil }
        busy = true
        Task {
            defer { busy = false }
            guard await DocumentEditingSessions.flushAll(), flushDrafts(), !hasUnsavedFacts else { error = t("saveFailed"); return }
            do {
                let catalog = workspaceCatalog
                let restored = try await Task.detached { () throws -> [WorkspaceItem] in
                    let bytes = try Data(contentsOf: url.appendingPathComponent("manifest.json"))
                    let format = (try JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["format"] as? String
                    if format == "ulecture-portable-workspace", let catalog, let destination { return try WorkspaceArchive(catalog: catalog).restore(from: url, into: destination) }
                    if let catalog, let destination { return try LegacyArchiveRestore(catalog: catalog).restore(from: url, into: destination) }
                    return try library.restoreBackup(from: url)
                }.value
                try reload(); if let item = restored.first { openItem(item) }
                notice = t("saved"); exportedURL = destination
            } catch { report(error); try? reload() }
        }
    }
}

extension WorkspaceKind {
    var symbol: String {
        switch self { case .course: return "books.vertical"; case .folder: return "folder"; case .classroom: return "waveform"; case .pdf: return "doc.richtext"; case .note: return "square.and.pencil" }
    }
}
