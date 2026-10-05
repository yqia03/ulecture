import AppKit
import Combine
import Foundation

/// Exercises the actual AppModel publishers without opening a window, making
/// network requests, recording audio, or accessing the user's workspace.
@main @MainActor enum WorkspaceRefreshChecks {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task {
            do { try await run(); exit(0) }
            catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
        }
        NSApplication.shared.run()
    }

    static func run() async throws {
        guard CommandLine.arguments.contains("--ui-test-workspace"), CommandLine.arguments.contains("--model-cache") else {
            throw LibraryError.message("Isolated workspace and model cache are required")
        }
        let index = CommandLine.arguments.firstIndex(of: "--ui-test-workspace")!
        let root = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        let course = try fixture(root)
        let model = AppModel()
        model.workspaceRefreshTask?.cancel(); model.workspaceRefreshTask = nil
        await model.projectRefreshTask?.value
        model.workspaceDirectoryObserver.stop()
        guard model.isTestMode, model.workspaceCatalog != nil else { throw LibraryError.message("Test workspace did not open") }
        var publications = 0, playbackPublications = 0, busyTransitions = [Bool]()
        let snapshots = [
            model.$items.dropFirst().sink { _ in publications += 1 },
            model.$classRecords.dropFirst().sink { _ in publications += 1 },
            model.$projectMounts.dropFirst().sink { _ in publications += 1 },
            model.$missingDocumentIDs.dropFirst().sink { _ in publications += 1 },
            model.$unavailableProjectIDs.dropFirst().sink { _ in publications += 1 }
        ]
        let idleControllers: [AudioCaptureSession] = [model.audio, model.probe, model.interpretation!.audio, model.interpretation!.online.capture]
        let idleAudio = idleControllers.map {
            $0.$playbackPosition.dropFirst().sink { _ in playbackPublications += 1 }
        }
        let busy = model.$busy.dropFirst().sink { busyTransitions.append($0) }
        var failures = [String]()
        // The ordinary idle health timer must not redraw the whole application.
        // Initial device enumeration and network discovery may legitimately
        // finish asynchronously, so observe the playback seam specifically.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        if playbackPublications != 0 { failures.append("Idle audio timers published \(playbackPublications) unnecessary changes") }
        for route in ["settings", "setup"] {
            model.route = route; publications = 0; busyTransitions = []
            let scan = model.refreshProjects(reportErrors: false, showProgress: false)
            if model.busy { failures.append("Background folder scan inserts the global busy indicator on \(route)") }
            await scan?.value
            model.workspaceDirectoryObserver.stop()
            if !busyTransitions.isEmpty { failures.append("Background folder scan changed global busy state on \(route): \(busyTransitions)") }
            if publications != 0 { failures.append("Unchanged workspace scan on \(route) published \(publications) unnecessary changes") }
        }
        let external = course.appendingPathComponent("External.txt")
        try Data("Externally created file".utf8).write(to: external)
        publications = 0; busyTransitions = []
        await model.refreshProjects(reportErrors: false, showProgress: false)?.value
        if model.items.contains(where: { $0.title == "External" }) || publications != 0 || !busyTransitions.isEmpty {
            failures.append("Background scans must not load files placed directly in a course folder")
        }
        let importedSource = root.appendingPathComponent("Imported.txt")
        try Data("Explicitly imported source".utf8).write(to: importedSource)
        let catalog = model.workspaceCatalog!
        guard let project = model.items.first(where: { $0.kind == .course }) else { throw LibraryError.message("Missing fixture course") }
        let added = try catalog.importDocument(from: importedSource, parentID: project.id)
        publications = 0; busyTransitions = []
        await model.refreshProjects(reportErrors: false, showProgress: false)?.value
        if !model.items.contains(where: { $0.id == added.id }) || publications == 0 || !busyTransitions.isEmpty {
            failures.append("Explicitly imported documents must publish content without global progress")
        }
        try FileManager.default.removeItem(at: catalog.documentURL(id: added.id))
        await model.refreshProjects(reportErrors: false, showProgress: false)?.value
        if !model.missingDocumentIDs.contains(added.id) { failures.append("Background scan missed an externally removed file") }
        publications = 0
        await model.refreshProjects(reportErrors: false, showProgress: false)?.value
        if publications != 0 { failures.append("Repeated missing-file scan republished unchanged state") }
        busyTransitions = []
        let explicitRefresh = model.refreshProjects()
        if !model.busy { failures.append("Explicit folder refresh lost its foreground progress") }
        await explicitRefresh?.value
        if busyTransitions != [true, false] { failures.append("Explicit folder refresh must finish foreground progress") }
        model.workspaceDirectoryObserver.stop()
        withExtendedLifetime(snapshots + idleAudio + [busy]) {}
        guard failures.isEmpty else { throw LibraryError.message(failures.joined(separator: "\n")) }
        print("PASS: idle application, unchanged scans, unimported files ignored, explicit imports and external removals, stable missing-file state, and explicit refresh progress")
    }

    static func fixture(_ root: URL) throws -> URL {
        guard !FileManager.default.fileExists(atPath: root.path) else { throw LibraryError.message("Use a fresh isolated workspace") }
        let library = try LibraryStore(rootURL: root.appendingPathComponent("Workspace"))
        let catalog = WorkspaceCatalog(library: library)
        let project = try catalog.createCourse(title: "Course")
        let source = root.appendingPathComponent("Source.txt")
        try Data("An unchanged source".utf8).write(to: source)
        _ = try catalog.importDocument(from: source, parentID: project.id)
        _ = try catalog.create(kind: .classroom, title: "An unchanged classroom", parentID: project.id)
        return try catalog.projectRoot(project.id)
    }
}
