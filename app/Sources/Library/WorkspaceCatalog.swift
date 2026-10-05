import Foundation
import PDFKit
import Darwin
import CryptoKit

struct ProjectMount: Codable, Identifiable, Equatable {
    var id: String
    var rootPath: String
    var bookmark: Data?
    var mounted = true
    var updatedAt = Date()
}

struct DocumentLocator: Codable, Identifiable {
    var id: String
    var projectID: String
    var relativePath: String
    var format: String
    var fileIdentity: String
    var contentHash: String?
    var byteCount: Int64?
    var modifiedAt: Date?
    var missing = false
    var updatedAt = Date()
}

struct SessionDocumentLink: Codable, Identifiable {
    var id: String { sessionID + ":" + documentID }
    var sessionID: String
    var documentID: String
}

struct WorkspaceFileJournal: Codable, Identifiable {
    var id: String = UUID().uuidString
    var itemID: String
    var operation: String
    var source: String
    var destination: String
    var sourceProjectID: String
    var destinationProjectID: String
    var destinationParentID: String?
    var destinationTitle: String
    var sourceRelativePath: String
    var destinationRelativePath: String
    var manifest: [String: String]
    var phase: String = "prepared"
    var createdAt = Date()
}

/// The catalog owns identities and display order. Project directories own document bytes.
/// The journal is committed before touching the filesystem; a row is updated only after a verified move.
final class WorkspaceCatalog {
    let library: LibraryStore
    private let lock = NSRecursiveLock()
    private let fm = FileManager.default
    static let formats: Set<String> = ["pdf", "ulnote", "md", "txt", "ppt", "pptx"]
    private var reservedRoots: [URL] = []
    var excludedRoots: [URL] {
        get { reservedRoots }
        set { reservedRoots = newValue.map(Self.canonicalURL) }
    }

    init(library: LibraryStore) { self.library = library }
    private func serialized<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }

    func mounts(includeUnmounted: Bool = false) throws -> [ProjectMount] {
        try library.records(collection: "project-mounts", as: ProjectMount.self).filter { includeUnmounted || $0.mounted }
    }
    func mount(id: String) throws -> ProjectMount? { try library.record(collection: "project-mounts", id: id, as: ProjectMount.self) }
    func locator(id: String) throws -> DocumentLocator? { try library.record(collection: "document-locators", id: id, as: DocumentLocator.self) }

    /// New courses start empty in app-managed storage. Existing folders are never adopted.
    @discardableResult func createCourse(title: String) throws -> WorkspaceItem {
        try serialized {
            let directory = library.rootURL.deletingLastPathComponent().appendingPathComponent("Courses", isDirectory: true)
            try fm.createDirectory(at: directory, withIntermediateDirectories: true)
            let root = directory.appendingPathComponent(UUID().uuidString, isDirectory: true)
            try requireProjectRoot(root)
            for existing in try mounts(includeUnmounted: true) {
                let other = URL(fileURLWithPath: existing.rootPath)
                guard !Self.contains(other, root), !Self.contains(root, other) else { throw LibraryError.message("课程文件夹不能互相嵌套；请选择独立文件夹。") }
            }
            try fm.createDirectory(at: root, withIntermediateDirectories: false)
            do {
                return try library.withTransaction {
                    let item = try library.createItem(kind: .course, title: title)
                    let bookmark = try? root.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                    let storage = ProjectMount(id: item.id, rootPath: root.path, bookmark: bookmark)
                    try library.putRecord(collection: "project-mounts", id: item.id, ownerID: item.id, value: storage)
                    return item
                }
            } catch {
                // Only our still-empty directory can be removed after a failed registration.
                if (try? fm.contentsOfDirectory(atPath: root.path).isEmpty) == true { try? fm.removeItem(at: root) }
                throw error
            }
        }
    }

    /// Unmounting only changes visibility. It does not delete files or detach historical sources.
    func unmount(_ id: String) throws {
        guard var value = try mount(id: id) else { return }
        value.mounted = false; value.updatedAt = Date()
        try library.putRecord(collection: "project-mounts", id: id, ownerID: id, value: value)
    }

    /// Restore visibility for a course already registered in this library.
    func restoreCourse(id: String) throws {
        guard let item = try library.item(id: id), item.kind == .course,
              var value = try mount(id: id) else { throw LibraryError.message("课程不存在。") }
        value.mounted = true; value.updatedAt = Date()
        try library.putRecord(collection: "project-mounts", id: id, ownerID: id, value: value)
    }

    func projectRoot(_ id: String) throws -> URL {
        guard var value = try mount(id: id) else { throw LibraryError.message("课程尚未选择工作文件夹。") }
        var root = Self.canonicalURL(URL(fileURLWithPath: value.rootPath))
        if !fm.fileExists(atPath: root.path), let bookmark = value.bookmark {
            var stale = false
            if let resolved = try? URL(resolvingBookmarkData: bookmark, options: [.withoutUI, .withoutMounting], relativeTo: nil, bookmarkDataIsStale: &stale), fm.fileExists(atPath: resolved.path) {
                root = Self.canonicalURL(resolved)
                try requireProjectRoot(root)
                value.rootPath = root.path; value.updatedAt = Date()
                value.bookmark = try? root.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                if !library.isReadOnly { try library.putRecord(collection: "project-mounts", id: id, ownerID: id, value: value) }
            }
        }
        var directory: ObjCBool = false
        guard fm.fileExists(atPath: root.path, isDirectory: &directory), directory.boolValue else { throw LibraryError.message("课程文件夹未连接，请重新连接磁盘或定位文件夹。") }
        try requireProjectRoot(root)
        return root
    }

    func relocate(projectID: String, root: URL) throws {
        try serialized {
            guard var value = try mount(id: projectID) else { throw LibraryError.message("课程不存在。") }
            let root = Self.canonicalURL(root)
            guard (try root.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true else { throw LibraryError.message("请选择课程文件夹。") }
            try requireProjectRoot(root)
            for other in try mounts(includeUnmounted: true) where other.id != projectID {
                let otherRoot = URL(fileURLWithPath: other.rootPath)
                guard !Self.contains(otherRoot, root), !Self.contains(root, otherRoot) else { throw LibraryError.message("课程文件夹不能互相嵌套；请选择独立文件夹。") }
            }
            let locators = try library.records(collection: "document-locators", as: DocumentLocator.self).filter { $0.projectID == projectID && !$0.missing }
            // A relocated volume may have new filesystem identities. Match the explicitly selected root by verified relative content.
            for locator in locators where locator.format != "folder" {
                let candidate = try LibraryStore.safeChild(root: root, relative: locator.relativePath)
                guard fm.fileExists(atPath: candidate.path), try (locator.contentHash == nil || locator.contentHash == Self.contentHash(candidate)) else { throw LibraryError.message("所选位置与课程资料不一致，尚未重新定位。") }
            }
            value.rootPath = root.path; value.bookmark = try? root.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil); value.updatedAt = Date()
            try library.putRecord(collection: "project-mounts", id: projectID, ownerID: projectID, value: value)
            try scan(projectID: projectID)
        }
    }

    func documentURL(id: String, allowMissing: Bool = false) throws -> URL {
        guard let locator = try locator(id: id) else {
            let item = try requireItem(id)
            if let asset = item.assetID { return try library.attachmentURL(assetID: asset) }
            throw LibraryError.message("文件尚未迁移到课程工作文件夹。")
        }
        let url = try LibraryStore.safeChild(root: projectRoot(locator.projectID), relative: locator.relativePath)
        guard allowMissing || fm.fileExists(atPath: url.path) else { throw LibraryError.message("文件已在外部移动或删除，请刷新或重新定位。") }
        return url
    }

    func metadataDirectory(documentID: String) throws -> URL {
        guard let locator = try locator(id: documentID) else {
            let url = library.rootURL.appendingPathComponent("document-data").appendingPathComponent(documentID)
            try fm.createDirectory(at: url, withIntermediateDirectories: true); return url
        }
        let root = try projectRoot(locator.projectID)
        let url = try LibraryStore.safeChild(root: root, relative: ".ulecture/documents/" + documentID)
        try fm.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func scan(projectID: String) throws {
        try serialized {
            let root = try projectRoot(projectID) // A disconnected root never turns every file into a deletion.
            let allLocators = try library.records(collection: "document-locators", as: DocumentLocator.self)
            let allItems = try library.items(includeDeleted: true)
            let deleted = Set(allItems.filter { $0.deletedAt != nil }.map(\.id))
            var byIdentity: [String: DocumentLocator] = [:]
            var byPath: [String: DocumentLocator] = [:]
            // Older catalogs may contain a stale missing row at a reused path.
            // Keep a deterministic live candidate rather than trapping on duplicate keys.
            for value in allLocators.sorted(by: Self.locatorPriority) where !deleted.contains(value.id) {
                if byIdentity[value.fileIdentity] == nil { byIdentity[value.fileIdentity] = value }
                if value.projectID == projectID, byPath[value.relativePath] == nil { byPath[value.relativePath] = value }
            }
            var seen = Set<String>()
            var updated: [(WorkspaceItem, DocumentLocator)] = []
            func visit(_ directory: URL, parentID: String) throws {
                let entries = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey], options: [.skipsHiddenFiles]).sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
                for url in entries {
                    if excludedRoots.contains(where: { Self.contains($0, url) }) { continue }
                    let attrs = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey, .isRegularFileKey])
                    if attrs.isSymbolicLink == true { continue }
                    let ext = url.pathExtension.lowercased()
                    let folder = attrs.isDirectory == true && ext != "ulnote"
                    guard folder || Self.formats.contains(ext) && (attrs.isRegularFile == true || ext == "ulnote" && attrs.isDirectory == true) else { continue }
                    let relative = try Self.relativePath(url, under: root)
                    let identity = try Self.fileIdentity(url)
                    // Filesystem identity is primary. Path is a fallback only when its old identity no longer exists anywhere.
                    let identityMatch = byIdentity[identity].flatMap { old -> DocumentLocator? in
                        // A second hard link is an independent tree entry, not an external move.
                        if let oldRoot = try? projectRoot(old.projectID), let oldURL = try? LibraryStore.safeChild(root: oldRoot, relative: old.relativePath),
                           oldURL.standardizedFileURL.resolvingSymlinksInPath().path != url.standardizedFileURL.resolvingSymlinksInPath().path,
                           (try? Self.fileIdentity(oldURL)) == identity { return nil }
                        return old
                    }
                    let pathMatch = byPath[relative].flatMap { old -> DocumentLocator? in
                        if old.fileIdentity == identity { return old }
                        // A replaced file at the same path keeps document identity only if the old inode did not move within the project.
                        if let moved = try? fm.subpathsOfDirectory(atPath: root.path), moved.contains(where: { path in
                            guard !path.hasPrefix("."), let candidate = try? LibraryStore.safeChild(root: root, relative: path) else { return false }
                            return (try? Self.fileIdentity(candidate)) == old.fileIdentity
                        }) { return nil }
                        return old
                    }
                    // Refresh maintains registered documents only. Unknown files and folders require explicit import.
                    guard let existing = identityMatch ?? pathMatch, let registeredItem = allItems.first(where: { $0.id == existing.id }) else { continue }
                    let id = existing.id
                    guard seen.insert(id).inserted else { continue } // hard links are one physical document
                    let kind: WorkspaceKind = folder ? .folder : (["pdf", "ppt", "pptx"].contains(ext) ? .pdf : .note)
                    var item = registeredItem
                    item.parentID = parentID; item.courseID = projectID; item.kind = kind; item.title = folder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
                    let fileAttributes = try fm.attributesOfItem(atPath: url.path)
                    let size = (fileAttributes[.size] as? NSNumber)?.int64Value
                    let modified = fileAttributes[.modificationDate] as? Date
                    let sameFile = ext != "ulnote" && existing.fileIdentity == identity && existing.byteCount == size && existing.modifiedAt == modified
                    let hash = folder ? nil : (sameFile ? existing.contentHash : try Self.contentHash(url))
                    var loc = DocumentLocator(id: id, projectID: projectID, relativePath: relative, format: folder ? "folder" : ext, fileIdentity: identity, contentHash: hash)
                    loc.byteCount = size; loc.modifiedAt = modified
                    if existing.relativePath == relative, existing.contentHash == hash, !existing.missing { loc.updatedAt = existing.updatedAt }
                    else { item.updatedAt = Date() }
                    updated.append((item, loc))
                    if existing.projectID != projectID { try copyMetadata(items: [item], from: existing.projectID, to: projectID) }
                    if folder { try visit(url, parentID: id) }
                }
            }
            try visit(root, parentID: projectID)
            try library.withTransaction {
                for (item, locator) in updated {
                    try library.writeItem(item)
                    try library.putRecord(collection: "document-locators", id: item.id, ownerID: item.id, value: locator)
                }
                let updatedParents = Dictionary(uniqueKeysWithValues: updated.filter { $0.0.kind == .folder }.map { ($0.0.id, $0.0) })
                for var session in allItems where session.kind == .classroom {
                    if let parentID = session.parentID, let parent = updatedParents[parentID], parent.courseID != session.courseID {
                        session.parentID = session.courseID; session.updatedAt = Date(); try library.writeItem(session)
                    }
                }
                for var value in allLocators where value.projectID == projectID && !seen.contains(value.id) && !deleted.contains(value.id) {
                    value.missing = true; value.updatedAt = Date()
                    try library.putRecord(collection: "document-locators", id: value.id, ownerID: value.id, value: value)
                }
            }
        }
    }

    @discardableResult func create(kind: WorkspaceKind, title: String, parentID: String) throws -> WorkspaceItem {
        try serialized {
            let (projectID, directory) = try destination(parentID)
            let name = try Self.validName(title)
            if kind == .classroom {
                // Classrooms are logical sessions; their material links do not own physical files.
                return try library.createItem(kind: .classroom, title: name, parentID: parentID)
            }
            guard kind == .folder || kind == .note else { throw LibraryError.message("请选择文件夹或笔记。") }
            let url = directory.appendingPathComponent(name + (kind == .note && !name.hasSuffix(".ulnote") ? ".ulnote" : ""))
            try requireMovableTree(url)
            guard !fm.fileExists(atPath: url.path) else { throw LibraryError.message("目标已有同名项目，请使用其他名称。") }
            try Self.checkWritable(directory)
            try fm.createDirectory(at: url, withIntermediateDirectories: false)
            do { return try registerDocument(url, projectID: projectID, parentID: parentID) }
            catch {
                if (try? fm.contentsOfDirectory(atPath: url.path).isEmpty) == true { try? fm.removeItem(at: url) }
                throw error
            }
        }
    }

    @discardableResult func importDocument(from source: URL, parentID: String) throws -> WorkspaceItem {
        try serialized {
            let format = source.pathExtension.lowercased()
            guard Self.formats.contains(format) else { throw LibraryError.message("支持 PDF、ULecture 笔记、Markdown、TXT、PPT 和 PPTX。此文件未导入。") }
            let sourceValues = try source.resourceValues(forKeys: [.isSymbolicLinkKey, .isDirectoryKey, .isRegularFileKey])
            guard sourceValues.isSymbolicLink != true else { throw LibraryError.message("不导入符号链接。请选择原文件。") }
            guard sourceValues.isRegularFile == true || format == "ulnote" && sourceValues.isDirectory == true else { throw LibraryError.message("不支持导入整个文件夹，请选择具体资料文件。") }
            if format == "pdf" { guard let pdf = PDFDocument(url: source), !pdf.isLocked, pdf.pageCount > 0 else { throw LibraryError.message("PDF 损坏、加密或没有可读取页面。") } }
            let (projectID, directory) = try destination(parentID)
            try Self.checkWritable(directory)
            let target = directory.appendingPathComponent(try Self.validName(source.lastPathComponent))
            try requireMovableTree(target)
            guard !fm.fileExists(atPath: target.path) else { throw LibraryError.message("目标已有同名文件，请先重命名或选择其他文件夹。") }
            let stage = directory.appendingPathComponent(".ulecture-import-" + UUID().uuidString)
            let expected = try Self.manifest(source)
            var published = false
            do {
                try fm.copyItem(at: source, to: stage)
                guard try Self.manifest(stage) == expected, try Self.manifest(source) == expected else { throw LibraryError.message("复制时原文件发生变化；导入未提交。") }
                try fm.moveItem(at: stage, to: target); published = true
                try library.syncDirectory(directory)
                return try registerDocument(target, projectID: projectID, parentID: parentID)
            } catch {
                try? fm.removeItem(at: stage)
                if published, (try? Self.manifest(target)) == expected { try? fm.removeItem(at: target) }
                throw error
            }
        }
    }

    /// Register only the single file or note package produced by an explicit create/import operation.
    private func registerDocument(_ url: URL, projectID: String, parentID: String) throws -> WorkspaceItem {
        let parent = try requireItem(parentID)
        let physicalParent = parent.kind == .classroom ? (parent.parentID ?? projectID) : parentID
        let format = url.pathExtension.lowercased()
        let folder = (try url.resourceValues(forKeys: [.isDirectoryKey])).isDirectory == true && format != "ulnote"
        let kind: WorkspaceKind = folder ? .folder : (["pdf", "ppt", "pptx"].contains(format) ? .pdf : .note)
        let title = folder ? url.lastPathComponent : url.deletingPathExtension().lastPathComponent
        let root = try projectRoot(projectID)
        let relative = try Self.relativePath(url, under: root)
        let attributes = try fm.attributesOfItem(atPath: url.path)
        let identity = try Self.fileIdentity(url)
        let candidates = try library.records(collection: "document-locators", as: DocumentLocator.self)
            .filter { $0.projectID == projectID && $0.relativePath == relative }
            .sorted(by: Self.locatorPriority)
        var existingItem: WorkspaceItem?
        for candidate in candidates {
            guard let item = try library.item(id: candidate.id), item.deletedAt == nil else { continue }
            // Reimport restores a missing document's identity, but a moved original
            // keeps its own identity even before the next background refresh.
            let originalMoved = try fm.subpathsOfDirectory(atPath: root.path).contains { path in
                guard !path.hasPrefix("."), let location = try? LibraryStore.safeChild(root: root, relative: path) else { return false }
                return location != url && (try? Self.fileIdentity(location)) == candidate.fileIdentity
            }
            if !originalMoved { existingItem = item; break }
        }
        return try library.withTransaction {
            var item = existingItem ?? WorkspaceItem(id: UUID().uuidString, parentID: physicalParent, courseID: projectID, kind: kind, title: title, createdAt: Date(), updatedAt: Date())
            item.parentID = physicalParent; item.courseID = projectID; item.kind = kind; item.title = title; item.updatedAt = Date()
            try library.writeItem(item)
            var locator = DocumentLocator(id: item.id, projectID: projectID, relativePath: relative, format: folder ? "folder" : format, fileIdentity: identity, contentHash: folder ? nil : try Self.contentHash(url))
            locator.byteCount = (attributes[.size] as? NSNumber)?.int64Value
            locator.modifiedAt = attributes[.modificationDate] as? Date
            try library.putRecord(collection: "document-locators", id: item.id, ownerID: item.id, value: locator)
            if parent.kind == .classroom { try link(documentID: item.id, sessionID: parentID) }
            return item
        }
    }

    private static func locatorPriority(_ lhs: DocumentLocator, _ rhs: DocumentLocator) -> Bool {
        if lhs.missing != rhs.missing { return !lhs.missing }
        if lhs.updatedAt != rhs.updatedAt { return lhs.updatedAt > rhs.updatedAt }
        return lhs.id < rhs.id
    }

    func link(documentID: String, sessionID: String) throws {
        guard try requireItem(sessionID).kind == .classroom else { throw LibraryError.message("关联目标不是课堂。") }
        _ = try requireItem(documentID)
        let link = SessionDocumentLink(sessionID: sessionID, documentID: documentID)
        try library.putRecord(collection: "session-document-links", id: link.id, ownerID: sessionID, value: link)
    }
    func linkedDocumentIDs(sessionID: String) throws -> Set<String> {
        var ids = Set(try library.records(collection: "session-document-links", ownerID: sessionID, as: SessionDocumentLink.self).map(\.documentID))
        for item in try library.items() where item.classroomID == sessionID && item.kind != .classroom { ids.insert(item.id) }
        return ids
    }

    func reorder(id: String, relativeTo otherID: String, after: Bool) throws {
        try library.withTransaction {
            let item = try requireItem(id), other = try requireItem(otherID)
            guard item.parentID == other.parentID else { throw LibraryError.message("请先移动到相同文件夹，再调整顺序。") }
            var siblings = try library.items().filter { $0.parentID == item.parentID && $0.id != id }.sorted(by: Self.ordered)
            guard let index = siblings.firstIndex(where: { $0.id == otherID }) else { return }
            siblings.insert(item, at: index + (after ? 1 : 0))
            for (offset, var value) in siblings.enumerated() { value.sortRank = Double(offset); try library.writeItem(value) }
        }
    }
    static func ordered(_ lhs: WorkspaceItem, _ rhs: WorkspaceItem) -> Bool {
        if lhs.sortRank != rhs.sortRank { return (lhs.sortRank ?? Double.greatestFiniteMagnitude) < (rhs.sortRank ?? Double.greatestFiniteMagnitude) }
        return lhs.createdAt == rhs.createdAt ? lhs.id < rhs.id : lhs.createdAt < rhs.createdAt
    }

    func rename(id: String, title: String) throws {
        let item = try requireItem(id)
        if item.kind == .course || item.kind == .classroom { try library.rename(id: id, title: title); return }
        guard let parentID = item.parentID else { throw LibraryError.message("找不到父文件夹。") }
        try move(id: id, parentID: parentID, title: title)
    }

    func move(id: String, parentID: String, title: String? = nil) throws {
        try serialized {
            let item = try requireItem(id)
            guard item.kind != .course && item.kind != .classroom else { throw LibraryError.message("课程通过拖放排序；课堂关联保持原课程。") }
            guard let sourceLocator = try locator(id: id) else { throw LibraryError.message("此旧资料需先迁移到课程工作文件夹。") }
            let descendants = library.descendantsOf(id, in: try library.items(includeDeleted: true))
            guard id != parentID, !descendants.contains(where: { $0.id == parentID }) else { throw LibraryError.message("不能移入自身或下级文件夹。") }
            let source = try documentURL(id: id)
            try requireMovableTree(source)
            let (projectID, directory) = try destination(parentID)
            let base = try Self.validName(title ?? item.title)
            let name = sourceLocator.format == "folder" ? base : (base.hasSuffix("." + sourceLocator.format) ? base : base + "." + sourceLocator.format)
            let target = directory.appendingPathComponent(name)
            if source.standardizedFileURL == target.standardizedFileURL { return }
            try requireMovableTree(target)
            guard !fm.fileExists(atPath: target.path) else { throw LibraryError.message("目标已有同名文件；没有覆盖或移动。") }
            try Self.checkWritable(source.deletingLastPathComponent()); try Self.checkWritable(directory)
            let targetRoot = try projectRoot(projectID)
            var journal = WorkspaceFileJournal(itemID: id, operation: "move", source: source.path, destination: target.path, sourceProjectID: sourceLocator.projectID, destinationProjectID: projectID, destinationParentID: parentID, destinationTitle: title ?? item.title, sourceRelativePath: sourceLocator.relativePath, destinationRelativePath: try Self.relativePath(target, under: targetRoot), manifest: try Self.manifest(source))
            try save(journal)
            // Copy first on every volume so interruption can be reconciled with both source and destination intact.
            let stage = directory.appendingPathComponent(".ulecture-move-" + journal.id)
            try fm.copyItem(at: source, to: stage)
            guard try Self.manifest(stage) == journal.manifest, try Self.manifest(source) == journal.manifest else { throw LibraryError.message("移动期间文件已改变；保留原件与恢复副本，尚未提交。") }
            try fm.moveItem(at: stage, to: target); try library.syncDirectory(directory)
            journal.phase = "copied"; try save(journal)
            try copyMetadata(items: [item] + descendants, from: sourceLocator.projectID, to: projectID)
            try commit(journal)
            journal.phase = "committed"; try save(journal)
            try retireSource(journal)
            journal.phase = "finished"; try save(journal)
            if try requireItem(parentID).kind == .classroom { try link(documentID: id, sessionID: parentID) }
        }
    }

    /// Files move to hidden project trash. Originals are recoverable without depending on system Trash permissions.
    func trash(id: String) throws {
        try serialized {
            let item = try requireItem(id)
            if item.kind == .course { try unmount(id); return }
            if item.kind == .classroom { _ = try library.softDelete(id: id); return }
            guard let locator = try locator(id: id) else { _ = try library.softDelete(id: id); return }
            let source = try documentURL(id: id)
            try requireMovableTree(source)
            let root = try projectRoot(locator.projectID)
            let relative = ".ulecture/trash/" + UUID().uuidString + "/" + source.lastPathComponent
            let target = try LibraryStore.safeChild(root: root, relative: relative)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            var journal = WorkspaceFileJournal(itemID: id, operation: "trash", source: source.path, destination: target.path, sourceProjectID: locator.projectID, destinationProjectID: locator.projectID, destinationParentID: item.parentID, destinationTitle: item.title, sourceRelativePath: locator.relativePath, destinationRelativePath: relative, manifest: try Self.manifest(source))
            try save(journal)
            try fm.moveItem(at: source, to: target)
            journal.phase = "copied"; try save(journal)
            try commitTrash(journal)
            journal.phase = "finished"; try save(journal)
        }
    }

    func restore(id: String) throws {
        try serialized {
            guard let item = try library.item(id: id), item.deletedAt != nil else { return }
            let journals = try library.records(collection: "filesystem-journals", as: WorkspaceFileJournal.self)
            guard let journal = journals.last(where: { $0.itemID == id && $0.operation == "trash" && $0.phase == "finished" }) else { try library.restore(id: id); return }
            let root = try projectRoot(journal.sourceProjectID)
            let source = try LibraryStore.safeChild(root: root, relative: journal.destinationRelativePath)
            let destination = try LibraryStore.safeChild(root: root, relative: journal.sourceRelativePath)
            try requireMovableTree(destination)
            guard !fm.fileExists(atPath: destination.path) else { throw LibraryError.message("原位置已有同名内容；请先移动该内容再恢复。") }
            try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.moveItem(at: source, to: destination)
            do { try library.restore(id: id); try scan(projectID: journal.sourceProjectID) }
            catch { try? fm.moveItem(at: destination, to: source); throw error }
        }
    }

    func recoverFileOperations() throws -> [String] {
        try serialized {
            var messages: [String] = []
            for var journal in try library.records(collection: "filesystem-journals", as: WorkspaceFileJournal.self) where !["finished", "abandoned"].contains(journal.phase) {
                do {
                guard ["move", "trash"].contains(journal.operation), ["prepared", "copied", "committed"].contains(journal.phase), UUID(uuidString: journal.id) != nil else { throw LibraryError.message("文件操作恢复记录无效，原件保持不变。") }
                // Mounts may have moved since the journal was written. Stable project identities and
                // validated relative paths resolve the current locations; stale absolute paths do not.
                journal.source = try LibraryStore.safeChild(root: projectRoot(journal.sourceProjectID), relative: journal.sourceRelativePath).path
                journal.destination = try LibraryStore.safeChild(root: projectRoot(journal.destinationProjectID), relative: journal.destinationRelativePath).path
                try requireMovableTree(URL(fileURLWithPath: journal.source))
                try requireMovableTree(URL(fileURLWithPath: journal.destination))
                try save(journal)
                let target = URL(fileURLWithPath: journal.destination)
                guard fm.fileExists(atPath: target.path) else {
                    if fm.fileExists(atPath: journal.source) { journal.phase = "abandoned"; try save(journal); messages.append("保留未完成操作的原件：" + journal.destinationTitle) }
                    else { messages.append("操作两端均未连接，需要重新定位：" + journal.destinationTitle) }
                    continue
                }
                guard try Self.manifest(target) == journal.manifest else { messages.append("恢复目标已被修改，保留两端等待处理：" + journal.destinationTitle); continue }
                if journal.operation == "trash" { try commitTrash(journal) }
                else {
                    let item = try requireItem(journal.itemID)
                    try copyMetadata(items: [item] + library.descendantsOf(item.id, in: try library.items(includeDeleted: true)), from: journal.sourceProjectID, to: journal.destinationProjectID)
                    try commit(journal); try retireSource(journal)
                }
                journal.phase = "finished"; try save(journal)
                messages.append("已恢复文件操作：" + journal.destinationTitle)
                } catch { messages.append("文件操作仍待恢复：" + journal.destinationTitle + " — " + error.localizedDescription) }
            }
            return messages
        }
    }

    private func commit(_ journal: WorkspaceFileJournal) throws {
        try library.withTransaction {
            var item = try requireItem(journal.itemID)
            let affected = [item] + library.descendantsOf(item.id, in: try library.items(includeDeleted: true))
            item.parentID = journal.destinationParentID; item.courseID = journal.destinationProjectID; item.title = journal.destinationTitle; item.updatedAt = Date(); item.sortRank = nil
            try library.writeItem(item)
            for var child in affected {
                if child.kind == .classroom, child.courseID != journal.destinationProjectID {
                    // Physical folders can move across projects; their logical sessions retain the
                    // original course and links, so their parent must remain inside that course too.
                    child.parentID = child.courseID; child.updatedAt = Date(); try library.writeItem(child)
                    continue
                }
                guard var locator = try locator(id: child.id) else { continue }
                let suffix = locator.relativePath == journal.sourceRelativePath ? "" : String(locator.relativePath.dropFirst(journal.sourceRelativePath.count))
                // Recovery after a database commit is idempotent.
                if locator.projectID == journal.destinationProjectID && (locator.relativePath == journal.destinationRelativePath || locator.relativePath.hasPrefix(journal.destinationRelativePath + "/")) { continue }
                locator.projectID = journal.destinationProjectID; locator.relativePath = journal.destinationRelativePath + suffix; locator.updatedAt = Date(); locator.missing = false
                let url = try LibraryStore.safeChild(root: projectRoot(journal.destinationProjectID), relative: locator.relativePath)
                locator.fileIdentity = try Self.fileIdentity(url)
                try library.putRecord(collection: "document-locators", id: child.id, ownerID: child.id, value: locator)
                if child.id != item.id { child.courseID = journal.destinationProjectID; child.updatedAt = Date(); try library.writeItem(child) }
            }
        }
    }
    private func commitTrash(_ journal: WorkspaceFileJournal) throws {
        try library.withTransaction {
            guard let item = try library.item(id: journal.itemID) else { return }
            for var child in [item] + library.descendantsOf(item.id, in: try library.items(includeDeleted: true)) {
                child.deletedAt = journal.createdAt; child.deletionGroup = journal.id; child.updatedAt = Date(); try library.writeItem(child)
            }
        }
    }
    private func retireSource(_ journal: WorkspaceFileJournal) throws {
        let source = URL(fileURLWithPath: journal.source)
        guard fm.fileExists(atPath: source.path) else { return }
        try requireMovableTree(source)
        guard try Self.manifest(source) == journal.manifest else { throw LibraryError.message("移动已提交，但原位置随后有新修改；两份内容都已保留，需要手动处理。") }
        let root = try projectRoot(journal.sourceProjectID)
        let retained = try LibraryStore.safeChild(root: root, relative: ".ulecture/move-recovery/" + journal.id + "/" + source.lastPathComponent)
        try fm.createDirectory(at: retained.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard !fm.fileExists(atPath: retained.path) else { throw LibraryError.message("恢复目录已有内容，原件保留在原位置。") }
        try fm.moveItem(at: source, to: retained)
    }
    private func copyMetadata(items: [WorkspaceItem], from: String, to: String) throws {
        guard from != to else { return }
        let sourceRoot = try projectRoot(from), targetRoot = try projectRoot(to)
        for item in items {
            let relative = ".ulecture/documents/" + item.id
            let source = try LibraryStore.safeChild(root: sourceRoot, relative: relative)
            guard fm.fileExists(atPath: source.path) else { continue }
            let target = try LibraryStore.safeChild(root: targetRoot, relative: relative)
            if fm.fileExists(atPath: target.path) {
                guard try Self.manifest(source) == Self.manifest(target) else { throw LibraryError.message("目标批注/版本资源冲突，文件操作等待恢复。") }
            } else {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                let stage = target.deletingLastPathComponent().appendingPathComponent(".copy-" + item.id + "-" + UUID().uuidString)
                let expected = try Self.manifest(source)
                try fm.copyItem(at: source, to: stage)
                guard try Self.manifest(source) == expected, try Self.manifest(stage) == expected else { throw LibraryError.message("批注与版本复制校验失败。原件与暂存副本已保留。") }
                try fm.moveItem(at: stage, to: target)
                try library.syncDirectory(target.deletingLastPathComponent())
            }
        }
    }
    private func save(_ journal: WorkspaceFileJournal) throws { try library.putRecord(collection: "filesystem-journals", id: journal.id, ownerID: journal.itemID, value: journal) }
    func requireProjectRoot(_ root: URL) throws {
        let metadata = Self.canonicalURL(root.appendingPathComponent(".ulecture"))
        guard !excludedRoots.contains(where: {
            Self.contains($0, root) || Self.contains($0, metadata) || Self.contains(metadata, $0)
        }) else { throw LibraryError.message("此位置属于转写存储或应用资料；请选择其他课程文件夹。") }
    }
    func requireMovableTree(_ candidate: URL) throws {
        let candidate = Self.canonicalURL(candidate)
        guard !excludedRoots.contains(where: { root in
            let root = Self.canonicalURL(root)
            return Self.contains(candidate, root) || Self.contains(root, candidate)
        }) else { throw LibraryError.message("此文件夹包含或属于转写存储或应用资料，不能移动、重命名或删除。请先在设置中更改相应保存位置。") }
    }
    private func requireItem(_ id: String) throws -> WorkspaceItem { guard let item = try library.item(id: id) else { throw LibraryError.message("资料条目不存在。") }; return item }
    private func destination(_ parentID: String) throws -> (String, URL) {
        let parent = try requireItem(parentID)
        guard parent.deletedAt == nil else { throw LibraryError.message("目标已删除。") }
        if parent.kind == .course { return (parent.id, try projectRoot(parent.id)) }
        if parent.kind == .classroom, let physicalParent = parent.parentID { return try destination(physicalParent) }
        guard parent.kind == .folder, let locator = try locator(id: parent.id) else { throw LibraryError.message("请选择课程或文件夹。") }
        return (locator.projectID, try documentURL(id: parent.id))
    }
    static func contains(_ root: URL, _ child: URL) -> Bool {
        let path = canonicalURL(root).path, target = canonicalURL(child).path
        return target == path || target.hasPrefix(path == "/" ? "/" : path + "/")
    }
    static func relativePath(_ url: URL, under root: URL) throws -> String {
        let base = canonicalURL(root).path
        let path = canonicalURL(url).path
        guard path.hasPrefix(base + "/") else { throw LibraryError.message("文件不在指定课程目录内。") }
        return String(path.dropFirst(base.count + 1))
    }
    static func validName(_ value: String) throws -> String {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != ".", value != "..", !value.hasPrefix("."), !value.contains("/"), !value.contains(":"), !value.contains("\\"), !value.contains("\0"), value.utf8.count <= 220 else { throw LibraryError.message("名称不能为空、以点开头或包含路径分隔符，长度应小于 220 字节。") }
        return value
    }
    static func checkWritable(_ url: URL) throws {
        let values = try FileManager.default.attributesOfItem(atPath: url.path)
        guard FileManager.default.isWritableFile(atPath: url.path), ((values[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o222 != 0 else { throw LibraryError.message("文件夹不可写，内容尚未保存。") }
    }
    static func fileIdentity(_ url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        guard let device = attributes[.systemNumber] as? NSNumber, let inode = attributes[.systemFileNumber] as? NSNumber else { throw LibraryError.message("无法读取文件身份。") }
        return device.stringValue + ":" + inode.stringValue
    }
    static func contentHash(_ url: URL) throws -> String {
        // Package directory mtimes do not reflect in-place edits to note.json or nested assets.
        // Only current content participates in scanning; historical revisions are verified by move/backup.
        let manifest: [String: String]
        if url.pathExtension.lowercased() == "ulnote" {
            var current: [String: String] = [:]
            let note = url.appendingPathComponent("note.json")
            if FileManager.default.fileExists(atPath: note.path) { current["note.json"] = try LibraryStore.sha256(of: note) }
            let assets = url.appendingPathComponent("assets")
            if FileManager.default.fileExists(atPath: assets.path) {
                for (path, hash) in try Self.manifest(assets) { current["assets/" + path] = hash }
            }
            manifest = current
        } else { manifest = try Self.manifest(url) }
        if manifest.count == 1, let file = manifest["."] { return file }
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
    static func manifest(_ url: URL) throws -> [String: String] {
        let attrs = try url.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard attrs.isSymbolicLink != true else { throw LibraryError.message("资料包含符号链接，不能安全复制。") }
        if attrs.isDirectory != true { return [".": try LibraryStore.sha256(of: url)] }
        var result = ["/": "directory"]
        var enumerationError: Error?
        guard let enumerator = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey], errorHandler: { _, error in enumerationError = error; return false }) else { throw LibraryError.message("无法读取资料目录。") }
        for case let child as URL in enumerator {
            let values = try child.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isSymbolicLink != true else { throw LibraryError.message("资料包含符号链接，不能安全复制。") }
            let relative = try relativePath(child, under: url)
            result[relative] = values.isDirectory == true ? "directory" : try LibraryStore.sha256(of: child)
        }
        if let enumerationError { throw enumerationError }
        return result
    }
}

private extension LibraryStore {
    static func safeChild(root: URL, relative: String) throws -> URL { try safeChild(relative, under: root) }
}
