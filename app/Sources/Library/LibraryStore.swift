import Foundation
import PDFKit
import AVFoundation
import CryptoKit
import Darwin

/// One local library. Database access serializes on a recursive lock; immutable attachment preparation runs outside it.
/// Successful returns are durable SQLite commits (synchronous=FULL), never optimistic save receipts.
final class LibraryStore {
    static let schemaVersion = 1
    let rootURL: URL
    private(set) var isReadOnly: Bool
    private(set) var libraryID: String = ""
    private var storedRecoveryWarnings: [String] = []
    private(set) var recoveryWarnings: [String] {
        get { locked { storedRecoveryWarnings } }
        set { locked { storedRecoveryWarnings = newValue } }
    }
    private var database: SQLiteDatabase!
    private var lockFD: Int32 = -1
    private let mutex = NSRecursiveLock()
    private var transactionDepth = 0
    private var storedTranscriptStore: TranscriptStore?
    private(set) var transcriptStore: TranscriptStore? {
        get { locked { storedTranscriptStore } }
        set { locked { storedTranscriptStore = newValue } }
    }
    private var dirtySessionIDs = Set<String>()
    private var restoringSessionSnapshot = false
    /// A failed outer transaction may have committed a newer independent session.
    /// Repair it before any later mutation can serialize an older catalog snapshot.
    private var sessionSavesNeedingReconciliation: [String: WorkspaceItem] = [:]
    /// Used by fault-injection checks at the cross-store durability boundary.
    var onSessionPersisted: ((String) throws -> Void)?
    // Independent coders also serve attachment preparation outside the database lock.
    var encoder: JSONEncoder { JSONEncoder() }
    var decoder: JSONDecoder { JSONDecoder() }

    init(rootURL: URL, createIfMissing: Bool = true, readOnly: Bool = false) throws {
        self.rootURL = rootURL.standardizedFileURL.resolvingSymlinksInPath()
        self.isReadOnly = readOnly
        let fm = FileManager.default
        var directory: ObjCBool = false
        if !fm.fileExists(atPath: self.rootURL.path, isDirectory: &directory) {
            guard createIfMissing && !readOnly else { throw LibraryError.message("资料库目录不存在。") }
            try fm.createDirectory(at: self.rootURL, withIntermediateDirectories: true)
        } else if !directory.boolValue { throw LibraryError.message("请选择资料库文件夹。") }
        let dbURL = self.rootURL.appendingPathComponent("library.sqlite")
        let existed = fm.fileExists(atPath: dbURL.path)
        if !existed && (!createIfMissing || readOnly) { throw LibraryError.message("此目录没有资料库。") }
        if !readOnly {
            let lockURL = self.rootURL.appendingPathComponent(".writer.lock")
            lockFD = open(lockURL.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            if lockFD < 0 || flock(lockFD, LOCK_EX | LOCK_NB) != 0 {
                if lockFD >= 0 { close(lockFD); lockFD = -1 }
                guard existed else { throw LibraryError.message("资料库不可写或被另一个应用实例占用。") }
                self.isReadOnly = true
                recoveryWarnings.append("资料库已按只读方式打开：位置不可写或另一个应用实例正在使用。")
            }
        }
        do {
            // Inspect an existing database using a read-only connection before any WAL/schema mutation.
            database = try SQLiteDatabase(url: dbURL, readOnly: existed || isReadOnly)
            let version = Int(try database.rows("PRAGMA user_version").first?["user_version"] ?? "0") ?? 0
            guard version <= Self.schemaVersion else {
                throw LibraryError.message("资料库格式 \(version) 不受支持；请使用更新版本。原资料未修改。")
            }
            if version == 0 {
                let tables = try database.rows("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
                guard tables.isEmpty else { throw LibraryError.message("未知资料库格式；原资料未修改。") }
            }
            if !isReadOnly {
                do { try ensureWritable() }
                catch {
                    guard existed else { throw error }
                    isReadOnly = true
                    recoveryWarnings.append("资料库位置不可写，已只读打开；编辑不会显示为已保存。")
                }
                if !isReadOnly { database = nil; database = try SQLiteDatabase(url: dbURL, readOnly: false) }
            }
            if version == 0 {
                guard !isReadOnly else { throw LibraryError.message("此资料库尚未初始化，无法只读打开。") }
                // An unversioned, nonempty SQLite database is never treated as ours or overwritten.
                let tables = try database.rows("SELECT name FROM sqlite_master WHERE type='table' AND name NOT LIKE 'sqlite_%'")
                guard tables.isEmpty else { throw LibraryError.message("未知资料库格式；原资料未修改。") }
                try initializeSchema()
            }
            libraryID = try database.rows("SELECT value FROM metadata WHERE key='library_id'").first?["value"] ?? ""
            guard UUID(uuidString: libraryID) != nil else { throw LibraryError.message("资料库身份损坏，请保留原目录。") }
            let integrity = try database.rows("PRAGMA quick_check").first?.values.first
            guard integrity == "ok" else { throw LibraryError.message("资料库完整性检查失败；请保留原目录。") }
            if !isReadOnly {
                try fm.createDirectory(at: self.rootURL.appendingPathComponent("attachments"), withIntermediateDirectories: true)
                try fm.createDirectory(at: self.rootURL.appendingPathComponent("staging"), withIntermediateDirectories: true)
                try recoverInterruptedClassrooms()
            }
            try inspectAttachments()
        } catch {
            database = nil
            if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
            throw error
        }
    }

    deinit {
        database = nil
        if lockFD >= 0 { flock(lockFD, LOCK_UN); close(lockFD) }
    }

    private func initializeSchema() throws {
        try database.execute("BEGIN IMMEDIATE")
        do {
            try database.execute("CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
            try database.execute("CREATE TABLE items(id TEXT PRIMARY KEY,parent_id TEXT REFERENCES items(id),kind TEXT NOT NULL,json TEXT NOT NULL)")
            try database.execute("CREATE INDEX items_parent ON items(parent_id)")
            try database.execute("CREATE TABLE records(collection TEXT NOT NULL,id TEXT NOT NULL,owner_id TEXT NOT NULL REFERENCES items(id),json TEXT NOT NULL,PRIMARY KEY(collection,id))")
            try database.execute("CREATE INDEX records_owner ON records(collection,owner_id)")
            try database.execute("CREATE TABLE attachments(id TEXT PRIMARY KEY,owner_id TEXT NOT NULL REFERENCES items(id),json TEXT NOT NULL)")
            try database.execute("INSERT INTO metadata(key,value) VALUES('library_id',?)", [UUID().uuidString])
            try database.execute("PRAGMA user_version=1")
            try database.execute("COMMIT")
        } catch { try? database.execute("ROLLBACK"); throw error }
    }

    private func locked<T>(_ operation: () throws -> T) rethrows -> T {
        mutex.lock(); defer { mutex.unlock() }; return try operation()
    }

    func withTransaction<T>(_ operation: () throws -> T) throws -> T {
        try locked {
            try ensureWritable()
            if transactionDepth == 0, !restoringSessionSnapshot { try reconcileInterruptedSessionSaves() }
            let depth = transactionDepth
            let priorDirtySessions = dirtySessionIDs
            var attemptedSessions: [WorkspaceItem] = []
            let savepoint = "nested_\(depth)"
            try database.execute(depth == 0 ? "BEGIN IMMEDIATE" : "SAVEPOINT \(savepoint)")
            transactionDepth += 1
            do {
                let value = try operation()
                try ensureWritable()
                if depth == 0, !restoringSessionSnapshot, let transcriptStore {
                    for id in dirtySessionIDs {
                        if let session = try item(id: id), session.kind == .classroom {
                            attemptedSessions.append(session)
                            try transcriptStore.persist(session: session, records: sessionRecords(id))
                            try onSessionPersisted?(id)
                        }
                    }
                }
                try database.execute(depth == 0 ? "COMMIT" : "RELEASE SAVEPOINT \(savepoint)")
                transactionDepth -= 1
                if depth == 0 { dirtySessionIDs.removeAll() }
                return value
            } catch {
                if depth == 0 { try? database.execute("ROLLBACK") }
                else { try? database.execute("ROLLBACK TO SAVEPOINT \(savepoint)"); try? database.execute("RELEASE SAVEPOINT \(savepoint)") }
                transactionDepth -= 1
                dirtySessionIDs = priorDirtySessions
                for session in attemptedSessions { sessionSavesNeedingReconciliation[session.id] = session }
                throw error
            }
        }
    }

    private func reconcileInterruptedSessionSaves() throws {
        guard let store = transcriptStore, !sessionSavesNeedingReconciliation.isEmpty else { return }
        restoringSessionSnapshot = true
        defer { restoringSessionSnapshot = false }
        for attempted in Array(sessionSavesNeedingReconciliation.values) {
            guard let session = try store.committedSession(for: attempted), let records = try store.records(for: session) else {
                sessionSavesNeedingReconciliation[attempted.id] = nil
                continue
            }
            try store.synchronizeTextFiles(for: session)
            try withTransaction {
                try writeItem(session)
                try database.execute("DELETE FROM records WHERE owner_id=? AND collection NOT IN ('filesystem-journals','session-document-links','transcript-recovery')", [session.id])
                for record in records { try writePortableRecord(record) }
                for record in records where record.collection == "session-attachment-metadata" {
                    let asset = try decode(ManagedAttachment.self, record.json)
                    if try attachment(id: asset.id) == nil { try writeAttachment(asset) }
                }
            }
            sessionSavesNeedingReconciliation[attempted.id] = nil
        }
    }

    func checkWritable() throws { try locked { try ensureWritable() } }
    func snapshotDatabase(to url: URL) throws { try locked { try database.snapshot(to: url) } }

    /// Opt in only for the new workspace catalog. Legacy libraries remain untouched until explicit migration.
    func configureTranscriptStorage(rootURL: URL) throws {
        try locked {
            try ensureWritable()
            let store = try TranscriptStore(rootURL: rootURL, catalogLibraryID: libraryID)
            restoringSessionSnapshot = true
            defer { restoringSessionSnapshot = false }
            let discovery = try store.discoveredSessions()
            store.useDiscoveredLocations(discovery)
            let recovery = TranscriptRecovery.restoreOrphans(in: self, discovery: discovery)
            recoveryWarnings += recovery.issues.map { $0.relativePath + ": " + $0.reason }
            // Reconcile a durable session commit left behind by a process death before the catalog commit.
            for session in try items(includeDeleted: true) where session.kind == .classroom {
                if let records = try store.records(for: session) {
                    try withTransaction {
                        try database.execute("DELETE FROM records WHERE owner_id=? AND collection NOT IN ('filesystem-journals','session-document-links','transcript-recovery')", [session.id])
                        for record in records { try writePortableRecord(record) }
                        for record in records where record.collection == "session-attachment-metadata" {
                            let asset = try decode(ManagedAttachment.self, record.json)
                            if try attachment(id: asset.id) == nil { try writeAttachment(asset) }
                        }
                    }
                    try store.synchronizeTextFile(for: session)
                } else { try store.persist(session: session, records: sessionRecords(session.id)) }
            }
            transcriptStore = store
            restoringSessionSnapshot = false
            try migrateLegacySessionAttachments()
            try recoverInterruptedClassrooms()
        }
    }
    private func sessionRecords(_ id: String) throws -> [PortableRecord] {
        try database.rows("SELECT collection,id,owner_id,json FROM records WHERE owner_id=? AND collection NOT IN ('filesystem-journals','session-document-links','transcript-recovery')", [id]).map {
            PortableRecord(collection: $0["collection"]!, id: $0["id"]!, ownerID: $0["owner_id"]!, json: $0["json"]!)
        }
    }
    func moveTranscriptStorage(to newRoot: URL) throws {
        // Keep the durable root pointer and the in-process writer switch under
        // one catalog lock; no save may land in the old root between them.
        try locked {
            try ensureWritable(); try reconcileInterruptedSessionSaves()
            guard let current = transcriptStore else { try configureTranscriptStorage(rootURL: newRoot); return }
            let replacement = try TranscriptRelocation(library: self, current: current).move(to: newRoot)
            guard transcriptStore === current else { throw LibraryError.message("转写位置已被其他操作更改。") }
            transcriptStore = replacement
        }
    }
    func savedTranscriptRoot() throws -> URL? {
        let file = rootURL.appendingPathComponent("transcript-location.json")
        guard FileManager.default.fileExists(atPath: file.path) else { return nil }
        return URL(fileURLWithPath: try JSONDecoder().decode(TranscriptRootLocation.self, from: Data(contentsOf: file)).rootPath)
    }
    private func ensureWritable() throws {
        guard !isReadOnly else { throw LibraryError.message("资料库以只读方式打开，内容尚未保存。") }
        let fm = FileManager.default
        guard fm.fileExists(atPath: rootURL.path), fm.isWritableFile(atPath: rootURL.path) else {
            throw LibraryError.message("资料库目录失联或不可写，内容尚未保存。")
        }
        let attributes = try fm.attributesOfItem(atPath: rootURL.path)
        if let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o222 == 0 {
            throw LibraryError.message("资料库目录没有写入权限，内容尚未保存。")
        }
        let dbURL = rootURL.appendingPathComponent("library.sqlite")
        if fm.fileExists(atPath: dbURL.path) {
            guard fm.isWritableFile(atPath: dbURL.path) else { throw LibraryError.message("资料库数据库不可写，内容尚未保存。") }
            if let mode = try fm.attributesOfItem(atPath: dbURL.path)[.posixPermissions] as? NSNumber, mode.intValue & 0o222 == 0 {
                throw LibraryError.message("资料库数据库没有写入权限，内容尚未保存。")
            }
        }
    }

    func items(includeDeleted: Bool = false) throws -> [WorkspaceItem] {
        try locked {
            try database.rows("SELECT json FROM items ORDER BY rowid").map { try decode(WorkspaceItem.self, $0["json"]!) }
                .filter { includeDeleted || $0.deletedAt == nil }
        }
    }
    func item(id: String) throws -> WorkspaceItem? {
        try locked { try database.rows("SELECT json FROM items WHERE id=?", [id]).first.map { try decode(WorkspaceItem.self, $0["json"]!) } }
    }

    @discardableResult
    func createItem(kind: WorkspaceKind, title: String, parentID: String? = nil) throws -> WorkspaceItem {
        try withTransaction {
            guard kind != .pdf else { throw LibraryError.message("请通过导入 PDF 建立受管附件。") }
            let relation = try parentRelation(kind: kind, parentID: parentID)
            let id = UUID().uuidString
            let now = Date()
            let value = WorkspaceItem(id: id, parentID: parentID, courseID: kind == .course ? id : relation.course,
                classroomID: kind == .classroom ? id : relation.classroom, kind: kind,
                title: try checkedTitle(title), createdAt: now, updatedAt: now)
            try writeItem(value)
            if kind == .classroom { try saveClassroom(ClassroomRecord(id: id)) }
            return value
        }
    }

    @discardableResult func createStandaloneSession(title: String) throws -> WorkspaceItem {
        try withTransaction {
            let id = UUID().uuidString
            let item = WorkspaceItem(id: id, kind: .classroom, title: try checkedTitle(title), createdAt: Date(), updatedAt: Date())
            try writeItem(item); try saveClassroom(ClassroomRecord(id: id)); return item
        }
    }
    func associateStandaloneSession(id: String, courseID: String) throws {
        try withTransaction {
            guard var session = try item(id: id), session.kind == .classroom, session.courseID == nil,
                  let course = try item(id: courseID), course.kind == .course, course.deletedAt == nil else { throw LibraryError.message("请选择未关联的独立会话和有效课程。") }
            session.courseID = courseID; session.parentID = courseID; session.updatedAt = Date()
            try writeItem(session)
        }
    }

    func rename(id: String, title: String) throws {
        try withTransaction {
            var value = try liveItem(id)
            value.title = try checkedTitle(title); value.updatedAt = Date(); try writeItem(value)
        }
    }

    func move(id: String, parentID: String?) throws {
        try withTransaction {
            var value = try liveItem(id)
            if value.kind != .classroom && value.classroomID != nil { throw LibraryError.message("课堂附件和笔记随课堂整理，不能脱离课堂。") }
            let all = try items(includeDeleted: true)
            let descendants = descendantsOf(id, in: all)
            guard parentID != id && !descendants.contains(where: { $0.id == parentID }) else { throw LibraryError.message("不能移入自身或下级文件夹。") }
            let relation = try parentRelation(kind: value.kind, parentID: parentID)
            if value.kind == .course { return }
            guard relation.classroom == value.classroomID || value.kind == .classroom else { throw LibraryError.message("移动不能改变课堂归属；请在课堂中导入 PDF 或新建课堂笔记。") }
            let affected = [value] + descendants
            for classroom in affected where classroom.kind == .classroom {
                guard classroom.courseID == relation.course else { throw LibraryError.message("课堂必须保留所属课程；不能跨课程移动包含课堂的内容。") }
            }
            value.parentID = parentID
            value.courseID = value.kind == .course ? value.id : relation.course
            value.updatedAt = Date(); try writeItem(value)
            for var child in descendants {
                child.courseID = value.courseID; child.updatedAt = Date(); try writeItem(child)
            }
        }
    }

    @discardableResult
    func softDelete(id: String) throws -> String {
        try withTransaction {
            let value = try liveItem(id)
            if value.kind != .classroom && value.classroomID != nil { throw LibraryError.message("课堂附件和笔记随课堂删除与恢复。") }
            let affected = [value] + descendantsOf(id, in: try items(includeDeleted: true))
            for child in affected where child.kind == .classroom {
                if let record = try classroom(id: child.id), ["capturing", "paused", "interrupted", "preparing"].contains(record.state) {
                    throw LibraryError.message("请先结束未完成的课堂，再删除这些资料。")
                }
            }
            let group = UUID().uuidString
            let now = Date()
            for var child in affected where child.deletedAt == nil {
                child.deletedAt = now; child.deletionGroup = group; child.updatedAt = now; try writeItem(child)
            }
            return group
        }
    }

    func restore(id: String) throws {
        try withTransaction {
            guard let value = try item(id: id), value.deletedAt != nil else { return }
            var all = try items(includeDeleted: true)
            // Restore deleted ancestors first so a restored classroom keeps its original course identity.
            var cursor = value.parentID
            while let parent = cursor, let index = all.firstIndex(where: { $0.id == parent }) {
                var ancestor = all[index]; cursor = ancestor.parentID
                if ancestor.deletedAt != nil { ancestor.deletedAt = nil; ancestor.deletionGroup = nil; ancestor.updatedAt = Date(); try writeItem(ancestor); all[index] = ancestor }
            }
            let group = value.deletionGroup
            let descendants = descendantsOf(id, in: all)
            for var child in [value] + descendants where child.id == id || (group != nil && child.deletionGroup == group) {
                child.deletedAt = nil; child.deletionGroup = nil; child.updatedAt = Date(); try writeItem(child)
            }
        }
    }

    func putRecord<T: Encodable>(collection: String, id: String, ownerID: String, value: T) throws {
        try withTransaction {
            try validateCollection(collection)
            guard try item(id: ownerID) != nil else { throw LibraryError.message("保存对象不属于此资料库。") }
            try database.execute("INSERT INTO records(collection,id,owner_id,json) VALUES(?,?,?,?) ON CONFLICT(collection,id) DO UPDATE SET owner_id=excluded.owner_id,json=excluded.json", [collection,id,ownerID,try encode(value)])
            if try item(id: ownerID)?.kind == .classroom { dirtySessionIDs.insert(ownerID) }
        }
    }
    func record<T: Decodable>(collection: String, id: String, as type: T.Type) throws -> T? {
        try locked { try database.rows("SELECT json FROM records WHERE collection=? AND id=?", [collection,id]).first.map { try decode(type, $0["json"]!) } }
    }
    func records<T: Decodable>(collection: String, ownerID: String? = nil, as type: T.Type) throws -> [T] {
        try locked {
            let rows = try ownerID.map { try database.rows("SELECT json FROM records WHERE collection=? AND owner_id=? ORDER BY rowid", [collection,$0]) }
                ?? database.rows("SELECT json FROM records WHERE collection=? ORDER BY rowid", [collection])
            return try rows.map { try decode(type, $0["json"]!) }
        }
    }
    func removeRecord(collection: String, id: String) throws {
        try withTransaction {
            if let owner = try database.rows("SELECT owner_id FROM records WHERE collection=? AND id=?", [collection,id]).first?["owner_id"], try item(id: owner)?.kind == .classroom { dirtySessionIDs.insert(owner) }
            try database.execute("DELETE FROM records WHERE collection=? AND id=?", [collection,id])
        }
    }

    func classroom(id: String) throws -> ClassroomRecord? { try record(collection: "classrooms", id: id, as: ClassroomRecord.self) }
    func saveClassroom(_ value: ClassroomRecord) throws {
        try withTransaction {
            guard try item(id: value.id)?.kind == .classroom, ["en", "ja"].contains(value.mainLanguage), ["zh-Hans", "zh-Hant"].contains(value.targetLanguage),
                ["draft", "preparing", "ready", "capturing", "paused", "interrupted", "ended"].contains(value.state), value.timelineMilliseconds >= 0 else { throw LibraryError.message("课堂配置无效。") }
            var next = value
            if let old = try classroom(id: value.id) {
                if old.state == "ended", value.state != "ended" { throw LibraryError.message("已结束课堂不能重新开始；请新建课堂。") }
                next.timelineMilliseconds = max(old.timelineMilliseconds, value.timelineMilliseconds)
                next.updatedAt = max(old.updatedAt, value.updatedAt)
            }
            try putRecord(collection: "classrooms", id: next.id, ownerID: next.id, value: next)
        }
    }
    func saveTranscript(_ value: TranscriptRecord) throws {
        try withTransaction {
            guard try classroom(id: value.classroomID) != nil, value.startMS >= 0, value.endMS >= value.startMS,
                !value.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, ["en","ja"].contains(value.language), value.revision > 0 else { throw LibraryError.message("确认原文的内容或时间范围无效。") }
            if let existing = try record(collection: "transcripts", id: value.id, as: TranscriptRecord.self) {
                guard existing.classroomID == value.classroomID else { throw LibraryError.message("原文身份不能跨课堂复用。") }
                if value.revision < existing.revision { return }
                if value.revision == existing.revision {
                    guard existing.text == value.text && existing.startMS == value.startMS && existing.endMS == value.endMS else { throw LibraryError.message("同一原文修订出现冲突。") }
                    return
                }
            }
            try putRecord(collection: "transcripts", id: value.id, ownerID: value.classroomID, value: value)
            try advanceTimeline(classroomID: value.classroomID, endMS: value.endMS)
        }
    }
    func transcripts(classroomID: String) throws -> [TranscriptRecord] {
        try records(collection: "transcripts", ownerID: classroomID, as: TranscriptRecord.self).sorted { $0.startMS == $1.startMS ? $0.id < $1.id : $0.startMS < $1.startMS }
    }
    @discardableResult
    func saveNote(noteID: String, markdown: String) throws -> NoteRevision {
        try withTransaction {
            let note = try liveItem(noteID)
            guard note.kind == .note else { throw LibraryError.message("此条目不是笔记。") }
            let previous = try noteRevision(noteID: noteID)
            if let previous, previous.markdown == markdown { return previous }
            let revision = NoteRevision(id: UUID().uuidString, noteID: noteID, classroomID: note.classroomID,
                version: (previous?.version ?? 0) + 1, markdown: markdown, savedAt: Date())
            try putRecord(collection: "note-revisions", id: revision.id, ownerID: noteID, value: revision)
            var changed = note; changed.updatedAt = revision.savedAt; try writeItem(changed)
            return revision
        }
    }
    func noteRevision(noteID: String, version: Int? = nil) throws -> NoteRevision? {
        let revisions = try records(collection: "note-revisions", ownerID: noteID, as: NoteRevision.self)
        return version.map { requested in revisions.first { $0.version == requested } } ?? revisions.max { $0.version < $1.version }
    }

    @discardableResult
    func importPDF(from source: URL, parentID: String? = nil) throws -> WorkspaceItem {
        try checkWritable()
        guard source.pathExtension.lowercased() == "pdf" else { throw LibraryError.message("首版请先将文件导出为 PDF。") }
        // Expensive copy and extraction must not prevent a concurrent confirmed segment or note save.
        let itemID = UUID().uuidString
        let assetID = UUID().uuidString
        let attachment = try stageAttachment(from: source, ownerID: itemID, assetID: assetID, mediaType: "application/pdf")
        do {
            // Extract the managed copy, never a possibly changed external original.
            guard let managedPDF = PDFDocument(url: try managedURL(attachment.relativePath)), !managedPDF.isLocked, managedPDF.pageCount > 0 else { throw LibraryError.message("无法读取此 PDF，文件可能损坏或受密码保护。") }
            let pages = (0..<managedPDF.pageCount).map { number -> PDFTextPage in
                let text = managedPDF.page(at: number)?.string ?? ""
                return PDFTextPage(assetID: assetID, version: 1, pageNumber: number + 1, text: text,
                    status: text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "no-extractable-text" : "text-extracted")
            }
            return try withTransaction {
                // The destination may have moved or been deleted while extraction was in progress.
                let relation = try parentRelation(kind: .pdf, parentID: parentID)
                let now = Date()
                let item = WorkspaceItem(id: itemID, parentID: parentID, courseID: relation.course, classroomID: relation.classroom, kind: .pdf,
                    title: source.deletingPathExtension().lastPathComponent, createdAt: now, updatedAt: now, assetID: assetID)
                try writeItem(item); try writeAttachment(attachment)
                for page in pages {
                    try writePortableRecord(PortableRecord(collection: "pdf-pages", id: page.id, ownerID: itemID, json: try encode(page)))
                }
                return item
            }
        } catch { try? FileManager.default.removeItem(at: managedURL(attachment.relativePath)); throw error }
    }

    func pdfPages(assetID: String) throws -> [PDFTextPage] {
        guard let owner = try attachment(id: assetID)?.ownerID else { return [] }
        return try records(collection: "pdf-pages", ownerID: owner, as: PDFTextPage.self).filter { $0.assetID == assetID }.sorted { $0.pageNumber < $1.pageNumber }
    }
    func attachmentURL(assetID: String) throws -> URL {
        try locked {
            guard let asset = try attachment(id: assetID) else { throw LibraryError.message("附件记录不存在。") }
            let url: URL
            if let location = try record(collection: "session-attachments", id: assetID, as: SessionAttachmentLocation.self) {
                guard let transcriptStore, let session = try item(id: location.sessionID) else { throw LibraryError.message("录音所在的转写保存位置尚未连接。") }
                url = try Self.safeChild(location.relativePath, under: transcriptStore.directory(for: session))
            } else { url = try managedURL(asset.relativePath) }
            guard FileManager.default.fileExists(atPath: url.path) else { throw LibraryError.message("受管附件缺失，请从完整备份恢复。") }
            return url
        }
    }
    func attachment(id: String) throws -> ManagedAttachment? {
        try locked { try database.rows("SELECT json FROM attachments WHERE id=?", [id]).first.map { try decode(ManagedAttachment.self, $0["json"]!) } }
    }
    func attachments(ownerID: String? = nil) throws -> [ManagedAttachment] {
        try locked {
            let rows = try ownerID.map { try database.rows("SELECT json FROM attachments WHERE owner_id=?", [$0]) } ?? database.rows("SELECT json FROM attachments")
            return try rows.map { try decode(ManagedAttachment.self, $0["json"]!) }
        }
    }

    /// Call after the audio writer has closed and validated a real recorded chunk.
    @discardableResult
    func importRecording(from source: URL, classroomID: String, epochID: String, startMS: Int64, endMS: Int64) throws -> RecordingRecord {
        try locked {
            guard try classroom(id: classroomID) != nil, startMS >= 0, endMS > startMS,
                  ["caf", "wav", "m4a"].contains(source.pathExtension.lowercased()) else { throw LibraryError.message("录音附件或时间范围无效。") }
            let audio = try AVAudioFile(forReading: source)
            guard audio.length > 0, audio.processingFormat.sampleRate > 0,
                  abs(Double(endMS - startMS) / 1000 - Double(audio.length) / audio.processingFormat.sampleRate) <= 0.1 else {
                throw LibraryError.message("录音时长与课堂映射不符，尚未登记为可回听。")
            }
            guard let buffer = AVAudioPCMBuffer(pcmFormat: audio.processingFormat, frameCapacity: 16384) else { throw LibraryError.message("无法验证录音。") }
            var readFrames: Int64 = 0
            while readFrames < audio.length {
                try audio.read(into: buffer)
                guard buffer.frameLength > 0 else { throw LibraryError.message("录音尾部不完整，尚未登记为可回听。") }
                readFrames += Int64(buffer.frameLength)
            }
            if let transcriptStore, let session = try item(id: classroomID) {
                let assetID = UUID().uuidString
                let relative = "recordings/" + assetID + "." + source.pathExtension.lowercased()
                let destination = try Self.safeChild(relative, under: transcriptStore.directory(for: session))
                try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                let expected = try Self.sha256(of: source)
                try FileManager.default.copyItem(at: source, to: destination)
                guard try Self.sha256(of: destination) == expected, try Self.sha256(of: source) == expected else { throw LibraryError.message("录音复制校验失败，原录音保留。") }
                let size = (try FileManager.default.attributesOfItem(atPath: destination.path)[.size] as? NSNumber)?.int64Value ?? 0
                let asset = ManagedAttachment(id: assetID, ownerID: classroomID, relativePath: "session-assets/" + assetID, originalName: source.lastPathComponent, mediaType: "audio/" + source.pathExtension.lowercased(), byteCount: size, sha256: expected, createdAt: Date())
                let value = RecordingRecord(id: UUID().uuidString, classroomID: classroomID, epochID: epochID, assetID: assetID, startMS: startMS, endMS: endMS)
                try syncDirectory(destination.deletingLastPathComponent())
                try withTransaction {
                    try writeAttachment(asset)
                    try putRecord(collection: "session-attachments", id: assetID, ownerID: classroomID, value: SessionAttachmentLocation(assetID: assetID, sessionID: classroomID, relativePath: relative))
                    try putRecord(collection: "session-attachment-metadata", id: assetID, ownerID: classroomID, value: asset)
                    try putRecord(collection: "recordings", id: value.id, ownerID: classroomID, value: value)
                    try advanceTimeline(classroomID: classroomID, endMS: endMS)
                }
                return value
            }
            let asset = try stageAttachment(from: source, ownerID: classroomID, assetID: UUID().uuidString, mediaType: "audio/\(source.pathExtension.lowercased())")
            let value = RecordingRecord(id: UUID().uuidString, classroomID: classroomID, epochID: epochID, assetID: asset.id, startMS: startMS, endMS: endMS)
            do { try withTransaction { try writeAttachment(asset); try putRecord(collection: "recordings", id: value.id, ownerID: classroomID, value: value); try advanceTimeline(classroomID: classroomID, endMS: endMS) } }
            catch { try? FileManager.default.removeItem(at: managedURL(asset.relativePath)); throw error }
            return value
        }
    }

    func recordings(classroomID: String) throws -> [RecordingRecord] {
        try records(collection: "recordings", ownerID: classroomID, as: RecordingRecord.self).sorted { $0.startMS < $1.startMS }
    }
    func saveGap(_ gap: TimelineGap) throws {
        guard gap.startMS >= 0, gap.endMS == nil || gap.endMS! >= gap.startMS else { throw LibraryError.message("间断时间无效。") }
        try withTransaction {
            try putRecord(collection: "gaps", id: gap.id, ownerID: gap.classroomID, value: gap)
            if let end = gap.endMS { try advanceTimeline(classroomID: gap.classroomID, endMS: end) }
        }
    }
    private func advanceTimeline(classroomID: String, endMS: Int64) throws {
        guard var record = try classroom(id: classroomID) else { throw LibraryError.message("课堂配置无效。") }
        record.timelineMilliseconds = max(record.timelineMilliseconds, endMS)
        record.updatedAt = Date()
        try saveClassroom(record)
    }

    // MARK: Shared implementation helpers used by portable backup extension
    func encode<T: Encodable>(_ value: T) throws -> String {
        String(decoding: try encoder.encode(value), as: UTF8.self)
    }
    func decode<T: Decodable>(_ type: T.Type, _ value: String) throws -> T { try decoder.decode(type, from: Data(value.utf8)) }
    func databaseRows(_ sql: String, _ values: [String?] = []) throws -> [[String:String]] { try locked { try database.rows(sql, values) } }
    func writeItem(_ value: WorkspaceItem) throws {
        try database.execute("INSERT INTO items(id,parent_id,kind,json) VALUES(?,?,?,?) ON CONFLICT(id) DO UPDATE SET parent_id=excluded.parent_id,kind=excluded.kind,json=excluded.json", [value.id,value.parentID,value.kind.rawValue,try encode(value)])
        if value.kind == .classroom { dirtySessionIDs.insert(value.id) }
    }
    func writeAttachment(_ value: ManagedAttachment) throws {
        try database.execute("INSERT INTO attachments(id,owner_id,json) VALUES(?,?,?)", [value.id,value.ownerID,try encode(value)])
    }
    func writePortableRecord(_ record: PortableRecord) throws {
        try validateCollection(record.collection)
        try database.execute("INSERT INTO records(collection,id,owner_id,json) VALUES(?,?,?,?)", [record.collection,record.id,record.ownerID,record.json])
        if try item(id: record.ownerID)?.kind == .classroom { dirtySessionIDs.insert(record.ownerID) }
    }
    func validateCollection(_ collection: String) throws {
        guard !collection.isEmpty, collection.count <= 64, collection.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }),
              !["credentials", "secrets", "keychain", "tokens", "api-keys", "settings"].contains(collection.lowercased()) else { throw LibraryError.message("此记录类型不能保存在课堂资料库。") }
    }
    func managedURL(_ path: String) throws -> URL {
        try Self.safeChild(path, under: rootURL)
    }
    static func safeChild(_ path: String, under root: URL) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0"),
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw LibraryError.message("附件路径不安全。") }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let child = base.appendingPathComponent(path).standardizedFileURL
        let resolved = child.resolvingSymlinksInPath()
        guard resolved.path.hasPrefix(base.path + "/"), resolved.path == child.path else { throw LibraryError.message("附件路径或符号链接不安全。") }
        return child
    }
    static func sha256(of url: URL) throws -> String {
        let file = try FileHandle(forReadingFrom: url); defer { try? file.close() }
        var digest = SHA256()
        while let data = try file.read(upToCount: 1_048_576), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    func descendantsOf(_ id: String, in all: [WorkspaceItem]) -> [WorkspaceItem] {
        var result: [WorkspaceItem] = [], queue = [id], visited: Set<String> = [id]
        while let parent = queue.popLast() {
            for child in all where child.parentID == parent && !visited.contains(child.id) { visited.insert(child.id); result.append(child); queue.append(child.id) }
        }
        return result
    }
    private func checkedTitle(_ title: String) throws -> String {
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.count <= 500 else { throw LibraryError.message("名称不能为空，且不得超过 500 个字符。") }; return trimmed
    }
    private func liveItem(_ id: String) throws -> WorkspaceItem {
        guard let value = try item(id: id), value.deletedAt == nil else { throw LibraryError.message("资料不存在或已删除。") }; return value
    }
    private func parentRelation(kind: WorkspaceKind, parentID: String?) throws -> (course: String?, classroom: String?) {
        if kind == .course { guard parentID == nil else { throw LibraryError.message("课程只能位于工作空间顶层。") }; return (nil, nil) }
        guard let parentID else {
            guard kind != .classroom else { throw LibraryError.message("请先选择课程，再新建课堂。") }; return (nil, nil)
        }
        let parent = try liveItem(parentID)
        guard [.course, .folder, .classroom].contains(parent.kind) else { throw LibraryError.message("此条目不能包含资料。") }
        if parent.kind == .classroom {
            guard kind == .note || kind == .pdf else { throw LibraryError.message("课堂中仅能添加 PDF 和课堂笔记。") }
            return (parent.courseID, parent.id)
        }
        guard kind != .classroom || parent.courseID != nil else { throw LibraryError.message("课堂必须属于课程。") }
        return (parent.kind == .course ? parent.id : parent.courseID, nil)
    }
    private func stageAttachment(from source: URL, ownerID: String, assetID: String, mediaType: String) throws -> ManagedAttachment {
        try ensureWritable()
        let fm = FileManager.default
        let ext = source.pathExtension.lowercased()
        guard ["pdf", "caf", "wav", "m4a"].contains(ext) else { throw LibraryError.message("不支持此附件类型。") }
        let staging = try managedURL("staging/\(UUID().uuidString).partial")
        let path = "attachments/\(assetID).\(ext)"
        let target = try managedURL(path)
        let resolvedSource = source.resolvingSymlinksInPath()
        guard try fm.attributesOfItem(atPath: resolvedSource.path)[.type] as? FileAttributeType == .typeRegular else { throw LibraryError.message("请选择普通附件文件。") }
        try fm.copyItem(at: resolvedSource, to: staging)
        defer { try? fm.removeItem(at: staging) }
        let size = (try fm.attributesOfItem(atPath: staging.path)[.size] as? NSNumber)?.int64Value ?? 0
        guard size > 0 else { throw LibraryError.message("附件为空，尚未导入。") }
        let hash = try Self.sha256(of: staging)
        let file = try FileHandle(forWritingTo: staging); try file.synchronize(); try file.close()
        try fm.moveItem(at: staging, to: target)
        try syncDirectory(rootURL.appendingPathComponent("attachments"))
        return ManagedAttachment(id: assetID, ownerID: ownerID, relativePath: path, originalName: source.lastPathComponent,
            mediaType: mediaType, byteCount: size, sha256: hash, createdAt: Date())
    }
    func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw LibraryError.message("无法确认附件目录已保存。") }; defer { close(fd) }
        guard fsync(fd) == 0 else { throw LibraryError.message("附件目录落盘失败，内容尚未保存。") }
    }
    private func recoverInterruptedClassrooms() throws {
        let values = try records(collection: "classrooms", as: ClassroomRecord.self)
        for var value in values where ["capturing", "paused", "preparing"].contains(value.state) {
            try withTransaction {
                value.state = "interrupted" // Preserve the last successful timeline commit's wall-clock anchor.
                try saveClassroom(value)
                try saveGap(TimelineGap(classroomID: value.id, epochID: nil, startMS: value.timelineMilliseconds,
                    endMS: nil, reason: "应用中断；最后未确认的音频尾部可能未保存。重开不会自动采集或播报。"))
            }
            recoveryWarnings.append("已恢复中断课堂的已提交资料；未确认音频尾部可能缺失。")
        }
    }
    private func inspectAttachments() throws {
        let assets = try attachments()
        for asset in assets {
            do {
                if try record(collection: "session-attachments", id: asset.id, as: SessionAttachmentLocation.self) != nil, transcriptStore == nil { continue }
                let path = try managedURL(asset.relativePath)
                let size = (try FileManager.default.attributesOfItem(atPath: path.path)[.size] as? NSNumber)?.int64Value
                if size != asset.byteCount { recoveryWarnings.append("附件缺失或大小不符：\(asset.originalName)。请使用完整备份恢复。") }
            } catch { recoveryWarnings.append("附件无法读取：\(asset.originalName)。原记录已保留。") }
        }
        let staging = rootURL.appendingPathComponent("staging")
        if let files = try? FileManager.default.contentsOfDirectory(at: staging, includingPropertiesForKeys: nil), !files.isEmpty {
            recoveryWarnings.append("发现 \(files.count) 个未完成导入文件，未计为已保存；保留在 staging 供诊断。")
        }
        let managed = rootURL.appendingPathComponent("attachments")
        if let files = try? FileManager.default.contentsOfDirectory(at: managed, includingPropertiesForKeys: nil) {
            let referenced = Set(assets.map { $0.relativePath })
            let count = files.filter { !referenced.contains("attachments/\($0.lastPathComponent)") }.count
            if count > 0 { recoveryWarnings.append("发现 \(count) 个未登记附件（可能来自中断导入）；保留文件，不计为成功导入。") }
        }
    }
}

extension LibraryStore {
    /// Holds a consistent read snapshot while a portable backup is materialized, including in read-only mode.
    func withReadSnapshot<T>(_ body: () throws -> T) throws -> T {
        try locked {
            if transactionDepth > 0 { return try body() }
            try database.execute("BEGIN DEFERRED")
            do { let result = try body(); try database.execute("COMMIT"); return result }
            catch { try? database.execute("ROLLBACK"); throw error }
        }
    }
}
