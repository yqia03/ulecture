import Foundation
import AppKit
import CryptoKit

private struct WorkspaceRestoreTarget: Codable {
    var stagedPath: String
    var destination: String
    var hashes: [String: String]
}
private struct WorkspaceRestoreJournal: Codable {
    var id = UUID().uuidString
    var sourceHash: String
    var destination: String
    var idMap: [String: String]
    var hashMap: [String: String] = [:]
    var targets: [WorkspaceRestoreTarget] = []
    var phase = "prepared"
}

extension WorkspaceArchive {
    /// Restores into new physical folders and new catalog identities. A durable journal allows the
    /// exact same prepared operation to resume after a process death without overwriting user files.
    @discardableResult func restore(from source: URL, into destination: URL, checkpoint: ((String) throws -> Void)? = nil) throws -> [WorkspaceItem] {
        let fm = FileManager.default
        try library.checkWritable()
        let manifestURL = try LibraryStore.safeChild("manifest.json", under: source)
        let size = (try fm.attributesOfItem(atPath: manifestURL.path)[.size] as? NSNumber)?.int64Value ?? .max
        guard size <= 256 * 1024 * 1024 else { throw LibraryError.message("备份清单过大。") }
        let manifestBytes = try Data(contentsOf: manifestURL)
        let manifest = try JSONDecoder().decode(WorkspaceArchiveManifest.self, from: manifestBytes)
        try validate(manifest, at: source) // No destination mutations until the complete closure verifies.
        let destination = destination.standardizedFileURL.resolvingSymlinksInPath()
        try WorkspaceCatalog.checkWritable(destination)
        guard !WorkspaceCatalog.contains(source, destination), !WorkspaceCatalog.contains(destination, source),
              !WorkspaceCatalog.contains(library.rootURL, destination),
              !WorkspaceCatalog.contains(destination, library.rootURL) else { throw LibraryError.message("恢复位置必须独立于备份和应用资料目录。") }
        for root in try catalog.mounts(includeUnmounted: true).map({ URL(fileURLWithPath: $0.rootPath) }) + [library.transcriptStore?.rootURL].compactMap({ $0 }) {
            guard !WorkspaceCatalog.contains(root, destination) else { throw LibraryError.message("恢复位置不能与已有课程或转写目录嵌套。") }
        }
        let sourceHash = try LibraryStore.sha256(of: manifestURL)
        let journalRoot = library.rootURL.appendingPathComponent("archive-restores")
        try fm.createDirectory(at: journalRoot, withIntermediateDirectories: true)
        var resumed: (URL, WorkspaceRestoreJournal)?
        for file in try fm.contentsOfDirectory(at: journalRoot, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            let candidate = try JSONDecoder().decode(WorkspaceRestoreJournal.self, from: Data(contentsOf: file))
            if candidate.sourceHash == sourceHash && candidate.destination == destination.path && candidate.phase != "completed" { resumed = (file, candidate); break }
        }
        var journal: WorkspaceRestoreJournal
        let journalURL: URL
        if let resumed { journalURL = resumed.0; journal = resumed.1 }
        else {
            var mapping = Dictionary(uniqueKeysWithValues: manifest.items.map { ($0.id, UUID().uuidString) })
            for asset in manifest.attachments { mapping[asset.id] = UUID().uuidString }
            for record in manifest.records {
                ArchiveIdentity.collect(record.id, field: "id", into: &mapping)
                ArchiveIdentity.collect(try JSONSerialization.jsonObject(with: Data(record.json.utf8)), into: &mapping)
            }
            // IDs in block revisions and annotation histories belong to the same restored identity closure.
            for payload in manifest.payloads where payload.path.hasPrefix("documents/") && payload.path.hasSuffix(".ulnote") || payload.path.hasPrefix("document-data/") {
                let root = try LibraryStore.safeChild(payload.path, under: source)
                if let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: nil) {
                    for case let file as URL in enumerator where file.pathExtension == "json" {
                        if let object = try? JSONSerialization.jsonObject(with: Data(contentsOf: file)) { ArchiveIdentity.collect(object, into: &mapping) }
                    }
                }
            }
            journal = WorkspaceRestoreJournal(sourceHash: sourceHash, destination: destination.path, idMap: mapping)
            journalURL = journalRoot.appendingPathComponent(journal.id + ".json")
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            try library.syncDirectory(journalRoot)
        }
        let stage = destination.appendingPathComponent(".ulecture-restore-" + journal.id)
        let map = journal.idMap
        var items = try manifest.items.map { value -> WorkspaceItem in
            var result = try JSONDecoder().decode(WorkspaceItem.self, from: ArchiveIdentity.rewrite(try JSONEncoder().encode(value), map: map))
            result.deletedAt = nil; result.deletionGroup = nil; result.updatedAt = Date()
            if value.id == manifest.rootItemID { result.title += "（恢复）" }
            return result
        }
        let rootID = map[manifest.rootItemID]!
        if let _: RestoreCommit = try library.record(collection: "workspace-restores", id: journal.id, as: RestoreCommit.self) {
            journal.phase = "completed"; try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            return items
        }
        let courses = items.filter { $0.kind == .course }
        let coursePaths = Dictionary(uniqueKeysWithValues: courses.map { ($0.id, "恢复-" + $0.id) })
        if journal.phase == "prepared" {
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            func mapTranscript(_ data: Data) throws {
                let original = try JSONDecoder().decode(TranscriptRecord.self, from: data)
                let restored = try JSONDecoder().decode(TranscriptRecord.self, from: ArchiveIdentity.rewrite(data, map: map))
                func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
                journal.hashMap[hash(try encoder.encode(original))] = hash(try encoder.encode(restored))
            }
            for record in manifest.records {
                if record.collection == "transcripts" { try mapTranscript(Data(record.json.utf8)) }
                if record.collection == "assistant-snapshots", let object = try JSONSerialization.jsonObject(with: Data(record.json.utf8)) as? [String: Any] {
                    for source in object["sources"] as? [[String: Any]] ?? [] {
                        if let frozen = source["transcriptSnapshot"] as? [String: Any] { try mapTranscript(JSONSerialization.data(withJSONObject: frozen)) }
                    }
                }
            }
            // A prior interrupted preparation is retained and not reused as trusted input.
            if fm.fileExists(atPath: stage.path) {
                try fm.moveItem(at: stage, to: destination.appendingPathComponent(".ulecture-restore-interrupted-" + UUID().uuidString))
            }
            try fm.createDirectory(at: stage, withIntermediateDirectories: false)
            for course in courses { try fm.createDirectory(at: stage.appendingPathComponent("projects/" + coursePaths[course.id]!), withIntermediateDirectories: true) }
            for document in manifest.documents.sorted(by: { $0.relativePath.count < $1.relativePath.count }) {
                let projectID = map[document.projectID]!
                let project = stage.appendingPathComponent("projects/" + coursePaths[projectID]!)
                let target = try LibraryStore.safeChild(document.relativePath, under: project)
                if document.format == "folder" { try fm.createDirectory(at: target, withIntermediateDirectories: true) }
                else {
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: LibraryStore.safeChild(document.payload, under: source), to: target)
                    if document.format == "ulnote" { try rewriteDocumentTree(target, map: map, hashMap: &journal.hashMap) }
                    else if ["md", "txt"].contains(document.format) {
                        let oldHash = try LibraryStore.sha256(of: target)
                        try ArchiveIdentity.rewriteTextFile(target, map: map)
                        journal.hashMap[oldHash] = try LibraryStore.sha256(of: target)
                    }
                }
                if let metadata = document.metadataPayload {
                    let target = project.appendingPathComponent(".ulecture/documents/" + map[document.id]!)
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.copyItem(at: LibraryStore.safeChild(metadata, under: source), to: target)
                    try rewriteDocumentTree(target, map: map, hashMap: &journal.hashMap)
                }
            }
            journal.targets = try courses.map { course in
                let path = "projects/" + coursePaths[course.id]!
                return WorkspaceRestoreTarget(stagedPath: path, destination: destination.appendingPathComponent(coursePaths[course.id]!).path, hashes: try WorkspaceCatalog.manifest(stage.appendingPathComponent(path)))
            }
            for recovery in manifest.textRecovery ?? [] {
                guard let id = map[recovery.sessionID], let session = items.first(where: { $0.id == id }),
                      let store = library.transcriptStore else { throw LibraryError.message("请先设置转写保存位置再恢复会话文本副本。") }
                let staged = "session-text-recovery/" + id
                let target = try LibraryStore.safeChild(staged, under: stage)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: LibraryStore.safeChild(recovery.payload, under: source), to: target)
                // Recovery text is opaque user content: do not rewrite UUIDs, links or byte order.
                let final = try store.directory(for: session).appendingPathComponent("text-recovery")
                journal.targets.append(WorkspaceRestoreTarget(stagedPath: staged, destination: final.path, hashes: try WorkspaceCatalog.manifest(target)))
            }
            for asset in manifest.attachments {
                let assetID = map[asset.id]!, ownerID = map[asset.ownerID]!
                let ext = URL(fileURLWithPath: asset.relativePath).pathExtension
                let name = assetID + (ext.isEmpty ? "" : "." + ext)
                let staged = "attachments/" + name
                let target = stage.appendingPathComponent(staged)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: LibraryStore.safeChild(asset.relativePath, under: source), to: target)
                let final: URL
                if let owner = items.first(where: { $0.id == ownerID && $0.kind == .classroom }), let store = library.transcriptStore {
                    final = try store.directory(for: owner).appendingPathComponent("recordings/" + name)
                } else { final = library.rootURL.appendingPathComponent(staged) }
                journal.targets.append(WorkspaceRestoreTarget(stagedPath: staged, destination: final.path, hashes: [".": asset.sha256]))
            }
            // Legacy document metadata may have no physical document locator yet.
            let mappedMetadata = Set(manifest.documents.compactMap(\.metadataPayload))
            for payload in manifest.payloads where payload.path.hasPrefix("document-data/") && !mappedMetadata.contains(payload.path) {
                let oldID = URL(fileURLWithPath: payload.path).lastPathComponent
                guard let id = map[oldID] else { throw LibraryError.message("文档元数据缺少身份。") }
                let staged = "document-data/" + id
                let target = stage.appendingPathComponent(staged)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: LibraryStore.safeChild(payload.path, under: source), to: target)
                try rewriteDocumentTree(target, map: map, hashMap: &journal.hashMap)
                journal.targets.append(WorkspaceRestoreTarget(stagedPath: staged, destination: library.rootURL.appendingPathComponent(staged).path, hashes: try WorkspaceCatalog.manifest(target)))
            }
            journal.phase = "verified"
            try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
            try library.syncDirectory(journalRoot)
        }
        // A matching complete copy may be left after any one of these moves. Recheck it, never overwrite it.
        for target in journal.targets {
            let final = URL(fileURLWithPath: target.destination)
            if fm.fileExists(atPath: final.path) {
                guard try WorkspaceCatalog.manifest(final) == target.hashes else { throw LibraryError.message("中断恢复的目标已被修改，已停止且未覆盖。请保留它并选择新的恢复位置。") }
            } else {
                let staged = try LibraryStore.safeChild(target.stagedPath, under: stage)
                guard try WorkspaceCatalog.manifest(staged) == target.hashes else { throw LibraryError.message("恢复暂存资源校验失败。") }
                try fm.createDirectory(at: final.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: staged, to: final)
                try library.syncDirectory(final.deletingLastPathComponent())
            }
        }
        try checkpoint?("published")
        var records = try manifest.records.filter { !["session-attachments", "session-attachment-metadata"].contains($0.collection) }.map { record -> PortableRecord in
            var value = record
            value.id = ArchiveIdentity.replace(record.id, map: map)
            value.ownerID = map[record.ownerID]!
            let data = try ArchiveIdentity.rewrite(Data(record.json.utf8), map: map, hashes: journal.hashMap)
            value.json = String(decoding: try suspendRestoredWork(data, collection: record.collection), as: UTF8.self)
            return value
        }
        var assets = [ManagedAttachment]()
        for asset in manifest.attachments {
            var value = asset; value.id = map[asset.id]!; value.ownerID = map[asset.ownerID]!
            let ext = URL(fileURLWithPath: asset.relativePath).pathExtension
            value.relativePath = "attachments/" + value.id + (ext.isEmpty ? "" : "." + ext)
            assets.append(value)
            if library.transcriptStore != nil, items.contains(where: { $0.id == value.ownerID && $0.kind == .classroom }) {
                let location = SessionAttachmentLocation(assetID: value.id, sessionID: value.ownerID, relativePath: "recordings/" + URL(fileURLWithPath: value.relativePath).lastPathComponent)
                records.append(PortableRecord(collection: "session-attachments", id: value.id, ownerID: value.ownerID, json: String(decoding: try JSONEncoder().encode(location), as: UTF8.self)))
                records.append(PortableRecord(collection: "session-attachment-metadata", id: value.id, ownerID: value.ownerID, json: String(decoding: try JSONEncoder().encode(value), as: UTF8.self)))
            }
        }
        for session in items where session.kind == .classroom {
            let value = ["restoreTaskID": journal.id]
            records.append(PortableRecord(collection: "workspace-restore-pending", id: session.id, ownerID: session.id, json: String(decoding: try JSONEncoder().encode(value), as: UTF8.self)))
        }
        try library.withTransaction {
            var pending = items, written = Set<String>()
            while !pending.isEmpty {
                let ready = pending.filter { $0.parentID == nil || written.contains($0.parentID!) }
                guard !ready.isEmpty else { throw LibraryError.message("恢复层级循环。") }
                for item in ready { try library.writeItem(item); written.insert(item.id) }
                pending.removeAll { written.contains($0.id) }
            }
            for asset in assets { try library.writeAttachment(asset) }
            for record in records { try library.writePortableRecord(record) }
            for course in courses {
                let root = destination.appendingPathComponent(coursePaths[course.id]!)
                let bookmark = try? root.bookmarkData(options: .minimalBookmark, includingResourceValuesForKeys: nil, relativeTo: nil)
                try library.putRecord(collection: "project-mounts", id: course.id, ownerID: course.id, value: ProjectMount(id: course.id, rootPath: root.path, bookmark: bookmark))
            }
            for document in manifest.documents {
                let id = map[document.id]!, projectID = map[document.projectID]!
                let root = destination.appendingPathComponent(coursePaths[projectID]!)
                let file = try LibraryStore.safeChild(document.relativePath, under: root)
                let locator = DocumentLocator(id: id, projectID: projectID, relativePath: document.relativePath, format: document.format,
                    fileIdentity: try WorkspaceCatalog.fileIdentity(file), contentHash: document.format == "folder" ? nil : try WorkspaceCatalog.contentHash(file))
                try library.putRecord(collection: "document-locators", id: id, ownerID: id, value: locator)
            }
            try library.putRecord(collection: "workspace-restores", id: journal.id, ownerID: rootID, value: RestoreCommit(snapshotID: manifest.snapshotID, itemIDs: items.map(\.id)))
        }
        try checkpoint?("committed")
        journal.phase = "completed"
        try JSONEncoder().encode(journal).write(to: journalURL, options: .atomic)
        try library.syncDirectory(journalRoot)
        // Empty staging directories are harmless and retain the operation identity for diagnostics.
        items = try items.map { try library.item(id: $0.id) ?? $0 }
        return items
    }

    private struct RestoreCommit: Codable { var snapshotID: String; var itemIDs: [String] }

    private func rewriteDocumentTree(_ root: URL, map: [String: String], hashMap: inout [String: String]) throws {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return }
        let files = enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "json" }.sorted { $0.path < $1.path }
        for file in files {
            let old = try Data(contentsOf: file)
            let oldHash = try LibraryStore.sha256(of: file)
            let data = try ArchiveIdentity.rewrite(old, map: map)
            if old == data { continue }
            try data.write(to: file, options: .atomic)
            let newHash = try LibraryStore.sha256(of: file)
            hashMap[oldHash] = newHash
            // Version filenames embed their content hash; keep their name truthful after identity remapping.
            if file.deletingLastPathComponent().lastPathComponent == "revisions", file.lastPathComponent.contains(oldHash) {
                let target = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent.replacingOccurrences(of: oldHash, with: newHash))
                try fm.moveItem(at: file, to: target)
            }
        }
    }

    private func suspendRestoredWork(_ bytes: Data, collection: String) throws -> Data {
        if InterpretationRecordValidation.collections.contains(collection) {
            return try InterpretationRecordValidation.suspend(bytes, collection: collection)
        }
        guard var object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any] else { return bytes }
        if collection == "classrooms" {
            if !["ended", "draft"].contains(object["state"] as? String ?? "") { object["state"] = "interrupted" }
            object["translationUserPaused"] = true
        }
        func freeze(_ value: Any) -> Any {
            if var dict = value as? [String: Any] {
                for (key, child) in dict { dict[key] = freeze(child) }
                if ["running", "streaming", "queued"].contains(dict["status"] as? String ?? "") { dict["status"] = "needsAttention"; dict["errorCode"] = "restoredRequestOutcomeUnknown" }
                if ["preparing", "running", "synthesizing", "cancelling"].contains(dict["state"] as? String ?? "") { dict["state"] = "interrupted"; dict["errorCode"] = "restoredRequestOutcomeUnknown" }
                if dict["historical"] != nil { dict["historical"] = true }
                return dict
            }
            if let list = value as? [Any] { return list.map(freeze) }
            return value
        }
        if collection == "cloud-state" { object["translationUserPaused"] = true }
        if collection == "cloud-state" || collection.hasPrefix("assistant-") || collection.hasPrefix("document-translation") { object = freeze(object) as! [String: Any] }
        return try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    }
}

/// Rewrites structured identities and app links while preserving arbitrary prose (including UUIDs).
private enum ArchiveIdentity {
    static func identityField(_ field: String) -> Bool {
        if InterpretationRecordValidation.opaqueFields.contains(field) { return false }
        return field == "id" || field.hasSuffix("ID") || field.hasSuffix("IDs") || ["completedChunkIDs", "missingChunkIDs"].contains(field)
    }
    static func collect(_ value: Any, field: String = "", into map: inout [String: String]) {
        if let object = value as? [String: Any] { for (key, child) in object { collect(child, field: key, into: &map) } }
        else if let array = value as? [Any] { for child in array { collect(child, field: field, into: &map) } }
        else if let string = value as? String, identityField(field) {
            for token in string.components(separatedBy: CharacterSet(charactersIn: "0123456789abcdefABCDEF-").inverted) where UUID(uuidString: token) != nil {
                if map[token] == nil { map[token] = UUID().uuidString }
            }
        }
    }
    static func replace(_ string: String, map: [String: String]) -> String {
        map.reduce(string) { $0.replacingOccurrences(of: $1.key, with: $1.value, options: .caseInsensitive) }
    }
    static func links(_ text: String, map: [String: String]) -> String {
        var result = text
        for scheme in ["uway-pdf://", "ulecture-document://", "ulecture://document/"] {
            for (old, new) in map { result = result.replacingOccurrences(of: scheme + old, with: scheme + new, options: .caseInsensitive) }
        }
        return result
    }
    static func rewriteTextFile(_ file: URL, map: [String: String]) throws {
        let bytes = try Data(contentsOf: file)
        guard let string = String(data: bytes, encoding: .utf8) else { return }
        let next = links(string, map: map)
        if next != string { try Data(next.utf8).write(to: file, options: .atomic) }
    }
    static func rewrite(_ data: Data, map: [String: String], hashes: [String: String] = [:]) throws -> Data {
        func visit(_ value: Any, field: String = "") throws -> Any {
            if let string = value as? String {
                if InterpretationRecordValidation.opaqueFields.contains(field) { return string }
                if identityField(field) || ["relativePath", "resource"].contains(field) { return replace(string, map: map) }
                if field.lowercased().contains("hash"), let next = hashes[string] { return next }
                if field == "richText", let bytes = Data(base64Encoded: string) {
                    let archived = bytes.starts(with: Data("bplist".utf8))
                    let decoded: NSAttributedString? = archived ? (try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: bytes)) : (try? NSAttributedString(data: bytes, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil))
                    if let decoded {
                        let rich = NSMutableAttributedString(attributedString: decoded)
                        var changes = [(NSRange, String)]()
                        rich.enumerateAttribute(.link, in: NSRange(location: 0, length: rich.length)) { value, range, _ in
                            let original = (value as? URL)?.absoluteString ?? (value as? String)
                            if let original { let next = links(original, map: map); if original != next { changes.append((range, next)) } }
                        }
                        for (range, value) in changes { rich.addAttribute(.link, value: value, range: range) }
                        if !changes.isEmpty { return try NSKeyedArchiver.archivedData(withRootObject: rich, requiringSecureCoding: true).base64EncodedString() }
                    }
                }
                return links(string, map: map)
            }
            if let object = value as? [String: Any] {
                var result = [String: Any]()
                for (key, child) in object { result[UUID(uuidString: key) == nil ? key : replace(key, map: map)] = try visit(child, field: key) }
                return result
            }
            if let array = value as? [Any] { return try array.map { try visit($0, field: field) } }
            return value
        }
        return try JSONSerialization.data(withJSONObject: visit(JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])), options: [.sortedKeys, .fragmentsAllowed])
    }
}
