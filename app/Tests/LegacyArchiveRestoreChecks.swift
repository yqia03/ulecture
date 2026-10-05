import Foundation
import AppKit
import PDFKit
import CoreText
import Darwin

@main struct LegacyArchiveRestoreChecks {
    static func main() throws {
        let out = URL(fileURLWithPath: CommandLine.arguments[1]), fm = FileManager.default
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        if CommandLine.arguments.count > 2 {
            let phase = CommandLine.arguments[2]
            let library = try LibraryStore(rootURL: out.appendingPathComponent("crash-catalog-" + phase))
            try library.configureTranscriptStorage(rootURL: out.appendingPathComponent("crash-transcripts-" + phase))
            let destination = out.appendingPathComponent("crash-projects-" + phase)
            try fm.createDirectory(at: destination, withIntermediateDirectories: true)
            _ = try LegacyArchiveRestore(catalog: WorkspaceCatalog(library: library)).restore(from: out.appendingPathComponent("source.uwaybackup"), into: destination) { if $0 == phase { kill(getpid(), SIGKILL) } }
            throw LibraryError.message("Requested crash point was not reached")
        }
        var checks: [String] = []
        func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw LibraryError.message(label) }; checks.append(label); print("PASS " + label)
        }
        func rejects(_ label: String, _ operation: () throws -> Void) throws {
            do { try operation() } catch { checks.append(label); return }; throw LibraryError.message("Did not reject " + label)
        }
        let legacy = try LibraryStore(rootURL: out.appendingPathComponent("legacy"))
        let course = try legacy.createItem(kind: .course, title: "Legacy course", parentID: nil)
        let session = try legacy.createItem(kind: .classroom, title: "Legacy class", parentID: course.id)
        let note = try legacy.createItem(kind: .note, title: "Legacy note", parentID: session.id)
        let pdf = out.appendingPathComponent("source.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 400, height: 600)
        let context = CGContext(pdf as CFURL, mediaBox: &bounds, nil)!
        context.beginPDFPage(nil); context.textPosition = CGPoint(x: 30, y: 500)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Legacy PDF evidence", attributes: [.font: NSFont.systemFont(ofSize: 16)])), context)
        context.endPDFPage(); context.closePDF()
        let item = try legacy.importPDF(from: pdf, parentID: session.id)
        let proseID = UUID().uuidString
        _ = try legacy.saveNote(noteID: note.id, markdown: "Original revision " + proseID)
        _ = try legacy.saveNote(noteID: note.id, markdown: "# Current note\nLiteral " + proseID + "\n[Page](uway-pdf://" + item.assetID! + "/1)")
        try legacy.saveTranscript(TranscriptRecord(id: UUID().uuidString, classroomID: session.id, epochID: UUID().uuidString, startMS: 1300, endMS: 4900, text: "Original transcript", language: "en"))
        var classroom = try legacy.classroom(id: session.id)!; classroom.state = "capturing"; try legacy.saveClassroom(classroom)
        let backup = out.appendingPathComponent("source.uwaybackup")
        try legacy.backup(itemID: course.id, to: backup)
        let originalManifest = try WorkspaceCatalog.manifest(backup)
        let library = try LibraryStore(rootURL: out.appendingPathComponent("catalog")), catalog = WorkspaceCatalog(library: library)
        try library.configureTranscriptStorage(rootURL: out.appendingPathComponent("transcripts"))
        let destination = out.appendingPathComponent("projects"); try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let operation = LegacyArchiveRestore(catalog: catalog)
        try rejects("preconverted interruption returns before modifying the real catalog") {
            _ = try operation.restore(from: backup, into: destination) { if $0 == "legacy-converted" { throw LibraryError.message("fixture interruption") } }
        }
        try check(library.items().isEmpty, "preconversion writes only its isolated library and frozen v2 archive")
        let imported = try operation.restore(from: backup, into: destination)
        let note2 = imported.first { $0.kind == .note }!, pdf2 = imported.first { $0.kind == .pdf }!, class2 = imported.first { $0.kind == .classroom }!
        let text = try String(contentsOf: catalog.documentURL(id: note2.id), encoding: .utf8)
        try check(text.contains(proseID) && text.contains(pdf2.assetID!) && (try library.records(collection: "note-revisions", ownerID: note2.id, as: NoteRevision.self)).count == 2, "legacy Markdown content, fixed revisions and local PDF link identities survive")
        try check(PDFDocument(url: try catalog.documentURL(id: pdf2.id))?.string?.contains("Legacy PDF evidence") == true, "legacy managed PDF becomes an actual readable workspace document")
        try check(try library.classroom(id: class2.id)?.state == "interrupted" && library.classroom(id: class2.id)?.translationUserPaused == true, "restored classroom stays paused and cannot automatically dispatch")
        try check(try library.transcripts(classroomID: class2.id).first?.startMS == 1300 && library.transcripts(classroomID: class2.id).first?.text == "Original transcript", "independent session storage retains actual transcript text and time")
        let again = try operation.restore(from: backup, into: destination)
        try check(Set(again.map(\.id)) == Set(imported.map(\.id)) && (try library.items()).count == imported.count, "completed retry reuses the committed restore and creates no duplicate objects")
        try check(try WorkspaceCatalog.manifest(backup) == originalManifest, "source v1 manifest and attachments remain byte-for-byte unchanged")
        let corrupt = out.appendingPathComponent("corrupt.uwaybackup"); try fm.copyItem(at: backup, to: corrupt)
        let manifest = try JSONDecoder().decode(LibraryBackupManifest.self, from: Data(contentsOf: corrupt.appendingPathComponent("manifest.json")))
        try Data("corrupt".utf8).write(to: corrupt.appendingPathComponent(manifest.attachments[0].relativePath))
        try rejects("tampered original attachments cannot reuse a prepared conversion") { _ = try operation.restore(from: corrupt, into: destination) }
        try check(try library.items().count == imported.count, "failed legacy validation leaves all current catalog objects intact")
        for phase in ["legacy-converted", "published", "committed"] {
            let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); child.arguments = [out.path, phase]
            try child.run(); child.waitUntilExit()
            try check(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL, "real process death at " + phase)
            let recovered = try LibraryStore(rootURL: out.appendingPathComponent("crash-catalog-" + phase))
            try recovered.configureTranscriptStorage(rootURL: out.appendingPathComponent("crash-transcripts-" + phase))
            let restorer = LegacyArchiveRestore(catalog: WorkspaceCatalog(library: recovered))
            let result = try restorer.restore(from: backup, into: out.appendingPathComponent("crash-projects-" + phase))
            let repeated = try restorer.restore(from: backup, into: out.appendingPathComponent("crash-projects-" + phase))
            try check(result.count == manifest.items.count && Set(result.map(\.id)) == Set(repeated.map(\.id)) && (try recovered.items()).count == result.count, "restart reuses fixed conversion and same restored identities after " + phase)
        }
        // The new archive path also preserves an authoritative legacy block
        // package when no filesystem locator has been created yet.
        let package = legacy.rootURL.appendingPathComponent("document-data/" + note.id + "/note.ulnote")
        let noteStore = BlockNoteStore(packageURL: package, noteID: note.id)
        var blocks = try noteStore.create(title: note.title)
        blocks.blocks = [NoteBlock(kind: .paragraph, text: "Authoritative legacy block package")]
        _ = try noteStore.save(blocks)
        let packageBackup = out.appendingPathComponent("package.ulbackup")
        try WorkspaceArchive(catalog: WorkspaceCatalog(library: legacy)).backup(itemID: course.id, to: packageBackup)
        let packageManifest = try JSONDecoder().decode(WorkspaceArchiveManifest.self, from: Data(contentsOf: packageBackup.appendingPathComponent("manifest.json")))
        try check(packageManifest.documents.contains { $0.id == note.id && $0.format == "ulnote" }, "legacy fallback exports authoritative block package instead of stale Markdown")
        let packageLibrary = try LibraryStore(rootURL: out.appendingPathComponent("package-catalog")), packageCatalog = WorkspaceCatalog(library: packageLibrary)
        let packageDestination = out.appendingPathComponent("package-projects"); try fm.createDirectory(at: packageDestination, withIntermediateDirectories: true)
        let packageItems = try WorkspaceArchive(catalog: packageCatalog).restore(from: packageBackup, into: packageDestination)
        let restoredNote = packageItems.first { $0.kind == .note }!
        let actual = try BlockNoteStore(packageURL: packageCatalog.documentURL(id: restoredNote.id), noteID: restoredNote.id).loadSnapshot()
        try check(actual.document.markdown.contains("Authoritative legacy block package"), "legacy block package restores with a valid immutable source revision")
        try JSONSerialization.data(withJSONObject: ["checks": checks, "count": checks.count, "boundary": "local immutable v1-to-v2 conversion and three real SIGKILL points; no UI, audio or cloud"], options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("legacy-archive-restore-checks.json"))
        print("PASS: \(checks.count) legacy archive conversion/restore checks")
    }
}
