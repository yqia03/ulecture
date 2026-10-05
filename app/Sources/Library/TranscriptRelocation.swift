import Foundation

private struct TranscriptRelocationJournal: Codable {
    var id = UUID().uuidString
    var source: String
    var phase = "prepared"
    var versions: [String: [String]] = [:]
    var targets: [String: [String: String]] = [:]
}
struct TranscriptRootLocation: Codable { var rootPath: String; var taskID: String; var savedAt = Date() }

/// A copied tree is never the selected root until all snapshots and recordings verify and the
/// catalog's durable pointer is atomically published. Old roots and failed generations are kept.
final class TranscriptRelocation {
    let library: LibraryStore
    let current: TranscriptStore
    init(library: LibraryStore, current: TranscriptStore) { self.library = library; self.current = current }
    private func versions() throws -> [String: [String]] {
        var result = [String: [String]]()
        for item in try library.items(includeDeleted: true) where item.kind == .classroom {
            result[item.id] = try library.databaseRows("SELECT collection,id,json FROM records WHERE owner_id=? AND collection NOT IN ('filesystem-journals','session-document-links','transcript-recovery')", [item.id]).map { $0["collection"]! + ":" + $0["id"]! + ":" + $0["json"]! }.sorted()
        }
        return result
    }
    func move(to requestedRoot: URL, checkpoint: ((String) throws -> Void)? = nil) throws -> TranscriptStore {
        let fm = FileManager.default, newRoot = WorkspaceCatalog.canonicalURL(requestedRoot)
        if current.rootURL.path == newRoot.path { return current }
        guard !WorkspaceCatalog.contains(current.rootURL, newRoot), !WorkspaceCatalog.contains(newRoot, current.rootURL),
              !WorkspaceCatalog.contains(library.rootURL, newRoot), !WorkspaceCatalog.contains(newRoot, library.rootURL) else { throw LibraryError.message("转写位置不能与原位置或应用资料目录嵌套。") }
        for mount in try library.records(collection: "project-mounts", as: ProjectMount.self) {
            let root = URL(fileURLWithPath: mount.rootPath)
            guard !WorkspaceCatalog.contains(root, newRoot), !WorkspaceCatalog.contains(newRoot, root) else { throw LibraryError.message("转写位置必须独立于课程资料文件夹。") }
        }
        try WorkspaceCatalog.checkWritable(newRoot)
        let journalURL = newRoot.appendingPathComponent(".ulecture-relocation.json")
        var journal: TranscriptRelocationJournal
        if fm.fileExists(atPath: journalURL.path) {
            journal = try JSONDecoder().decode(TranscriptRelocationJournal.self, from: Data(contentsOf: journalURL))
            guard UUID(uuidString: journal.id) != nil else { throw LibraryError.message("转写迁移任务标识无效。") }
            guard WorkspaceCatalog.canonicalURL(URL(fileURLWithPath: journal.source)).path == WorkspaceCatalog.canonicalURL(current.rootURL).path else { throw LibraryError.message("目标包含其他转写迁移任务，未覆盖：" + journal.source + " → " + current.rootURL.path) }
        } else {
            guard try fm.contentsOfDirectory(at: newRoot, includingPropertiesForKeys: nil).isEmpty else { throw LibraryError.message("请选择空文件夹；未覆盖已有内容。") }
            journal = TranscriptRelocationJournal(source: current.rootURL.path)
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            try library.syncDirectory(newRoot)
        }
        func stash(_ original: URL, generation: String) throws {
            guard fm.fileExists(atPath: original.path) else { return }
            let recovery = newRoot.appendingPathComponent(".ulecture-relocation-recovery/" + generation)
            try fm.createDirectory(at: recovery, withIntermediateDirectories: true)
            let name = original.lastPathComponent + "-" + UUID().uuidString
            try fm.moveItem(at: original, to: recovery.appendingPathComponent(name))
        }
        if journal.phase == "verified", journal.versions != (try versions()) {
            // Source changed since interruption: retain the previously verified generation, then take
            // a new snapshot. Any user edit in its published tree stops recovery instead of being replaced.
            for (name, hashes) in journal.targets {
                let target = try LibraryStore.safeChild(name, under: newRoot)
                if fm.fileExists(atPath: target.path) {
                    guard try WorkspaceCatalog.manifest(target) == hashes else { throw LibraryError.message("迁移目标已有后续编辑，未覆盖；请选择新的转写位置。") }
                    try stash(target, generation: journal.id)
                }
            }
            try stash(newRoot.appendingPathComponent(".ulecture-relocate-" + journal.id), generation: journal.id)
            journal = TranscriptRelocationJournal(source: current.rootURL.path)
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        }
        let stage = newRoot.appendingPathComponent(".ulecture-relocate-" + journal.id)
        if journal.phase == "prepared" {
            try stash(stage, generation: journal.id)
            try fm.createDirectory(at: stage, withIntermediateDirectories: false)
            let sessions = try library.withReadSnapshot { () throws -> [WorkspaceItem] in
                let sessions = try library.items(includeDeleted: true).filter { $0.kind == .classroom }
                journal.versions = try versions()
                for session in sessions {
                    let source = try current.directory(for: session)
                    let path = try WorkspaceCatalog.relativePath(source, under: current.rootURL)
                    let target = try LibraryStore.safeChild(path, under: stage)
                    try fm.createDirectory(at: target, withIntermediateDirectories: true)
                    try current.snapshot(session: session, to: target.appendingPathComponent("session.sqlite"), textFileURL: target.appendingPathComponent("transcript.txt"))
                }
                return sessions
            }
            for session in sessions {
                let source = try current.directory(for: session)
                let path = try WorkspaceCatalog.relativePath(source, under: current.rootURL)
                let target = try LibraryStore.safeChild(path, under: stage)
                for name in ["recordings", "recording-staging", "text-recovery"] {
                    let resources = source.appendingPathComponent(name)
                    if fm.fileExists(atPath: resources.path) {
                        let hashes = try WorkspaceCatalog.manifest(resources)
                        try fm.copyItem(at: resources, to: target.appendingPathComponent(name))
                        guard try WorkspaceCatalog.manifest(resources) == hashes, try WorkspaceCatalog.manifest(target.appendingPathComponent(name)) == hashes else { throw LibraryError.message("移动转写时录音有变化，原位置仍有效。") }
                    }
                }
            }
            journal.targets = [:]
            for child in try fm.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil) { journal.targets[child.lastPathComponent] = try WorkspaceCatalog.manifest(child) }
            journal.phase = "verified"
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            try library.syncDirectory(newRoot)
        }
        try checkpoint?("verified")
        try library.withReadSnapshot {
            guard journal.versions == (try versions()) else { throw LibraryError.message("移动期间会话有新保存，请重试；原位置保持有效。") }
            for (name, hashes) in journal.targets {
                let target = try LibraryStore.safeChild(name, under: newRoot)
                if fm.fileExists(atPath: target.path) {
                    guard try WorkspaceCatalog.manifest(target) == hashes else { throw LibraryError.message("迁移目标已经变化，未覆盖。") }
                } else {
                    let from = try LibraryStore.safeChild(name, under: stage)
                    guard try WorkspaceCatalog.manifest(from) == hashes else { throw LibraryError.message("迁移暂存校验失败，原位置保持有效。") }
                    try fm.moveItem(at: from, to: target)
                }
            }
            try library.syncDirectory(newRoot)
            try checkpoint?("published")
            let pointer = TranscriptRootLocation(rootPath: newRoot.path, taskID: journal.id)
            try JSONEncoder().encode(pointer).write(to: library.rootURL.appendingPathComponent("transcript-location.json"), options: .atomic)
            try library.syncDirectory(library.rootURL)
        }
        journal.phase = "completed"
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        return try TranscriptStore(rootURL: newRoot, catalogLibraryID: library.libraryID)
    }
}
