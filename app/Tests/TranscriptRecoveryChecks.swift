import Foundation

@main enum TranscriptRecoveryChecks {
    static func main() throws {
        let base = URL(fileURLWithPath: CommandLine.arguments[1]), fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        var checks: [String] = []
        func check(_ condition: @autoclosure () throws -> Bool, _ title: String) throws {
            guard try condition() else { throw LibraryError.message("FAILED: " + title) }
            checks.append(title)
        }
        func record<T: Encodable>(_ collection: String, _ id: String, _ owner: String, _ value: T) throws -> PortableRecord {
            PortableRecord(collection: collection, id: id, ownerID: owner, json: String(decoding: try JSONEncoder().encode(value), as: UTF8.self))
        }
        func session(course: String? = nil, parent: String? = nil) -> WorkspaceItem {
            WorkspaceItem(id: UUID().uuidString, parentID: parent ?? course, courseID: course, classroomID: nil, kind: .classroom, title: "Recovered lecture", createdAt: Date(), updatedAt: Date())
        }
        let library = try LibraryStore(rootURL: base.appendingPathComponent("catalog"))
        let root = base.appendingPathComponent("transcripts"), store = try TranscriptStore(rootURL: root, catalogLibraryID: library.libraryID)
        let courseID = UUID().uuidString, folderID = UUID().uuidString, orphan = session(course: courseID, parent: folderID)
        let segment = TranscriptRecord(id: UUID().uuidString, classroomID: orphan.id, epochID: UUID().uuidString, startMS: 100, endMS: 900, text: "Commit survived before catalog commit 中文", language: "zh-Hans")
        let assetID = UUID().uuidString, relativeRecording = "recordings/" + assetID + ".wav"
        let directory = try store.directory(for: orphan)
        try fm.createDirectory(at: directory.appendingPathComponent("recordings"), withIntermediateDirectories: true)
        let recordingURL = directory.appendingPathComponent(relativeRecording)
        try Data("fixture recording bytes; never played".utf8).write(to: recordingURL)
        let asset = ManagedAttachment(id: assetID, ownerID: orphan.id, relativePath: "session-assets/" + assetID, originalName: "lecture.wav", mediaType: "audio/wav", byteCount: 36, sha256: try WorkspaceCatalog.contentHash(recordingURL), createdAt: Date())
        let location = SessionAttachmentLocation(assetID: assetID, sessionID: orphan.id, relativePath: relativeRecording)
        let records = try [record("classrooms", orphan.id, orphan.id, ClassroomRecord(id: orphan.id)), record("transcripts", segment.id, orphan.id, segment),
            record("session-attachment-metadata", asset.id, orphan.id, asset), record("session-attachments", asset.id, orphan.id, location)]
        try store.persist(session: orphan, records: records)
        try check(try library.item(id: orphan.id) == nil, "fixture represents durable session with catalog commit absent")
        let before = try WorkspaceCatalog.contentHash(directory.appendingPathComponent("session.sqlite"))
        let discovery = try store.discoveredSessions()
        try check(discovery.sessions.count == 1 && discovery.issues.isEmpty && discovery.sessions[0].records.count == 4, "read-only discovery sees latest committed WAL records")
        try check(try WorkspaceCatalog.contentHash(directory.appendingPathComponent("session.sqlite")) == before, "discovery does not modify source database bytes")
        store.useDiscoveredLocations(discovery)
        let restored = TranscriptRecovery.restoreOrphans(in: library, discovery: discovery)
        try check(restored.recoveredSessionIDs == [orphan.id] && restored.issues.isEmpty, "missing classroom is atomically reconstructed")
        try check(try library.item(id: courseID)?.title == "已恢复课程 " + String(courseID.prefix(8)) && library.item(id: orphan.id)?.parentID == courseID, "missing course uses original UUID and absent folder falls back to course")
        try check(try library.transcripts(classroomID: orphan.id).first?.text == segment.text, "recovered confirmed transcript retains exact content")
        try check(try library.attachment(id: assetID)?.sha256 == asset.sha256 && library.record(collection: "session-attachments", id: assetID, as: SessionAttachmentLocation.self)?.relativePath == relativeRecording, "recording attachment metadata and physical location are reconstructed")
        let receipt = try library.record(collection: "transcript-recovery", id: orphan.id, as: TranscriptRecoveryReceipt.self)
        try check(receipt?.originalParentID == folderID && receipt?.sourceCatalogLibraryID == library.libraryID && receipt?.legacyUnverifiedCatalog == false, "recovery provenance retains original association and catalog identity")
        try check(TranscriptRecovery.restoreOrphans(in: library, discovery: discovery).recoveredSessionIDs.isEmpty, "repeated recovery is idempotent")

        let legacy = session(), legacyStore = try TranscriptStore(rootURL: root)
        try legacyStore.persist(session: legacy, records: [record("classrooms", legacy.id, legacy.id, ClassroomRecord(id: legacy.id))])
        let secondDiscovery = try store.discoveredSessions()
        let second = TranscriptRecovery.restoreOrphans(in: library, discovery: secondDiscovery)
        try check(second.recoveredSessionIDs == [legacy.id] && (try library.item(id: legacy.id)?.courseID == nil), "legacy standalone session recovers without inventing a course")
        try check(try library.record(collection: "transcript-recovery", id: legacy.id, as: TranscriptRecoveryReceipt.self)?.legacyUnverifiedCatalog == true, "legacy session without catalog identity is explicitly identified")
        var associated = legacy; associated.courseID = courseID; associated.parentID = courseID
        store.useDiscoveredLocations(secondDiscovery)
        try check(try store.directory(for: associated).path == root.appendingPathComponent("Standalone/" + legacy.id).standardizedFileURL.resolvingSymlinksInPath().path, "standalone physical identity survives course association")

        let foreign = session(), foreignStore = try TranscriptStore(rootURL: root, catalogLibraryID: UUID().uuidString)
        try foreignStore.persist(session: foreign, records: [])
        var foreignReadRejected = false
        do { _ = try store.records(for: foreign) } catch { foreignReadRejected = true }
        try check(foreignReadRejected, "direct access also rejects a database explicitly owned by another catalog")
        let invalidID = UUID().uuidString, invalidDir = root.appendingPathComponent("Standalone/" + invalidID)
        try fm.createDirectory(at: invalidDir, withIntermediateDirectories: true)
        try Data("not a SQLite database".utf8).write(to: invalidDir.appendingPathComponent("session.sqlite"))
        let empty = root.appendingPathComponent("Standalone/" + UUID().uuidString)
        try fm.createDirectory(at: empty, withIntermediateDirectories: true)
        let ignored = root.appendingPathComponent(".restore-in-progress/Standalone/" + UUID().uuidString)
        try fm.createDirectory(at: ignored, withIntermediateDirectories: true)
        try Data("unfinished staging".utf8).write(to: ignored.appendingPathComponent("session.sqlite"))
        let mixed = try store.discoveredSessions()
        try check(mixed.sessions.count == 2 && mixed.issues.count == 2 && !mixed.sessions.contains { $0.session.id == foreign.id }, "foreign and corrupt databases are isolated while valid sessions remain discoverable")
        try check(!mixed.issues.contains { $0.relativePath.contains(".restore-in-progress") || $0.relativePath.contains(empty.lastPathComponent) }, "two-level discovery ignores staging and uncommitted empty directories")

        let duplicateBucket = root.appendingPathComponent(courseID), duplicateDir = duplicateBucket.appendingPathComponent(legacy.id)
        try fm.createDirectory(at: duplicateDir, withIntermediateDirectories: true)
        var duplicateSession = legacy; duplicateSession.courseID = courseID; duplicateSession.parentID = courseID
        let duplicateDB = try SQLiteDatabase(url: duplicateDir.appendingPathComponent("session.sqlite"), readOnly: false)
        try duplicateDB.execute("CREATE TABLE metadata(key TEXT PRIMARY KEY,value TEXT NOT NULL)")
        try duplicateDB.execute("CREATE TABLE records(collection TEXT NOT NULL,id TEXT NOT NULL,owner_id TEXT NOT NULL,json TEXT NOT NULL,PRIMARY KEY(collection,id))")
        try duplicateDB.execute("PRAGMA user_version=1")
        try duplicateDB.execute("INSERT INTO metadata VALUES('session',?)", [String(decoding: JSONEncoder().encode(duplicateSession), as: UTF8.self)])
        try duplicateDB.execute("INSERT INTO metadata VALUES('saved_at',?)", [String(Date().timeIntervalSince1970)])
        let duplicates = try store.discoveredSessions()
        try check(!duplicates.sessions.contains { $0.session.id == legacy.id } && duplicates.issues.filter { $0.relativePath.hasSuffix(legacy.id) }.count == 2, "duplicate session identities preserve both sources and require explicit resolution")

        let collision = session(course: UUID().uuidString)
        let collisionRecords = [try record("transcripts", segment.id, collision.id, TranscriptRecord(id: segment.id, classroomID: collision.id, epochID: UUID().uuidString, startMS: 0, endMS: 1, text: "must not overwrite", language: "en"))]
        let colliding = DiscoveredTranscriptSession(session: collision, records: collisionRecords, directoryURL: root.appendingPathComponent(collision.courseID! + "/" + collision.id), savedAt: Date(), catalogLibraryID: library.libraryID)
        let failed = TranscriptRecovery.restoreOrphans(in: library, discovery: TranscriptDiscovery(sessions: [colliding]))
        try check(failed.recoveredSessionIDs.isEmpty && failed.issues.count == 1 && (try library.item(id: collision.id) == nil) && (try library.item(id: collision.courseID!) == nil), "record collision rolls back orphan and recovered course without partial catalog state")
        try check(try library.transcripts(classroomID: orphan.id).first?.text == segment.text, "collision never overwrites existing confirmed text")

        let symlinkID = UUID().uuidString
        try fm.createSymbolicLink(at: root.appendingPathComponent("Standalone/" + symlinkID), withDestinationURL: directory)
        let links = try store.discoveredSessions()
        try check(links.issues.contains { $0.relativePath.hasSuffix(symlinkID) }, "symbolic-link session directories are not followed")
        let pendingSession = session(course: courseID), pendingTask = UUID().uuidString
        try store.persist(session: pendingSession, records: [record("classrooms", pendingSession.id, pendingSession.id, ClassroomRecord(id: pendingSession.id)), record("workspace-restore-pending", pendingSession.id, pendingSession.id, ["restoreTaskID": pendingTask])])
        let pendingDiscovery = try store.discoveredSessions(), pendingResult = TranscriptRecovery.restoreOrphans(in: library, discovery: pendingDiscovery)
        try check(try library.item(id: pendingSession.id) == nil && pendingResult.issues.contains { $0.reason.contains("完整备份恢复尚未提交") }, "uncommitted whole-backup session stays isolated for the original restore task retry")
        try library.putRecord(collection: "workspace-restores", id: pendingTask, ownerID: courseID, value: ["committed": true])
        let committedResult = TranscriptRecovery.restoreOrphans(in: library, discovery: pendingDiscovery)
        try check(committedResult.recoveredSessionIDs.contains(pendingSession.id), "whole-backup session may recover only after its catalog restore commit exists")
        let integrated = session(course: courseID)
        try store.persist(session: integrated, records: [record("classrooms", integrated.id, integrated.id, ClassroomRecord(id: integrated.id))])
        var updated = segment; updated.text = "Newer durable session commit"; updated.revision += 1
        var updatedRecords = records; updatedRecords[1] = try record("transcripts", updated.id, orphan.id, updated)
        try store.persist(session: orphan, records: updatedRecords)
        try library.configureTranscriptStorage(rootURL: root)
        try check(try library.item(id: integrated.id)?.id == integrated.id && library.transcripts(classroomID: orphan.id).first?.text == updated.text, "configure startup recovers a new orphan and refreshes an already indexed session")
        try check(try library.record(collection: "transcript-recovery", id: orphan.id, as: TranscriptRecoveryReceipt.self)?.originalParentID == folderID, "startup reconciliation retains the original recovery provenance")
        try check(!library.recoveryWarnings.isEmpty && fm.fileExists(atPath: recordingURL.path), "unrecoverable sources are reported while original recording bytes remain in place")
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["passed": checks.count, "checks": checks], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
