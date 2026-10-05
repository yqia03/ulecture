import Foundation

struct WorkspaceArchivePayload: Codable {
    var path: String
    var hashes: [String: String]
}
struct WorkspaceArchiveDocument: Codable {
    var id: String
    var projectID: String
    var relativePath: String
    var format: String
    var payload: String
    var metadataPayload: String?
}
struct WorkspaceArchiveTextRecovery: Codable {
    var sessionID: String
    var payload: String
}
struct WorkspaceArchiveManifest: Codable {
    var format = "ulecture-portable-workspace"
    var version = 2
    var snapshotID: String
    var createdAt: Date
    var rootItemID: String
    var items: [WorkspaceItem]
    var records: [PortableRecord]
    var attachments: [ManagedAttachment]
    var documents: [WorkspaceArchiveDocument]
    var payloads: [WorkspaceArchivePayload]
    /// Optional for backwards compatibility with earlier v2 archives.
    var textRecovery: [WorkspaceArchiveTextRecovery]? = nil
    var notice = "Frozen documents, versions, annotations and saved session records. Credentials, models, bookmarks and original absolute paths are excluded. Incomplete live audio is not represented as a completed recording."
}

final class WorkspaceArchive {
    let catalog: WorkspaceCatalog
    var library: LibraryStore { catalog.library }
    private let fm = FileManager.default
    private static let localCollections: Set<String> = ["project-mounts", "document-locators", "filesystem-journals", "course-migrations", "legacy-migration", "workspace-restores", "workspace-restore-pending", "transcript-recovery"]
    init(catalog: WorkspaceCatalog) { self.catalog = catalog }

    func backup(itemID: String, to destination: URL) throws {
        guard !fm.fileExists(atPath: destination.path) else { throw LibraryError.message("目标已存在，请使用新的备份名称。") }
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".ulecture-backup-" + UUID().uuidString)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        var sources: [(URL, WorkspaceArchivePayload)] = []
        var manifest = try library.withReadSnapshot { () throws -> WorkspaceArchiveManifest in
            let allItems = try library.items(includeDeleted: true)
            let allRecords = try library.databaseRows("SELECT collection,id,owner_id,json FROM records ORDER BY rowid").map {
                PortableRecord(collection: $0["collection"]!, id: $0["id"]!, ownerID: $0["owner_id"]!, json: $0["json"]!)
            }
            let allAssets = try library.attachments()
            let scope = try closure(itemID: itemID, items: allItems, records: allRecords, assets: allAssets)
            let ids = Set(scope.map(\.id))
            let records = allRecords.filter { ids.contains($0.ownerID) && !Self.localCollections.contains($0.collection) }
            var assets = allAssets.filter { ids.contains($0.ownerID) }
            var documents: [WorkspaceArchiveDocument] = []
            var textRecovery: [WorkspaceArchiveTextRecovery] = []
            for item in scope where [.pdf, .note, .folder].contains(item.kind) {
                if let locator = try catalog.locator(id: item.id) {
                    let source = try archiveDocumentURL(item, locator: locator)
                    let payload = "documents/" + item.id + (locator.format == "folder" ? "" : "." + locator.format)
                    // Folder hierarchy is carried by items; do not accidentally include unsupported, unselected files.
                    if item.kind != .folder { sources.append((source, WorkspaceArchivePayload(path: payload, hashes: try WorkspaceCatalog.manifest(source)))) }
                    var metadataPayload: String?
                    let metadata = try LibraryStore.safeChild(".ulecture/documents/" + item.id, under: catalog.projectRoot(locator.projectID))
                    if fm.fileExists(atPath: metadata.path) {
                        metadataPayload = "document-data/" + item.id
                        sources.append((metadata, WorkspaceArchivePayload(path: metadataPayload!, hashes: try WorkspaceCatalog.manifest(metadata))))
                    }
                    documents.append(WorkspaceArchiveDocument(id: item.id, projectID: locator.projectID, relativePath: locator.relativePath, format: locator.format, payload: payload, metadataPayload: metadataPayload))
                } else {
                    let metadata = library.rootURL.appendingPathComponent("document-data/" + item.id)
                    let metadataPayload = fm.fileExists(atPath: metadata.path) ? "document-data/" + item.id : nil
                    if let metadataPayload { sources.append((metadata, WorkspaceArchivePayload(path: metadataPayload, hashes: try WorkspaceCatalog.manifest(metadata)))) }
                    if let projectID = item.courseID {
                        var format = item.kind == .folder ? "folder" : (item.kind == .pdf ? "pdf" : "md")
                        let source: URL?
                        if item.kind == .pdf, let assetID = item.assetID { source = try library.attachmentURL(assetID: assetID) }
                        else if item.kind == .note {
                            let package = metadata.appendingPathComponent("note.ulnote")
                            if fm.fileExists(atPath: package.appendingPathComponent("note.json").path) { source = package; format = "ulnote" }
                            else {
                                let frozen = stage.appendingPathComponent("frozen-legacy/" + item.id + ".md")
                                try fm.createDirectory(at: frozen.deletingLastPathComponent(), withIntermediateDirectories: true)
                                try Data((library.noteRevision(noteID: item.id)?.markdown ?? "").utf8).write(to: frozen)
                                source = frozen
                            }
                        } else { source = nil }
                        var parents = [WorkspaceItem](), cursor = item.parentID
                        while let id = cursor, let parent = scope.first(where: { $0.id == id }), parent.kind != .course {
                            if parent.kind == .folder { parents.insert(parent, at: 0) }; cursor = parent.parentID
                        }
                        func name(_ value: WorkspaceItem) -> String { value.title.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") + "-" + String(value.id.prefix(8)) }
                        let relative = (parents.map(name) + [name(item) + (format == "folder" ? "" : "." + format)]).joined(separator: "/")
                        let payload = "documents/" + item.id + (format == "folder" ? "" : "." + format)
                        if let source { sources.append((source, WorkspaceArchivePayload(path: payload, hashes: try WorkspaceCatalog.manifest(source)))) }
                        documents.append(WorkspaceArchiveDocument(id: item.id, projectID: projectID, relativePath: relative, format: format, payload: payload, metadataPayload: metadataPayload))
                    }
                }
            }
            for index in assets.indices {
                let source = try library.attachmentURL(assetID: assets[index].id)
                let ext = source.pathExtension.lowercased()
                guard try LibraryStore.sha256(of: source) == assets[index].sha256 else { throw LibraryError.message("附件校验失败，备份未完成。") }
                assets[index].relativePath = "attachments/" + assets[index].id + (ext.isEmpty ? "" : "." + ext)
                sources.append((source, WorkspaceArchivePayload(path: assets[index].relativePath, hashes: [".": assets[index].sha256])))
            }
            // Exercise the WAL snapshot API and compare its facts with the catalog's same-barrier record set.
            if let store = library.transcriptStore {
                for session in scope where session.kind == .classroom {
                    let path = stage.appendingPathComponent("session-checkpoint-" + session.id + ".sqlite")
                    try store.snapshot(session: session, to: path)
                    let checkpoint = try SQLiteDatabase(url: path, readOnly: true)
                    let external = try checkpoint.rows("SELECT collection,id,json FROM records").map { $0["collection"]! + ":" + $0["id"]! + ":" + $0["json"]! }.sorted()
                    let catalogRecords = allRecords.filter { $0.ownerID == session.id && !["filesystem-journals", "session-document-links", "transcript-recovery"].contains($0.collection) }.map { $0.collection + ":" + $0.id + ":" + $0.json }.sorted()
                    guard external == catalogRecords else { throw LibraryError.message("会话有尚未协调的保存结果，备份未发布。请先重试保存。") }
                    let recovery = try store.directory(for: session).appendingPathComponent("text-recovery")
                    if fm.fileExists(atPath: recovery.path) {
                        let payload = "session-text-recovery/" + session.id
                        sources.append((recovery, WorkspaceArchivePayload(path: payload, hashes: try WorkspaceCatalog.manifest(recovery))))
                        textRecovery.append(WorkspaceArchiveTextRecovery(sessionID: session.id, payload: payload))
                    }
                }
            }
            return WorkspaceArchiveManifest(snapshotID: UUID().uuidString, createdAt: Date(), rootItemID: itemID, items: scope, records: records, attachments: assets, documents: documents, payloads: [], textRecovery: textRecovery.isEmpty ? nil : textRecovery)
        }
        // Copy all large resources after releasing the database barrier; verify against frozen manifests twice.
        for (source, payload) in sources {
            let target = try LibraryStore.safeChild(payload.path, under: stage)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try fm.copyItem(at: source, to: target)
            guard try WorkspaceCatalog.manifest(target) == payload.hashes, try WorkspaceCatalog.manifest(source) == payload.hashes else { throw LibraryError.message("备份期间文件发生变化，保留暂存副本，未显示成功。") }
            manifest.payloads.append(payload)
        }
        for (source, payload) in sources { guard try WorkspaceCatalog.manifest(source) == payload.hashes else { throw LibraryError.message("备份期间资料有新版本，请重试。") } }
        for file in try fm.contentsOfDirectory(at: stage, includingPropertiesForKeys: nil) where file.lastPathComponent.hasPrefix("session-checkpoint-") { try fm.removeItem(at: file) }
        let frozenLegacy = stage.appendingPathComponent("frozen-legacy")
        if fm.fileExists(atPath: frozenLegacy.path) { try fm.removeItem(at: frozenLegacy) }
        let data = try JSONEncoder().encode(manifest)
        try data.write(to: stage.appendingPathComponent("manifest.json"), options: .atomic)
        try validate(manifest, at: stage)
        try library.syncDirectory(stage)
        try fm.moveItem(at: stage, to: destination)
        try library.syncDirectory(destination.deletingLastPathComponent())
    }

    private func closure(itemID: String, items: [WorkspaceItem], records: [PortableRecord], assets: [ManagedAttachment]) throws -> [WorkspaceItem] {
        guard let root = items.first(where: { $0.id == itemID }) else { throw LibraryError.message("备份对象不存在。") }
        let byID = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        var ids = Set(([root] + library.descendantsOf(itemID, in: items)).map(\.id))
        let owners = Dictionary(assets.map { ($0.id, $0.ownerID) } + records.map { ($0.id, $0.ownerID) }, uniquingKeysWith: { old, _ in old })
        func referenceIDs(_ value: Any, field: String = "") -> Set<String> {
            if let dictionary = value as? [String: Any] { return dictionary.reduce(into: Set<String>()) { $0.formUnion(referenceIDs($1.value, field: $1.key)) } }
            if let array = value as? [Any] { return array.reduce(into: Set<String>()) { $0.formUnion(referenceIDs($1, field: field)) } }
            if ["documentID", "entityID", "assetID", "noteID", "classID", "classroomID", "sessionID"].contains(field), let id = value as? String { return [id] }
            return []
        }
        var previous = Set<String>(), inspectedFiles = Set<String>()
        while previous != ids {
            previous = ids
            for id in previous {
                if let item = byID[id] {
                    ids.formUnion([item.parentID, item.courseID, item.classroomID].compactMap { $0 })
                    if inspectedFiles.insert(id).inserted, [.pdf, .note].contains(item.kind) {
                        var roots = [URL]()
                        if let locator = try catalog.locator(id: id) {
                            roots.append(try archiveDocumentURL(item, locator: locator))
                            let metadata = try LibraryStore.safeChild(".ulecture/documents/" + id, under: catalog.projectRoot(locator.projectID))
                            if fm.fileExists(atPath: metadata.path) { roots.append(metadata) }
                        } else {
                            let metadata = library.rootURL.appendingPathComponent("document-data/" + id)
                            if fm.fileExists(atPath: metadata.path) { roots.append(metadata) }
                        }
                        for root in roots {
                            for reference in try Self.fileReferences(root) { ids.insert(byID[reference] != nil ? reference : (owners[reference] ?? reference)) }
                        }
                    }
                }
            }
            for record in records where ids.contains(record.ownerID) && !Self.localCollections.contains(record.collection) {
                let object = try JSONSerialization.jsonObject(with: Data(record.json.utf8), options: [.fragmentsAllowed])
                for reference in referenceIDs(object) {
                    if byID[reference] != nil { ids.insert(reference) }
                    else if let owner = owners[reference] { ids.insert(owner) }
                }
            }
            for record in records where record.collection == "session-document-links" {
                let link = try JSONDecoder().decode(SessionDocumentLink.self, from: Data(record.json.utf8))
                if ids.contains(link.documentID) || ids.contains(link.sessionID) { ids.insert(link.documentID); ids.insert(link.sessionID) }
            }
        }
        guard ids.allSatisfy({ byID[$0] != nil }) else { throw LibraryError.message("资料关联有缺失，备份未完成。") }
        return items.filter { ids.contains($0.id) }
    }

    private func archiveDocumentURL(_ item: WorkspaceItem, locator: DocumentLocator) throws -> URL {
        if item.deletedAt == nil { return try catalog.documentURL(id: item.id) }
        let journals = try library.records(collection: "filesystem-journals", as: WorkspaceFileJournal.self)
        if let trash = journals.last(where: { $0.operation == "trash" && $0.phase == "finished" && $0.sourceProjectID == locator.projectID && (locator.relativePath == $0.sourceRelativePath || locator.relativePath.hasPrefix($0.sourceRelativePath + "/")) }) {
            let suffix = String(locator.relativePath.dropFirst(trash.sourceRelativePath.count))
            return try LibraryStore.safeChild(trash.destinationRelativePath + suffix, under: catalog.projectRoot(locator.projectID))
        }
        return try catalog.documentURL(id: item.id)
    }

    static func fileReferences(_ root: URL) throws -> Set<String> {
        var files = [URL](), result = Set<String>()
        let directory = try root.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true
        if directory, let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isSymbolicLinkKey]) {
            for case let file as URL in enumerator where ["json", "md", "txt"].contains(file.pathExtension.lowercased()) { files.append(file) }
        } else if !directory { files = [root] }
        func collect(_ object: Any, field: String = "") {
            if let object = object as? [String: Any] { for (key, value) in object { collect(value, field: key) } }
            else if let array = object as? [Any] { for value in array { collect(value, field: field) } }
            else if let text = object as? String {
                if field == "documentID", UUID(uuidString: text) != nil { result.insert(text) }
                let expression = try! NSRegularExpression(pattern: "(?:ulecture-document|uway-pdf)://([0-9A-Fa-f-]{36})")
                for match in expression.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                    if let range = Range(match.range(at: 1), in: text) { result.insert(String(text[range])) }
                }
            }
        }
        for file in files {
            guard ["json", "md", "txt"].contains(file.pathExtension.lowercased()) else { continue }
            let bytes = try Data(contentsOf: file)
            if file.pathExtension == "json", let object = try? JSONSerialization.jsonObject(with: bytes) { collect(object) }
            else if let text = String(data: bytes, encoding: .utf8) { collect(text) }
        }
        return result
    }

    func validate(_ manifest: WorkspaceArchiveManifest, at root: URL) throws {
        guard manifest.format == "ulecture-portable-workspace", manifest.version == 2,
              UUID(uuidString: manifest.snapshotID) != nil, !manifest.items.isEmpty, manifest.items.count <= 100_000,
              manifest.records.count <= 1_000_000, manifest.payloads.count <= 200_000 else { throw LibraryError.message("备份格式不支持或规模无效。") }
        let ids = Set(manifest.items.map(\.id))
        guard ids.count == manifest.items.count, ids.contains(manifest.rootItemID), ids.allSatisfy({ UUID(uuidString: $0) != nil }) else { throw LibraryError.message("备份身份无效或重复。") }
        let items = Dictionary(uniqueKeysWithValues: manifest.items.map { ($0.id, $0) })
        for item in manifest.items {
            guard item.parentID == nil || ids.contains(item.parentID!), item.courseID == nil || items[item.courseID!]?.kind == .course,
                  item.classroomID == nil || items[item.classroomID!]?.kind == .classroom else { throw LibraryError.message("备份引用缺失。") }
            var seen = Set([item.id]), cursor = item.parentID
            while let parent = cursor { guard seen.insert(parent).inserted else { throw LibraryError.message("备份包含循环层级。") }; cursor = items[parent]?.parentID }
        }
        var paths = Set<String>(), recordIDs = Set<String>()
        for record in manifest.records {
            try library.validateCollection(record.collection)
            guard ids.contains(record.ownerID), !Self.localCollections.contains(record.collection), recordIDs.insert(record.collection + ":" + record.id).inserted else { throw LibraryError.message("备份记录包含本机位置、重复或缺失归属。") }
            _ = try JSONSerialization.jsonObject(with: Data(record.json.utf8), options: [.fragmentsAllowed])
        }
        for payload in manifest.payloads {
            guard paths.insert(payload.path).inserted, !payload.hashes.isEmpty else { throw LibraryError.message("备份资源重复或清单为空。") }
            let url = try LibraryStore.safeChild(payload.path, under: root)
            guard try WorkspaceCatalog.manifest(url) == payload.hashes else { throw LibraryError.message("备份资源校验失败，现有资料未修改。") }
        }
        var recoveredSessions = Set<String>()
        for recovery in manifest.textRecovery ?? [] {
            guard items[recovery.sessionID]?.kind == .classroom, recoveredSessions.insert(recovery.sessionID).inserted,
                  recovery.payload == "session-text-recovery/" + recovery.sessionID, paths.contains(recovery.payload) else {
                throw LibraryError.message("转写恢复副本的归属或资源无效。")
            }
        }
        var documentIDs = Set<String>(), documentPaths = Set<String>()
        for document in manifest.documents {
            guard documentIDs.insert(document.id).inserted, documentPaths.insert(document.projectID + ":" + document.relativePath).inserted,
                  WorkspaceCatalog.formats.contains(document.format) || document.format == "folder", ids.contains(document.id), items[document.projectID]?.kind == .course,
                  items[document.id]?.courseID == document.projectID,
                  document.format == "folder" || paths.contains(document.payload),
                  document.metadataPayload == nil || paths.contains(document.metadataPayload!) else { throw LibraryError.message("备份文档或版本依赖不完整。") }
            _ = try LibraryStore.safeChild(document.relativePath, under: root)
            for path in [document.format == "folder" ? nil : document.payload, document.metadataPayload].compactMap({ $0 }) {
                guard try Self.fileReferences(LibraryStore.safeChild(path, under: root)).isSubset(of: ids.union(manifest.attachments.map(\.id))) else { throw LibraryError.message("笔记或批注引用了备份范围外资料。") }
            }
        }
        let assets = Dictionary(manifest.attachments.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        guard assets.count == manifest.attachments.count else { throw LibraryError.message("附件身份重复。") }
        let records = Dictionary(uniqueKeysWithValues: manifest.records.map { ($0.collection + ":" + $0.id, $0) })
        for record in manifest.records {
            try InterpretationRecordValidation.portable(record) { items[$0]?.kind == .classroom }
            switch record.collection {
            case "transcripts":
                let value = try JSONDecoder().decode(TranscriptRecord.self, from: Data(record.json.utf8))
                guard value.classroomID == record.ownerID, items[value.classroomID]?.kind == .classroom, value.startMS >= 0, value.endMS >= value.startMS else { throw LibraryError.message("转写时间或归属无效。") }
            case "recordings":
                let value = try JSONDecoder().decode(RecordingRecord.self, from: Data(record.json.utf8))
                guard value.classroomID == record.ownerID, assets[value.assetID]?.ownerID == record.ownerID, value.endMS > value.startMS else { throw LibraryError.message("录音引用或时间映射不完整。") }
            case "session-document-links":
                let value = try JSONDecoder().decode(SessionDocumentLink.self, from: Data(record.json.utf8))
                guard ids.contains(value.documentID), items[value.sessionID]?.kind == .classroom else { throw LibraryError.message("会话资料引用缺失。") }
            case "assistant-turns":
                let object = try JSONSerialization.jsonObject(with: Data(record.json.utf8)) as? [String: Any]
                guard let snapshotID = object?["snapshotID"] as? String, records["assistant-snapshots:" + snapshotID]?.ownerID == record.ownerID else { throw LibraryError.message("AI 来源快照缺失。") }
            case "assistant-snapshots":
                let object = try JSONSerialization.jsonObject(with: Data(record.json.utf8)) as? [String: Any]
                guard let sources = object?["sources"] as? [[String: Any]] else { throw LibraryError.message("AI 来源快照无效。") }
                var sourceIDs = Set<String>()
                for value in sources {
                    guard let id = value["id"] as? String, sourceIDs.insert(id).inserted, let documentID = value["documentID"] as? String, ids.contains(documentID), value["text"] is String else { throw LibraryError.message("AI 来源身份或固定文字缺失。") }
                }
            default: break
            }
        }
        for asset in manifest.attachments {
            guard ids.contains(asset.ownerID), paths.contains(asset.relativePath),
                  manifest.payloads.first(where: { $0.path == asset.relativePath })?.hashes["."] == asset.sha256 else { throw LibraryError.message("备份附件依赖不完整。") }
        }
    }
}
