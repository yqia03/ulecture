import SwiftUI
import AppKit

struct ProjectSettingsView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(model.items.filter { $0.kind == .course && $0.deletedAt == nil }) { course in
                VStack(alignment: .leading, spacing: 6) {
                    Text(course.title).font(.headline)
                    if let mount = model.projectMounts.first(where: { $0.id == course.id }) {
                        Text(mount.rootPath).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                        HStack {
                            Button(model.t("openFolder")) { NSWorkspace.shared.open(URL(fileURLWithPath: mount.rootPath)) }
                            Button(model.t("locateProject")) { model.relocateProject(course) }
                            if !mount.mounted { Button(model.t("restore")) { model.restoreCourse(course) } }
                        }
                    } else { Button(model.t("migrateCourseFolder")) { model.migrateCourseFolder(course) } }
                }.padding(.vertical, 4)
            }
            Divider()
            Text(model.t("transcriptLocation")).font(.headline)
            Text(model.library?.transcriptStore?.rootURL.path ?? model.t("transcriptStorageUnavailable")).font(.caption).textSelection(.enabled)
            HStack {
                Button(model.t("openFolder")) { if let url = model.library?.transcriptStore?.rootURL { NSWorkspace.shared.open(url) } }
                Button(model.t("changeTranscriptLocation")) { model.changeTranscriptLocation() }
            }
            Divider()
            Text(model.t("migrateLegacyHelp")).font(.callout).foregroundStyle(.secondary)
            if let url = model.legacyLibraryURL { Text(url.path).font(.caption).textSelection(.enabled) }
            Button(model.t("migrateLegacy")) { model.importLegacyLibrary() }
            Button(model.t("legacyPreflight")) { model.preflightLegacyLibrary() }
            Text(model.t("legacyPreflightHelp")).font(.caption).foregroundStyle(.secondary)
        }.disabled(model.busy).frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor extension AppModel {
    func relocateProject(_ course: WorkspaceItem) {
        guard let workspaceCatalog else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = t("locateProject")
        guard panel.runModal() == .OK, let root = panel.url else { return }
        performProjectChange { try workspaceCatalog.relocate(projectID: course.id, root: root) }
    }
    func restoreCourse(_ course: WorkspaceItem) {
        guard let workspaceCatalog else { return }
        performProjectChange { try workspaceCatalog.restoreCourse(id: course.id) }
    }
    func importLegacyLibrary() {
        guard let library, !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = t("migrateLegacy")
        if let legacyLibraryURL { panel.directoryURL = legacyLibraryURL }
        guard panel.runModal() == .OK, let source = panel.url else { return }
        let legacyTitle = t("legacyMaterials")
        performProjectChange {
            let migration = LegacyMigration(destination: library)
            let snapshot = try migration.prepare(sourceRoot: source)
            _ = try migration.install(snapshot: snapshot)
            _ = try library.organizeLegacyRoots(title: legacyTitle)
            try library.migrateLegacySessionAttachments()
        }
    }
    func preflightLegacyLibrary() {
        guard let library, !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.prompt = t("legacyPreflight")
        guard panel.runModal() == .OK, let source = panel.url else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let snapshot = try await Task.detached { try LegacyMigration(destination: library).prepare(sourceRoot: source, newGeneration: true) }.value
                exportedURL = snapshot; notice = t("legacyPreflightHelp")
            } catch { report(error) }
        }
    }
    func migrateCourseFolder(_ course: WorkspaceItem) {
        guard let workspaceCatalog else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = t("migrateCourseFolder")
        guard panel.runModal() == .OK, let root = panel.url else { return }
        performProjectChange {
            try workspaceCatalog.materializeLegacyCourse(courseID: course.id, root: root) { item, revisions, target in
                let store = BlockNoteStore(packageURL: target, noteID: item.id)
                _ = try store.importMarkdown(Data((revisions.last?.markdown ?? "").utf8), title: item.title)
                let history = try JSONEncoder().encode(revisions)
                let url = target.appendingPathComponent("legacy-revisions.json")
                if FileManager.default.fileExists(atPath: url.path) {
                    guard try Data(contentsOf: url) == history else { throw DocumentFailure.conflict }
                } else { try history.write(to: url, options: .atomic) }
            }
        }
    }
    func changeTranscriptLocation() {
        guard let library, !busy else { return }
        let panel = NSOpenPanel(); panel.canChooseFiles = false; panel.canChooseDirectories = true; panel.canCreateDirectories = true; panel.prompt = t("changeTranscriptLocation")
        guard panel.runModal() == .OK, let root = panel.url else { return }
        busy = true
        Task {
            defer { busy = false }
            await audio.pause(reason: "storage-change"); await probe.pause(reason: "storage-change")
            if let interpretation, !(await interpretation.prepareForExit()) { error = t("saveFailed"); return }
            guard audio.phase != .capturing, !audio.draining, flushDrafts(), !hasUnsavedFacts else { error = t("saveFailed"); return }
            do {
                try await Task.detached { try library.moveTranscriptStorage(to: root) }.value
                preferences.defaults.set(root.path, forKey: "transcriptRootPath")
                transcriptStorageReady = true
                workspaceCatalog?.excludedRoots = [library.rootURL, root]
                notice = t("saved")
            } catch { report(error) }
        }
    }
}
