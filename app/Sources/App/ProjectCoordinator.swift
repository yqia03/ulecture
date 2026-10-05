import Foundation
import AppKit

@MainActor extension AppModel {
    func openDefaultWorkspace() {
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            let args = CommandLine.arguments
            let isolatedRoot = args.firstIndex(of: "--ui-test-workspace").flatMap { $0 + 1 < args.count ? URL(fileURLWithPath: args[$0 + 1]) : nil }
            let root = isolatedRoot?.appendingPathComponent("Workspace") ?? support.appendingPathComponent("ULecture/Workspace", isDirectory: true)
            openLibrary(root, remember: false)
            guard let library else { return }
            let catalog = WorkspaceCatalog(library: library)
            workspaceCatalog = catalog
            configureAssistant()
            let transcriptRoot = try isolatedRoot?.appendingPathComponent("Transcripts") ?? library.savedTranscriptRoot() ?? preferences.defaults.string(forKey: "transcriptRootPath").map { URL(fileURLWithPath: $0) } ?? TranscriptStore.defaultRoot()
            catalog.excludedRoots = [root, transcriptRoot]
            do { try library.configureTranscriptStorage(rootURL: transcriptRoot); transcriptStorageReady = true }
            catch { transcriptStorageReady = false; report(error) }
            let recovered = try catalog.recoverFileOperations()
            if !recovered.isEmpty { notice = recovered.joined(separator: "\n") }
            try reload()
            interpretation = InterpretationController(library: library, models: models, settings: cloudService, defaults: preferences.defaults, interpretationSettings: interpretationService)
            interpretation?.onLibraryChange = { [weak self] in try? self?.reload() }
            interpretation?.online.onUsageChanged = { [weak self] in self?.usageRevision += 1 }
            refreshProjects()
            workspaceRefreshTask = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 4_000_000_000)
                    guard !Task.isCancelled, let self else { return }
                    if !self.busy { self.refreshProjects(reportErrors: false, showProgress: false) }
                }
            }
        } catch { report(error) }
    }

    func configureAssistant() {
        guard let library else { assistant = nil; return }
        let controller = AIAssistantController(library: library, catalog: workspaceCatalog, settings: cloudService)
        controller.onLibraryChange = { [weak self] in try? self?.reload() }
        controller.onOpenReference = { [weak self] source in self?.openAssistantReference(source) }
        assistant = controller
    }

    func openAssistantReference(_ source: AssistantSource) {
        guard let item = items.first(where: { $0.id == source.documentID && $0.deletedAt == nil }) else { notice = t("sourceUnavailable"); return }
        if let page = source.page {
            if source.kind == .annotation, let annotationID = source.annotationID {
                DocumentNavigationState.shared.requestAnnotation(documentID: item.id, sourceHash: source.sourceHash, page: page, annotationID: annotationID, revision: source.version)
            } else { DocumentNavigationState.shared.request(documentID: item.id, sourceHash: source.navigationHash ?? source.sourceHash, page: page) }
            pdfPages[item.id] = page
        }
        if source.kind == .note, let block = source.blockID { DocumentNavigationState.shared.requestBlock(documentID: item.id, blockID: block, revision: source.version) }
        openItem(item)
        if source.kind == .transcript {
            preferences.panel = "transcript"
            if let row = transcriptRows[item.id]?.first(where: { $0.startMS == source.startMS }) { transcriptFocusIDs[item.id] = row.id }
        }
    }

    func createCourse(title: String) {
        guard let workspaceCatalog, !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let item = try await Task.detached { try workspaceCatalog.createCourse(title: title) }.value
                try reload(); openItem(item)
            } catch { report(error); try? reload() }
        }
    }

    @discardableResult func refreshProjects(reportErrors: Bool = true, showProgress: Bool = true) -> Task<Void, Never>? {
        if let projectRefreshTask { return projectRefreshTask }
        guard let workspaceCatalog, !busy else { return nil }
        if workspaceCatalog.library.isReadOnly {
            do {
                try reload()
                let unavailable = Set(try workspaceCatalog.mounts().filter { !FileManager.default.isReadableFile(atPath: $0.rootPath) }.map(\.id))
                if unavailableProjectIDs != unavailable { unavailableProjectIDs = unavailable }
            } catch { if reportErrors { report(error) } }
            return nil
        }
        // Automatic FSEvent, activation and fallback scans must not insert the
        // global progress row. Keep their concurrency guard separate from UI.
        if showProgress { busy = true }
        let task = Task {
            defer { projectRefreshTask = nil; if showProgress { busy = false } }
            do {
                let failures = try await Task.detached { () -> [String: String] in
                    var failures: [String: String] = [:]
                    for project in try workspaceCatalog.mounts() {
                        do { try workspaceCatalog.scan(projectID: project.id) }
                        catch { failures[project.id] = error.localizedDescription }
                    }
                    return failures
                }.value
                // A silent scan must not apply results to a different library
                // selected while it was running.
                guard self.workspaceCatalog === workspaceCatalog, library === workspaceCatalog.library else { return }
                try reload()
                let unavailable = Set(failures.keys)
                if unavailableProjectIDs != unavailable { unavailableProjectIDs = unavailable }
                if reportErrors && !failures.isEmpty { notice = failures.values.joined(separator: "\n") }
            } catch { if reportErrors { report(error) } }
        }
        projectRefreshTask = task
        return task
    }

    func performProjectChange(_ operation: @escaping () throws -> Void) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            guard await DocumentEditingSessions.flushAll(), flushDrafts() else { error = t("saveFailed"); return }
            do { try await Task.detached { try operation() }.value; try reload() }
            catch { report(error); try? reload() }
        }
    }

    func documentURL(for item: WorkspaceItem) throws -> URL {
        if let workspaceCatalog { return try workspaceCatalog.documentURL(id: item.id) }
        guard let library, let assetID = item.assetID else { throw LibraryError.message(t("missingAttachment")) }
        return try library.attachmentURL(assetID: assetID)
    }

    func annotationDirectory(for item: WorkspaceItem) throws -> URL {
        if let workspaceCatalog { return try workspaceCatalog.metadataDirectory(documentID: item.id) }
        guard let library else { throw LibraryError.message(t("chooseProjectFirst")) }
        let directory = library.rootURL.appendingPathComponent("document-data/" + item.id, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func notePackageURL(for item: WorkspaceItem) throws -> URL {
        if let workspaceCatalog, let locator = try workspaceCatalog.locator(id: item.id), locator.format == "ulnote" {
            return try workspaceCatalog.documentURL(id: item.id)
        }
        let directory = try annotationDirectory(for: item).appendingPathComponent("note.ulnote", isDirectory: true)
        let store = BlockNoteStore(packageURL: directory, noteID: item.id)
        if !FileManager.default.fileExists(atPath: directory.appendingPathComponent("note.json").path) {
            if let revision = try library?.noteRevision(noteID: item.id) {
                _ = try store.importMarkdown(Data(revision.markdown.utf8), title: item.title)
            } else { _ = try store.create(title: item.title) }
        }
        return directory
    }

    func projectDocumentIDs(for classroomID: String) -> Set<String> {
        documentIDsByClass[classroomID] ?? []
    }
}
