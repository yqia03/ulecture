import Foundation
import Darwin
import CryptoKit

enum TranscriptTextKind: String, CaseIterable, Sendable {
    case source, bilingual
    var filename: String { self == .source ? "transcript.txt" : "transcript-bilingual.txt" }
}

private struct TranscriptPublication: Codable {
    var version = 2
    var generation = UUID().uuidString
    var hashes: [String: String]
    var previousHashes: [String: String]? = nil
    var published = false
}

/// Durable per-session storage independent of project files. No API credentials or model resources enter this store.
final class TranscriptStore {
    let rootURL: URL
    let catalogLibraryID: String?
    private let mutex = NSRecursiveLock()
    private var connections: [String: SQLiteDatabase] = [:]
    private var discoveredLocations: [String: URL] = [:]
    private let fm = FileManager.default
    /// Fault-injection seam at the atomic publication/directory-durability boundary.
    var onTextFileWillSynchronize: (() throws -> Void)?
    /// Test checkpoints are after durable boundaries, allowing real process-death checks.
    var onPublicationCheckpoint: ((String) throws -> Void)?

    init(rootURL: URL, catalogLibraryID: String? = nil) throws {
        guard catalogLibraryID == nil || UUID(uuidString: catalogLibraryID!) != nil else { throw LibraryError.message("资料库标识无效。") }
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.catalogLibraryID = catalogLibraryID
        try fm.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        try WorkspaceCatalog.checkWritable(self.rootURL)
    }

    static func defaultRoot() throws -> URL {
        try FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("ULecture/Transcripts", isDirectory: true)
    }

    func directory(for session: WorkspaceItem) throws -> URL {
        mutex.lock(); defer { mutex.unlock() }
        guard session.kind == .classroom, UUID(uuidString: session.id) != nil,
              session.courseID == nil || UUID(uuidString: session.courseID!) != nil else { throw LibraryError.message("转写会话标识无效。") }
        if let location = discoveredLocations[session.id] {
            return try LibraryStore.safeChild(location.deletingLastPathComponent().lastPathComponent + "/" + location.lastPathComponent, under: rootURL)
        }
        // A standalone session may later be associated with a course. Its physical identity remains stable.
        let standalone = try LibraryStore.safeChild("Standalone/" + session.id, under: rootURL)
        if fm.fileExists(atPath: standalone.appendingPathComponent("session.sqlite").path) { return standalone }
        return try LibraryStore.safeChild((session.courseID ?? "Standalone") + "/" + session.id, under: rootURL)
    }

    /// Resolving either user-facing path never writes.
    func fileURL(for session: WorkspaceItem, kind: TranscriptTextKind = .source) throws -> URL {
        try LibraryStore.safeChild(kind.filename, under: directory(for: session))
    }

    @discardableResult
    func synchronizeTextFile(for session: WorkspaceItem) throws -> URL {
        try synchronizeTextFiles(for: session)[.source]!
    }

    /// Always repairs the pair from one committed session snapshot, never from UI drafts.
    @discardableResult
    func synchronizeTextFiles(for session: WorkspaceItem) throws -> [TranscriptTextKind: URL] {
        mutex.lock(); defer { mutex.unlock() }
        guard let records = try records(for: session), let db = try database(for: session, create: false) else {
            throw LibraryError.message("此会话尚无已保存的转写数据。")
        }
        let savedSession = try committedSession(for: session) ?? session
        let texts = try TranscriptTextFormatter.sessionFiles(savedSession, records: records)
        let old = try publication(db)
        let hashes = Dictionary(uniqueKeysWithValues: texts.map { ($0.key.filename, Self.hash($0.value)) })
        var receipt = old?.hashes == hashes ? old! : TranscriptPublication(hashes: hashes, previousHashes: old?.hashes)
        receipt.published = false
        let prepared = try preparePair(texts, session: session, previous: old)
        defer { discard(prepared) }
        // The snapshot already exists; record repair intent before publishing either path.
        try writePublication(receipt, db: db)
        try publishPair(prepared, session: session, receipt: receipt, db: db)
        return try Dictionary(uniqueKeysWithValues: TranscriptTextKind.allCases.map { ($0, try fileURL(for: session, kind: $0)) })
    }

    private static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    private func publication(_ db: SQLiteDatabase) throws -> TranscriptPublication? {
        guard let text = try db.rows("SELECT value FROM metadata WHERE key='text_publication'").first?["value"] else { return nil }
        let value = try JSONDecoder().decode(TranscriptPublication.self, from: Data(text.utf8))
        guard value.version == 2, UUID(uuidString: value.generation) != nil,
              Set(value.hashes.keys) == Set(TranscriptTextKind.allCases.map(\.filename)),
              value.hashes.values.allSatisfy({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) else {
            throw LibraryError.message("转写保存记录无效，原文件未覆盖。")
        }
        return value
    }
    private func writePublication(_ value: TranscriptPublication, db: SQLiteDatabase) throws {
        let json = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
        try db.execute("INSERT INTO metadata(key,value) VALUES('text_publication',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [json])
    }

    /// Unexpected existing bytes (including the old bilingual TXT) are immutable recovery assets.
    /// Content-addressed filenames make a crash before the format marker harmless and idempotent.
    private func preserve(_ data: Data, filename: String, directory: URL) throws {
        let root = try LibraryStore.safeChild("text-recovery", under: directory)
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        let target = try LibraryStore.safeChild(filename + "." + Self.hash(data) + ".txt", under: root)
        if fm.fileExists(atPath: target.path) {
            guard try Data(contentsOf: target) == data else { throw LibraryError.message("转写恢复副本校验失败，原文件未覆盖。") }
        } else {
            let temporary = root.appendingPathComponent(".transcript-" + UUID().uuidString + ".tmp")
            defer { try? fm.removeItem(at: temporary) }
            try data.write(to: temporary, options: .withoutOverwriting)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
            let handle = try FileHandle(forWritingTo: temporary)
            do { try handle.synchronize(); try handle.close() }
            catch { try? handle.close(); throw error }
            // Publish without overwriting a concurrently created recovery asset.
            if link(temporary.path, target.path) != 0 {
                guard errno == EEXIST, try Data(contentsOf: target) == data else { throw LibraryError.message("转写恢复副本保存失败，原文件未覆盖。") }
            }
        }
        let handle = try FileHandle(forWritingTo: target)
        defer { try? handle.close() }
        try handle.synchronize()
        try synchronizeDirectory(root)
        try synchronizeDirectory(directory)
    }

    private struct PreparedPair {
        var staged: [TranscriptTextKind: URL] = [:]
        var observedHashes: [TranscriptTextKind: String] = [:]
    }
    private func preparePair(_ texts: [TranscriptTextKind: Data], session: WorkspaceItem,
                             previous: TranscriptPublication?) throws -> PreparedPair {
        let directory = try directory(for: session)
        try WorkspaceCatalog.checkWritable(directory)
        var prepared = PreparedPair()
        do {
            for kind in TranscriptTextKind.allCases {
                let url = try fileURL(for: session, kind: kind), data = texts[kind]!
                if fm.fileExists(atPath: url.path) {
                    let attributes = try fm.attributesOfItem(atPath: url.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular else { throw LibraryError.message("转写 TXT 路径不是普通文件，未覆盖。") }
                    try WorkspaceCatalog.checkWritable(url)
                    let existing = try Data(contentsOf: url)
                    // A partially published pending generation is already recoverable from SQLite.
                    let existingHash = Self.hash(existing)
                    prepared.observedHashes[kind] = existingHash
                    if previous == nil || (existingHash != previous?.hashes[kind.filename] &&
                        (previous?.published == true || existingHash != previous?.previousHashes?[kind.filename])) {
                        try preserve(existing, filename: kind.filename, directory: directory)
                    }
                    if existing == data { continue }
                }
                let temporary = directory.appendingPathComponent(".transcript-" + UUID().uuidString + ".tmp")
                prepared.staged[kind] = temporary
                try data.write(to: temporary, options: .withoutOverwriting)
                try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
                let handle = try FileHandle(forWritingTo: temporary)
                do { try handle.synchronize(); try handle.close() }
                catch { try? handle.close(); throw error }
            }
            return prepared
        } catch { discard(prepared); throw error }
    }
    private func discard(_ prepared: PreparedPair) { for url in prepared.staged.values { try? fm.removeItem(at: url) } }
    private func synchronizeDirectory(_ url: URL) throws {
        let descriptor = open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard descriptor >= 0 else { throw LibraryError.message("无法确认转写 TXT 已保存，请重试。") }
        defer { close(descriptor) }
        guard fsync(descriptor) == 0 else { throw LibraryError.message("转写 TXT 落盘失败，请重试保存。") }
    }
    private func publishPair(_ prepared: PreparedPair, session: WorkspaceItem,
                             receipt: TranscriptPublication, db: SQLiteDatabase) throws {
        for kind in TranscriptTextKind.allCases {
            let url = try fileURL(for: session, kind: kind)
            // A document editor can replace either path while SQLite commits.
            // Detect edits made since staging and retain them before a retry.
            let current = fm.fileExists(atPath: url.path) ? try Data(contentsOf: url) : nil
            guard current.map(Self.hash) == prepared.observedHashes[kind] else {
                if let current { try preserve(current, filename: kind.filename, directory: directory(for: session)) }
                throw LibraryError.message("转写 TXT 保存未完成，请重试保存。")
            }
            if let temporary = prepared.staged[kind] {
                guard rename(temporary.path, url.path) == 0 else { throw LibraryError.message("转写 TXT 保存未完成，请重试保存。") }
            }
            try onPublicationCheckpoint?("published-" + kind.rawValue)
        }
        // Equal-content retry still crosses the durability boundary.
        try onTextFileWillSynchronize?()
        try synchronizeDirectory(directory(for: session))
        try onPublicationCheckpoint?("directory-synchronized")
        var complete = receipt; complete.published = true
        try writePublication(complete, db: db)
        try onPublicationCheckpoint?("receipt-published")
        // A process can die after fsync but before rename. Only this store's UUID
        // staging names are disposable, and only after the pair has been repaired.
        let directory = try directory(for: session)
        try cleanStaging(in: directory)
        let recovery = directory.appendingPathComponent("text-recovery")
        if fm.fileExists(atPath: recovery.path) { try cleanStaging(in: recovery) }
    }
    private func cleanStaging(in directory: URL) throws {
        for file in try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) {
            let name = file.lastPathComponent
            guard name.hasPrefix(".transcript-"), name.hasSuffix(".tmp"),
                  UUID(uuidString: String(name.dropFirst(12).dropLast(4))) != nil else { continue }
            let attributes = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if attributes.isRegularFile == true, attributes.isSymbolicLink != true { try fm.removeItem(at: file) }
        }
    }

    /// Discovery is read-only. Adopt only verified, unambiguous locations so a later association
    /// change cannot make an existing standalone database appear to be a new empty session.
    func useDiscoveredLocations(_ discovery: TranscriptDiscovery) {
        mutex.lock(); defer { mutex.unlock() }
        for value in discovery.sessions { discoveredLocations[value.session.id] = value.directoryURL }
    }

    func discoveredSessions() throws -> TranscriptDiscovery {
        mutex.lock(); defer { mutex.unlock() }
        return try TranscriptRecovery.discover(rootURL: rootURL, catalogLibraryID: catalogLibraryID)
    }

    private func database(for session: WorkspaceItem, create: Bool) throws -> SQLiteDatabase? {
        let directory = try directory(for: session)
        let url = directory.appendingPathComponent("session.sqlite")
        if connections[session.id] != nil && !fm.fileExists(atPath: url.path) {
            connections[session.id] = nil
            throw LibraryError.message("会话数据库已在外部删除或移动，内容尚未保存。")
        }
        if !create && !fm.fileExists(atPath: url.path) { return nil }
        if fm.fileExists(atPath: url.path), connections[session.id] == nil {
            // Check ownership before opening a writable connection (which may change journal mode).
            let inspected = try SQLiteDatabase(url: url, readOnly: true)
            let version = Int(try inspected.rows("PRAGMA user_version").first?["user_version"] ?? "0") ?? 0
            guard version <= 1 else { throw LibraryError.message("转写格式较新，未改写。") }
            if version == 1 { try checkIdentity(inspected, sessionID: session.id) }
        }
        guard fm.fileExists(atPath: rootURL.path) else { throw LibraryError.message("转写保存位置未连接。") }
        try WorkspaceCatalog.checkWritable(rootURL)
        try fm.createDirectory(at: directory, withIntermediateDirectories: true)
        try WorkspaceCatalog.checkWritable(directory)
        // Checking every write catches ejected/read-only roots even if a connection remains open.
        if let value = connections[session.id] { try checkIdentity(value, sessionID: session.id); return value }
        let db = try SQLiteDatabase(url: url, readOnly: false)
        let version = Int(try db.rows("PRAGMA user_version").first?["user_version"] ?? "0") ?? 0
        guard version <= 1 else { throw LibraryError.message("转写格式较新，未改写。") }
        if version == 0 {
            guard try db.rows("SELECT name FROM sqlite_master WHERE type='table'").isEmpty else { throw LibraryError.message("未知转写数据库，未改写。") }
            try db.execute("CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
            try db.execute("CREATE TABLE records(collection TEXT NOT NULL,id TEXT NOT NULL,owner_id TEXT NOT NULL,json TEXT NOT NULL,PRIMARY KEY(collection,id))")
            try db.execute("PRAGMA user_version=1")
        }
        let integrity = try db.rows("PRAGMA quick_check").first?.values.first
        guard integrity == "ok" else { throw LibraryError.message("转写数据库完整性检查失败。") }
        connections[session.id] = db
        return db
    }

    private func checkIdentity(_ database: SQLiteDatabase, sessionID: String) throws {
        if let catalogLibraryID, let existing = try database.rows("SELECT value FROM metadata WHERE key='catalog_library_id'").first?["value"] {
            guard existing == catalogLibraryID else { throw LibraryError.message("此转写属于另一资料库，未改写。") }
        }
        if let json = try database.rows("SELECT value FROM metadata WHERE key='session'").first?["value"] {
            let session = try JSONDecoder().decode(WorkspaceItem.self, from: Data(json.utf8))
            guard session.kind == .classroom, session.id == sessionID else { throw LibraryError.message("会话数据库的稳定标识不匹配，未改写。") }
        }
    }

    /// Session snapshots are committed before the corresponding catalog transaction is acknowledged.
    /// On process death between commits the session is authoritative and can rebuild its catalog records.
    func persist(session: WorkspaceItem, records: [PortableRecord]) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard records.allSatisfy({ $0.ownerID == session.id }) else { throw LibraryError.message("转写快照含其他会话记录。") }
        let texts = try TranscriptTextFormatter.sessionFiles(session, records: records)
        guard let db = try database(for: session, create: true) else { throw LibraryError.message("转写保存位置无法打开。") }
        let previous = try publication(db)
        guard previous?.published != false else { throw LibraryError.message("转写保存尚未恢复，请重试保存。") }
        let staged = try preparePair(texts, session: session, previous: previous)
        defer { discard(staged) }
        let receipt = TranscriptPublication(hashes: Dictionary(uniqueKeysWithValues: texts.map { ($0.key.filename, Self.hash($0.value)) }), previousHashes: previous?.hashes)
        try db.execute("BEGIN IMMEDIATE")
        do {
            let item = String(decoding: try JSONEncoder().encode(session), as: UTF8.self)
            if let catalogLibraryID {
                let existing = try db.rows("SELECT value FROM metadata WHERE key='catalog_library_id'").first?["value"]
                guard existing == nil || existing == catalogLibraryID else { throw LibraryError.message("此转写属于另一资料库，未改写。") }
                try db.execute("INSERT INTO metadata(key,value) VALUES('catalog_library_id',?) ON CONFLICT(key) DO NOTHING", [catalogLibraryID])
            }
            try db.execute("INSERT INTO metadata(key,value) VALUES('session',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [item])
            try db.execute("INSERT INTO metadata(key,value) VALUES('saved_at',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value", [String(Date().timeIntervalSince1970)])
            let incoming = Set(records.map { $0.collection + ":" + $0.id })
            for old in try db.rows("SELECT collection,id FROM records") where !incoming.contains(old["collection"]! + ":" + old["id"]!) {
                try db.execute("DELETE FROM records WHERE collection=? AND id=?", [old["collection"], old["id"]])
            }
            for record in records {
                guard record.ownerID == session.id else { throw LibraryError.message("转写快照含其他会话记录。") }
                try db.execute("INSERT INTO records(collection,id,owner_id,json) VALUES(?,?,?,?) ON CONFLICT(collection,id) DO UPDATE SET owner_id=excluded.owner_id,json=excluded.json WHERE records.json<>excluded.json", [record.collection,record.id,record.ownerID,record.json])
            }
            try writePublication(receipt, db: db)
            try db.execute("COMMIT")
        } catch { try? db.execute("ROLLBACK"); throw error }
        try onPublicationCheckpoint?("snapshot-committed")
        do { try publishPair(staged, session: session, receipt: receipt, db: db) }
        catch { throw LibraryError.message("会话记录已保存，但两份 TXT 尚未全部保存。请重试保存。") }
    }

    func records(for session: WorkspaceItem) throws -> [PortableRecord]? {
        mutex.lock(); defer { mutex.unlock() }
        guard let db = try database(for: session, create: false) else { return nil }
        return try db.rows("SELECT collection,id,owner_id,json FROM records ORDER BY rowid").map { row in
            guard let collection = row["collection"], let id = row["id"], let owner = row["owner_id"], let json = row["json"], owner == session.id else { throw LibraryError.message("会话记录的所有者不匹配。") }
            return PortableRecord(collection: collection, id: id, ownerID: owner, json: json)
        }
    }

    func committedSession(for session: WorkspaceItem) throws -> WorkspaceItem? {
        mutex.lock(); defer { mutex.unlock() }
        guard let db = try database(for: session, create: false),
              let json = try db.rows("SELECT value FROM metadata WHERE key='session'").first?["value"] else { return nil }
        return try JSONDecoder().decode(WorkspaceItem.self, from: Data(json.utf8))
    }

    func snapshot(session: WorkspaceItem, to destination: URL, textFileURL: URL? = nil) throws {
        mutex.lock(); defer { mutex.unlock() }
        guard let db = try database(for: session, create: false) else { throw LibraryError.message("此会话尚无转写数据。") }
        try db.snapshot(to: destination)
        if let textFileURL, let records = try records(for: session) {
            let targetDirectory = textFileURL.deletingLastPathComponent()
            let texts = try TranscriptTextFormatter.sessionFiles(committedSession(for: session) ?? session, records: records)
            for kind in TranscriptTextKind.allCases {
                let url = try LibraryStore.safeChild(kind.filename, under: targetDirectory)
                try texts[kind]!.write(to: url, options: .withoutOverwriting)
                let handle = try FileHandle(forWritingTo: url)
                do { try handle.synchronize(); try handle.close() }
                catch { try? handle.close(); throw error }
            }
            try synchronizeDirectory(targetDirectory)
        }
    }
}
