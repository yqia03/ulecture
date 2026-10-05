import Foundation

@main struct LegacyMigrationChecks {
    static func main() throws {
        let base = URL(fileURLWithPath: CommandLine.arguments[1])
        let fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        var checks: [String] = []
        func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try value() else { throw LibraryError.message("FAILED: " + name) }; checks.append(name)
        }
        func rejects(_ name: String, _ body: () throws -> Void) throws {
            do { try body() } catch { checks.append(name); return }; throw LibraryError.message("FAILED: " + name)
        }
        let oldRoot = base.appendingPathComponent("legacy")
        var old: LibraryStore? = try LibraryStore(rootURL: oldRoot)
        let course = try old!.createItem(kind: .course, title: "Original course")
        let classroom = try old!.createItem(kind: .classroom, title: "Original class", parentID: course.id)
        let note = try old!.createItem(kind: .note, title: "Original note", parentID: classroom.id)
        let markdown = "# 原文\r\n\r\n|A|B|\r\n|-|-|\r\n|**one**|[link](https://example.invalid)|\r\n\n$$x^2$$\n<custom raw='1'>unknown</custom>\n"
        _ = try old!.saveNote(noteID: note.id, markdown: markdown)
        _ = try old!.saveNote(noteID: note.id, markdown: markdown + "Newer revision\n")
        let transcript = TranscriptRecord(id: UUID().uuidString, classroomID: classroom.id, epochID: UUID().uuidString, startMS: 9000, endMS: 12000, text: "Original speech", language: "en")
        try old!.saveTranscript(transcript)
        let destination = try LibraryStore(rootURL: base.appendingPathComponent("catalog"))
        try destination.configureTranscriptStorage(rootURL: base.appendingPathComponent("transcripts"))
        let migration = LegacyMigration(destination: destination)
        try rejects("a running legacy writer blocks migration") { _ = try migration.prepare(sourceRoot: oldRoot) }
        old = nil
        // SQLite may create disposable reader coordination sidecars when opening a WAL-mode database.
        func durableSourceFiles() throws -> [String: String] { try WorkspaceCatalog.manifest(oldRoot).filter { !["library.sqlite-wal", "library.sqlite-shm", ".writer.lock"].contains($0.key) } }
        let before = try durableSourceFiles()
        let snapshot = try migration.prepare(sourceRoot: oldRoot)
        let receipt = try migration.install(snapshot: snapshot)
        try check(receipt.phase == "committed" && receipt.itemCount == 3, "frozen snapshot migrated all stable entities")
        try check(try destination.item(id: note.id)?.classroomID == classroom.id, "legacy classroom and note identities preserved")
        try check(try destination.noteRevision(noteID: note.id, version: 1)?.markdown == markdown, "legacy Markdown preserved byte for byte with CRLF and unknown syntax")
        try check(try destination.noteRevision(noteID: note.id)?.version == 2, "all note revisions preserved")
        try check(try destination.transcripts(classroomID: classroom.id).first?.startMS == 9000, "transcript identity and original time preserved")
        try check(try destination.transcriptStore!.records(for: classroom)!.contains { $0.id == transcript.id }, "migration writes session data to independent root")
        let repeated = try migration.install(snapshot: snapshot)
        try check(repeated.taskID == receipt.taskID && (try destination.items(includeDeleted: true).count) == 3, "repeated migration is idempotent")
        try check(try durableSourceFiles() == before, "migration does not change original database, attachments or user files")
        _ = try destination.saveNote(noteID: note.id, markdown: "post-migration edit")
        _ = try migration.install(snapshot: snapshot)
        try check(try destination.noteRevision(noteID: note.id)?.markdown == "post-migration edit", "migration retry never overwrites new edits")
        let project = base.appendingPathComponent("chosen-course-root")
        try fm.createDirectory(at: project, withIntermediateDirectories: true)
        let catalog = WorkspaceCatalog(library: destination)
        try catalog.materializeLegacyCourse(courseID: course.id, root: project)
        try check(try String(contentsOf: catalog.documentURL(id: note.id)) == "post-migration edit", "per-course migration copies latest note to chosen actual directory")
        try check(try destination.item(id: note.id)?.parentID == course.id && catalog.linkedDocumentIDs(sessionID: classroom.id).contains(note.id), "physical note hierarchy and logical session reference are separate")
        try check(try destination.noteRevision(noteID: note.id, version: 1)?.markdown == markdown, "course migration preserves original historical Markdown")
        try Data("new external editing".utf8).write(to: catalog.documentURL(id: note.id))
        try catalog.materializeLegacyCourse(courseID: course.id, root: project)
        try check(try String(contentsOf: catalog.documentURL(id: note.id)) == "new external editing", "course migration retry never overwrites post-migration file edits")
        old = try LibraryStore(rootURL: oldRoot)
        _ = try old!.saveNote(noteID: note.id, markdown: "old library drift")
        old = nil
        try rejects("source drift requires a new preflight and preserves fixed snapshot") { _ = try migration.prepare(sourceRoot: oldRoot) }
        let corrupt = snapshot.appendingPathComponent("library.sqlite")
        let valid = try Data(contentsOf: corrupt)
        try Data("bad".utf8).write(to: corrupt)
        try rejects("modified frozen snapshot rejected before any catalog write") { _ = try migration.install(snapshot: snapshot) }
        try valid.write(to: corrupt)
        let protectedCourse = try destination.createItem(kind: .course, title: "Protected destination")
        catalog.excludedRoots = [destination.rootURL, destination.transcriptStore!.rootURL]
        try rejects("course migration rejects application data before journaling") { try catalog.materializeLegacyCourse(courseID: protectedCourse.id, root: destination.rootURL) }
        try rejects("course migration rejects transcript storage before journaling") { try catalog.materializeLegacyCourse(courseID: protectedCourse.id, root: destination.transcriptStore!.rootURL) }
        try check(try destination.record(collection: "course-migrations", id: protectedCourse.id, as: CourseMigrationJournal.self) == nil, "reserved root rejection creates no course migration journal")
        let alias = base.appendingPathComponent("transcripts-alias")
        try fm.createSymbolicLink(at: alias, withDestinationURL: destination.transcriptStore!.rootURL)
        catalog.excludedRoots = [alias]
        try rejects("canonical reserved alias cannot bypass course migration") { try catalog.materializeLegacyCourse(courseID: protectedCourse.id, root: destination.transcriptStore!.rootURL) }
        let ancestorRoot = base.appendingPathComponent("Documents-migration")
        let nestedReserved = ancestorRoot.appendingPathComponent("School/Transcripts")
        try fm.createDirectory(at: nestedReserved, withIntermediateDirectories: true)
        try Data("Reserved byte fixture".utf8).write(to: nestedReserved.appendingPathComponent("session.txt"))
        let reservedBytes = try WorkspaceCatalog.manifest(nestedReserved)
        let ancestorCourse = try destination.createItem(kind: .course, title: "Ancestor migration")
        let school = try destination.createItem(kind: .folder, title: "School", parentID: ancestorCourse.id)
        let ordinary = try destination.createItem(kind: .note, title: "Ordinary", parentID: school.id)
        _ = try destination.saveNote(noteID: ordinary.id, markdown: "An ordinary sibling remains allowed")
        catalog.excludedRoots = [destination.rootURL, nestedReserved]
        try catalog.materializeLegacyCourse(courseID: ancestorCourse.id, root: ancestorRoot)
        try check(try String(contentsOf: catalog.documentURL(id: ordinary.id)).contains("ordinary sibling") && WorkspaceCatalog.manifest(nestedReserved) == reservedBytes, "migration into Documents ancestor preserves reserved tree and publishes ordinary sibling")
        let blockedRoot = base.appendingPathComponent("Blocked-migration")
        let blockedReserved = blockedRoot.appendingPathComponent("School/Transcripts")
        try fm.createDirectory(at: blockedReserved, withIntermediateDirectories: true)
        let badSchool = try destination.createItem(kind: .folder, title: "School", parentID: protectedCourse.id)
        let badTranscripts = try destination.createItem(kind: .folder, title: "Transcripts", parentID: badSchool.id)
        _ = try destination.createItem(kind: .note, title: "Must not publish", parentID: badTranscripts.id)
        catalog.excludedRoots = [destination.rootURL, nestedReserved, blockedReserved]
        try rejects("legacy entries cannot publish into reserved descendants") { try catalog.materializeLegacyCourse(courseID: protectedCourse.id, root: blockedRoot) }
        try check(try catalog.mount(id: protectedCourse.id) == nil && fm.contentsOfDirectory(atPath: blockedReserved.path).isEmpty, "reserved entry failure neither mounts course nor changes protected files")
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["passed": checks.count, "checks": checks], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
