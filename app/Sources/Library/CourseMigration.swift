import Foundation

struct CourseMigrationEntry: Codable {
    var itemID: String
    var parentID: String
    var relativePath: String
    var format: String
    var manifest: [String: String]
    var metadataManifest: [String: String]? = nil
}
struct CourseMigrationJournal: Codable {
    var id: String
    var courseID: String
    var rootPath: String
    var stagePath: String
    var phase: String
    var entries: [CourseMigrationEntry]
}

extension WorkspaceCatalog {
    /// Copy a legacy course into the explicitly selected root. The legacy attachments remain untouched.
    func materializeLegacyCourse(courseID: String, root: URL, makeNote: ((WorkspaceItem, [NoteRevision], URL) throws -> Void)? = nil, checkpoint: ((String) throws -> Void)? = nil) throws {
        let fm = FileManager.default
        guard let course = try library.item(id: courseID), course.kind == .course else { throw LibraryError.message("课程不存在。") }
        let root = Self.canonicalURL(root)
        func validateTarget(_ target: URL, folder: Bool) throws {
            let target = Self.canonicalURL(target)
            guard !excludedRoots.contains(where: { Self.contains($0, target) }) else { throw LibraryError.message("此位置属于转写存储或应用资料；请选择其他课程文件夹。") }
            if !folder { try requireMovableTree(target) }
        }
        // Check before even creating a migration journal. Documents may be a
        // course root, but neither publication nor retry can enter its reserved trees.
        try requireProjectRoot(root)
        try validateTarget(root, folder: true)
        try WorkspaceCatalog.checkWritable(root)
        if let mounted = try mount(id: courseID) {
            guard mounted.rootPath == root.path else { throw LibraryError.message("课程已经迁移；请使用重新定位或移动功能。") }
            return
        }
        for existing in try mounts(includeUnmounted: true) {
            let other = URL(fileURLWithPath: existing.rootPath)
            guard !Self.contains(other, root), !Self.contains(root, other) else { throw LibraryError.message("不能选择已挂载课程或其上级/下级文件夹。") }
        }
        var journal: CourseMigrationJournal
        if let saved = try library.record(collection: "course-migrations", id: courseID, as: CourseMigrationJournal.self) {
            guard saved.rootPath == root.path else { throw LibraryError.message("已有未完成迁移，请继续原目标以保留恢复记录。") }
            journal = saved
        } else {
            let id = UUID().uuidString
            journal = CourseMigrationJournal(id: id, courseID: courseID, rootPath: root.path, stagePath: library.rootURL.appendingPathComponent("course-migrations/" + id).path, phase: "prepared", entries: [])
            try library.putRecord(collection: "course-migrations", id: courseID, ownerID: courseID, value: journal)
        }
        let stage = URL(fileURLWithPath: journal.stagePath)
        let metadataStage = URL(fileURLWithPath: journal.stagePath + "-metadata")
        if journal.phase == "prepared" {
            for unverified in [stage, metadataStage] where fm.fileExists(atPath: unverified.path) {
                try fm.moveItem(at: unverified, to: URL(fileURLWithPath: unverified.path + "-interrupted-" + UUID().uuidString))
            }
        }
        try fm.createDirectory(at: stage, withIntermediateDirectories: true)
        let all = try library.items(includeDeleted: true)
        let scope = library.descendantsOf(courseID, in: all).filter { $0.deletedAt == nil }
        var paths = [courseID: ""]
        var physicalParents = [courseID: courseID]
        if journal.phase == "prepared" {
            var pending = scope
            var entries: [CourseMigrationEntry] = []
            var usedPaths = Set<String>()
            while !pending.isEmpty {
                let ready = pending.filter { paths[$0.parentID ?? courseID] != nil }
                guard !ready.isEmpty else { throw LibraryError.message("课程包含无法定位的父级。") }
                for item in ready {
                    let parent = item.parentID ?? courseID
                    let parentPath = paths[parent]!
                    if item.kind == .classroom {
                        paths[item.id] = parentPath; physicalParents[item.id] = physicalParents[parent] ?? parent
                        continue
                    }
                    let format: String
                    switch item.kind {
                    case .folder: format = "folder"
                    case .pdf: format = "pdf"
                    case .note: format = makeNote == nil ? "md" : "ulnote"
                    default: continue
                    }
                    let name = (try? Self.validName(item.title)) ?? (item.kind.rawValue + "-" + String(item.id.prefix(8)))
                    var leaf = name + (format == "folder" ? "" : "." + format)
                    var path = parentPath.isEmpty ? leaf : parentPath + "/" + leaf
                    if usedPaths.contains(path.lowercased()) {
                        leaf = name + "-" + String(item.id.prefix(8)) + (format == "folder" ? "" : "." + format)
                        path = parentPath.isEmpty ? leaf : parentPath + "/" + leaf
                    }
                    usedPaths.insert(path.lowercased()); paths[item.id] = path; physicalParents[item.id] = item.id
                    try validateTarget(LibraryStore.safeChild(path, under: root), folder: format == "folder")
                    let output = try LibraryStore.safeChild(path, under: stage)
                    try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if format == "folder" { try fm.createDirectory(at: output, withIntermediateDirectories: true) }
                    else if !fm.fileExists(atPath: output.path) {
                        if item.kind == .pdf, let asset = item.assetID { try fm.copyItem(at: library.attachmentURL(assetID: asset), to: output) }
                        else if item.kind == .note {
                            let revisions = try library.records(collection: "note-revisions", ownerID: item.id, as: NoteRevision.self).sorted { $0.version < $1.version }
                            if let makeNote { try makeNote(item, revisions, output) }
                            else { try Data((revisions.last?.markdown ?? "").utf8).write(to: output, options: .atomic) }
                        }
                    }
                    try checkpoint?("stage-output")
                    let metadata = library.rootURL.appendingPathComponent("document-data/" + item.id)
                    var metadataManifest: [String: String]?
                    if fm.fileExists(atPath: metadata.path) {
                        metadataManifest = try Self.manifest(metadata)
                        try VerifiedMigrationCopy.copy(metadata, to: metadataStage.appendingPathComponent(item.id), expected: metadataManifest)
                    }
                    let parentID = physicalParents[parent] ?? parent
                    entries.append(CourseMigrationEntry(itemID: item.id, parentID: parentID, relativePath: path, format: format, manifest: format == "folder" ? [:] : try Self.manifest(output), metadataManifest: metadataManifest))
                }
                let ids = Set(ready.map(\.id)); pending.removeAll { ids.contains($0.id) }
            }
            journal.entries = entries; journal.phase = "verified"
            try library.putRecord(collection: "course-migrations", id: courseID, ownerID: courseID, value: journal)
        }
        // Validate the complete destination set before publishing any member;
        // this also covers verified journals created by an earlier build.
        for entry in journal.entries {
            try validateTarget(LibraryStore.safeChild(entry.relativePath, under: root), folder: entry.format == "folder")
            try validateTarget(LibraryStore.safeChild(".ulecture/documents/" + entry.itemID, under: root), folder: false)
        }
        // A target collision never overwrites a pre-existing file. Verified retry copies are accepted.
        for entry in journal.entries {
            let target = try LibraryStore.safeChild(entry.relativePath, under: root)
            if entry.format == "folder" {
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: target.path, isDirectory: &isDirectory), !isDirectory.boolValue { throw LibraryError.message("目标同名文件占用了文件夹位置，原件未覆盖。") }
                try fm.createDirectory(at: target, withIntermediateDirectories: true)
                continue
            }
            let source = try LibraryStore.safeChild(entry.relativePath, under: stage)
            guard try Self.manifest(source) == entry.manifest else { throw LibraryError.message("迁移暂存副本有变化，尚未提交。") }
            try VerifiedMigrationCopy.copy(source, to: target, expected: entry.manifest)
            try checkpoint?("file-published")
        }
        for entry in journal.entries {
            if let hashes = entry.metadataManifest {
                try VerifiedMigrationCopy.copy(metadataStage.appendingPathComponent(entry.itemID), to: LibraryStore.safeChild(".ulecture/documents/" + entry.itemID, under: root), expected: hashes)
            } else {
                // Older journals did not snapshot metadata; still publish a complete verified copy.
                let source = library.rootURL.appendingPathComponent("document-data/" + entry.itemID)
                if fm.fileExists(atPath: source.path) { try VerifiedMigrationCopy.copy(source, to: LibraryStore.safeChild(".ulecture/documents/" + entry.itemID, under: root)) }
            }
        }
        try library.syncDirectory(root)
        try library.withTransaction {
            let bookmark = try? root.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
            try library.putRecord(collection: "project-mounts", id: courseID, ownerID: courseID, value: ProjectMount(id: courseID, rootPath: root.path, bookmark: bookmark))
            for entry in journal.entries {
                guard var item = try library.item(id: entry.itemID) else { throw LibraryError.message("迁移条目缺失。") }
                let target = try LibraryStore.safeChild(entry.relativePath, under: root)
                item.parentID = entry.parentID; item.courseID = courseID
                try library.writeItem(item)
                if let session = item.classroomID { try link(documentID: item.id, sessionID: session) }
                let locator = DocumentLocator(id: item.id, projectID: courseID, relativePath: entry.relativePath, format: entry.format, fileIdentity: try Self.fileIdentity(target), contentHash: entry.format == "folder" ? nil : try Self.contentHash(target))
                try library.putRecord(collection: "document-locators", id: item.id, ownerID: item.id, value: locator)
            }
            journal.phase = "committed"
            try library.putRecord(collection: "course-migrations", id: courseID, ownerID: courseID, value: journal)
        }
    }
}
