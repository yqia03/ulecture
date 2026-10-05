import Foundation

struct DiscoveredTranscriptSession {
    let session: WorkspaceItem
    let records: [PortableRecord]
    let directoryURL: URL
    let savedAt: Date
    let catalogLibraryID: String?
}

struct TranscriptRecoveryIssue: Codable {
    let relativePath: String
    let reason: String
}

struct TranscriptDiscovery {
    var sessions: [DiscoveredTranscriptSession] = []
    var issues: [TranscriptRecoveryIssue] = []
}

struct TranscriptRecoveryReceipt: Codable {
    let sessionID: String
    let originalCourseID: String?
    let originalParentID: String?
    let restoredParentID: String?
    let relativeDirectory: String
    let sourceSavedAt: Date
    let recoveredAt: Date
    let sourceCatalogLibraryID: String?
    let legacyUnverifiedCatalog: Bool
}

struct TranscriptRecoveryResult {
    var recoveredSessionIDs: [String] = []
    var issues: [TranscriptRecoveryIssue] = []
}

/// Session SQLite commits are authoritative; this reconstructs only missing catalog identities.
/// Neither discovery nor recovery writes to, renames, or deletes the source session databases.
enum TranscriptRecovery {
    static func discover(rootURL: URL, catalogLibraryID: String?) throws -> TranscriptDiscovery {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
        var result = TranscriptDiscovery()
        for bucket in try fm.contentsOfDirectory(at: rootURL, includingPropertiesForKeys: Array(keys)).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let name = bucket.lastPathComponent
            guard name == "Standalone" || UUID(uuidString: name) != nil else { continue }
            do {
                let attributes = try bucket.resourceValues(forKeys: keys)
                guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw LibraryError.message("转写课程目录不是普通目录。") }
                for directory in try fm.contentsOfDirectory(at: bucket, includingPropertiesForKeys: Array(keys)).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                    guard UUID(uuidString: directory.lastPathComponent) != nil else { continue }
                    let relative = name + "/" + directory.lastPathComponent
                    do {
                        let attributes = try directory.resourceValues(forKeys: keys)
                        guard attributes.isDirectory == true, attributes.isSymbolicLink != true else { throw LibraryError.message("会话目录不是普通目录。") }
                        let file = try LibraryStore.safeChild(relative + "/session.sqlite", under: rootURL)
                        guard fm.fileExists(atPath: file.path) else { continue } // Incomplete staging/empty directory is not a session.
                        let fileAttributes = try file.resourceValues(forKeys: keys)
                        guard fileAttributes.isRegularFile == true, fileAttributes.isSymbolicLink != true else { throw LibraryError.message("会话数据库不是普通文件。") }
                        result.sessions.append(try read(file, directory: directory, bucket: name, catalogLibraryID: catalogLibraryID))
                    } catch { result.issues.append(.init(relativePath: relative, reason: error.localizedDescription)) }
                }
            } catch { result.issues.append(.init(relativePath: name, reason: error.localizedDescription)) }
        }
        let duplicates = Dictionary(grouping: result.sessions, by: { $0.session.id.lowercased() }).filter { $0.value.count > 1 }
        for group in duplicates.values {
            for value in group { result.issues.append(.init(relativePath: relativeDirectory(value.directoryURL), reason: "同一会话标识存在多个数据库；保留全部原件，等待选择恢复来源。")) }
        }
        result.sessions.removeAll { duplicates[$0.session.id.lowercased()] != nil }
        return result
    }

    private static func read(_ url: URL, directory: URL, bucket: String, catalogLibraryID: String?) throws -> DiscoveredTranscriptSession {
        let db = try SQLiteDatabase(url: url, readOnly: true)
        try db.execute("BEGIN")
        defer { try? db.execute("ROLLBACK") }
        guard try db.rows("PRAGMA user_version").first?["user_version"] == "1",
              try db.rows("PRAGMA quick_check").first?.values.first == "ok" else { throw LibraryError.message("会话数据库版本或完整性检查未通过。") }
        var values: [String: String] = [:]
        for row in try db.rows("SELECT key,value FROM metadata") {
            guard let key = row["key"], let value = row["value"], values[key] == nil else { throw LibraryError.message("会话元数据损坏。") }
            values[key] = value
        }
        guard let json = values["session"], let saved = values["saved_at"].flatMap(Double.init), saved.isFinite else { throw LibraryError.message("会话数据库尚未完成首次保存。") }
        let sourceCatalogID = values["catalog_library_id"]
        guard sourceCatalogID == nil || UUID(uuidString: sourceCatalogID!) != nil,
              sourceCatalogID == nil || catalogLibraryID == nil || sourceCatalogID == catalogLibraryID else { throw LibraryError.message("此会话属于另一资料库，未自动导入。") }
        let session = try JSONDecoder().decode(WorkspaceItem.self, from: Data(json.utf8))
        guard session.kind == .classroom, UUID(uuidString: session.id) == UUID(uuidString: directory.lastPathComponent),
              session.courseID == nil || UUID(uuidString: session.courseID!) != nil,
              session.parentID == nil || UUID(uuidString: session.parentID!) != nil,
              session.parentID != session.id,
              bucket == "Standalone" || UUID(uuidString: session.courseID ?? "") == UUID(uuidString: bucket) else { throw LibraryError.message("会话路径与稳定标识不一致。") }
        let records = try db.rows("SELECT collection,id,owner_id,json FROM records ORDER BY rowid").map { row -> PortableRecord in
            guard let collection = row["collection"], let id = row["id"], let owner = row["owner_id"], let json = row["json"], owner == session.id,
                  !collection.isEmpty, collection.count <= 64, collection.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
                  !["credentials", "secrets", "keychain", "tokens", "api-keys", "settings", "filesystem-journals", "session-document-links"].contains(collection.lowercased()),
                  !id.isEmpty else { throw LibraryError.message("会话包含无效或其他所有者记录。") }
            _ = try JSONSerialization.jsonObject(with: Data(json.utf8), options: [.fragmentsAllowed])
            return PortableRecord(collection: collection, id: id, ownerID: owner, json: json)
        }
        for record in records where record.collection == "session-attachment-metadata" {
            let asset = try JSONDecoder().decode(ManagedAttachment.self, from: Data(record.json.utf8))
            guard UUID(uuidString: asset.id) != nil, asset.id == record.id, asset.ownerID == session.id,
                  asset.byteCount >= 0, asset.sha256.count == 64, asset.sha256.allSatisfy(\.isHexDigit) else { throw LibraryError.message("会话附件元数据无效。") }
            _ = try LibraryStore.safeChild(asset.relativePath, under: directory)
        }
        for record in records where record.collection == "session-attachments" {
            let location = try JSONDecoder().decode(SessionAttachmentLocation.self, from: Data(record.json.utf8))
            guard UUID(uuidString: location.assetID) != nil, location.assetID == record.id, location.sessionID == session.id else { throw LibraryError.message("会话附件路径标识无效。") }
            _ = try LibraryStore.safeChild(location.relativePath, under: directory)
        }
        return DiscoveredTranscriptSession(session: session, records: records, directoryURL: directory, savedAt: Date(timeIntervalSince1970: saved), catalogLibraryID: sourceCatalogID)
    }

    /// Call while LibraryStore is restoringSessionSnapshot, before reconciling existing sessions.
    /// Per-session transactions prevent a malformed orphan from partially altering the catalog.
    static func restoreOrphans(in library: LibraryStore, discovery: TranscriptDiscovery) -> TranscriptRecoveryResult {
        var result = TranscriptRecoveryResult(issues: discovery.issues)
        for source in discovery.sessions {
            do {
                for pending in source.records where pending.collection == "workspace-restore-pending" {
                    struct PendingRestore: Decodable { let restoreTaskID: String }
                    let marker = try library.decode(PendingRestore.self, pending.json)
                    guard UUID(uuidString: marker.restoreTaskID) != nil,
                          !(try library.databaseRows("SELECT id FROM records WHERE collection='workspace-restores' AND id=?", [marker.restoreTaskID])).isEmpty else {
                        throw LibraryError.message("完整备份恢复尚未提交，请重试原恢复任务。")
                    }
                }
                if let existing = try library.item(id: source.session.id) {
                    guard existing.kind == .classroom else { throw LibraryError.message("会话标识与现有非课堂项目冲突。") }
                    continue
                }
                try library.withTransaction {
                    var session = source.session
                    if let courseID = session.courseID {
                        if let course = try library.item(id: courseID) {
                            guard course.kind == .course else { throw LibraryError.message("原课程标识与现有其他项目冲突。") }
                        } else {
                            try library.writeItem(WorkspaceItem(id: courseID, parentID: nil, courseID: courseID, classroomID: nil, kind: .course,
                                title: "已恢复课程 " + String(courseID.prefix(8)), createdAt: session.createdAt, updatedAt: Date()))
                        }
                        let parent = try session.parentID.flatMap { try library.item(id: $0) }
                        if parent == nil || parent!.deletedAt != nil || ![WorkspaceKind.course, .folder].contains(parent!.kind) || (parent!.id != courseID && parent!.courseID != courseID) { session.parentID = courseID }
                    } else { session.parentID = nil }
                    try library.writeItem(session)
                    for record in source.records { try library.writePortableRecord(record) }
                    for record in source.records where record.collection == "session-attachment-metadata" {
                        let asset = try library.decode(ManagedAttachment.self, record.json)
                        if let existing = try library.attachment(id: asset.id) {
                            guard existing.ownerID == asset.ownerID, existing.sha256 == asset.sha256, existing.relativePath == asset.relativePath else { throw LibraryError.message("恢复附件标识与现有附件冲突，未覆盖。") }
                        } else { try library.writeAttachment(asset) }
                    }
                    let receipt = TranscriptRecoveryReceipt(sessionID: session.id, originalCourseID: source.session.courseID, originalParentID: source.session.parentID,
                        restoredParentID: session.parentID, relativeDirectory: relativeDirectory(source.directoryURL), sourceSavedAt: source.savedAt, recoveredAt: Date(),
                        sourceCatalogLibraryID: source.catalogLibraryID, legacyUnverifiedCatalog: source.catalogLibraryID == nil)
                    // Catalog-only audit is excluded from authoritative session-record reconciliation.
                    try library.putRecord(collection: "transcript-recovery", id: session.id, ownerID: session.id, value: receipt)
                }
                result.recoveredSessionIDs.append(source.session.id)
            } catch { result.issues.append(.init(relativePath: relativeDirectory(source.directoryURL), reason: error.localizedDescription)) }
        }
        return result
    }

    private static func relativeDirectory(_ url: URL) -> String { url.deletingLastPathComponent().lastPathComponent + "/" + url.lastPathComponent }
}
