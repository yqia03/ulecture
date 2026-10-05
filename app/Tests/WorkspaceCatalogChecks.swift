import Foundation
import PDFKit
import AppKit

@main struct WorkspaceCatalogChecks {
    static func main() throws {
        let base = URL(fileURLWithPath: CommandLine.arguments[1])
        let fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        var checks: [String] = []
        func check(_ condition: @autoclosure () throws -> Bool, _ name: String) throws {
            guard try condition() else { throw LibraryError.message("FAILED: " + name) }; checks.append(name); FileHandle.standardError.write(Data(("PASS " + name + "\n").utf8))
        }
        func rejects(_ name: String, _ body: () throws -> Void) throws {
            do { try body() } catch { checks.append(name); FileHandle.standardError.write(Data(("PASS " + name + "\n").utf8)); return }; throw LibraryError.message("FAILED: " + name)
        }
        var library: LibraryStore? = try LibraryStore(rootURL: base.appendingPathComponent("catalog"))
        var catalog: WorkspaceCatalog? = WorkspaceCatalog(library: library!)
        let ca = try catalog!.createCourse(title: "CourseA / Theory: 2026"), cb = try catalog!.createCourse(title: "CourseB")
        let a = try catalog!.projectRoot(ca.id), b = try catalog!.projectRoot(cb.id)
        try check(ca.title == "CourseA / Theory: 2026", "course display titles keep punctuation independently of their managed directory name")
        try check(try fm.contentsOfDirectory(atPath: a.path).isEmpty && fm.contentsOfDirectory(atPath: b.path).isEmpty, "new courses have empty independent managed directories")
        let folder = try catalog!.create(kind: .folder, title: "Week1", parentID: ca.id)
        let original = base.appendingPathComponent("notes.md")
        try Data("# Original\n\nA source paragraph.\n".utf8).write(to: original)
        let note = try catalog!.importDocument(from: original, parentID: folder.id)
        try Data("ignore".utf8).write(to: a.appendingPathComponent("unsupported.bin"))
        try fm.createSymbolicLink(at: a.appendingPathComponent("loop"), withDestinationURL: a)
        try Data("not imported".utf8).write(to: a.appendingPathComponent("Unknown.md"))
        try fm.createDirectory(at: a.appendingPathComponent("UnknownFolder"), withIntermediateDirectories: false)
        try Data("not imported either".utf8).write(to: a.appendingPathComponent("UnknownFolder/Hidden.txt"))
        try catalog!.scan(projectID: ca.id)
        try check(try library!.items().count == 4, "refresh never loads unimported files or folders")
        try rejects("ordinary folders cannot be imported as course contents") { _ = try catalog!.importDocument(from: a.appendingPathComponent("UnknownFolder"), parentID: ca.id) }
        let disguisedFolder = base.appendingPathComponent("folder.md")
        try fm.createDirectory(at: disguisedFolder, withIntermediateDirectories: false)
        try rejects("a folder with a supported extension cannot bypass explicit file import") { _ = try catalog!.importDocument(from: disguisedFolder, parentID: ca.id) }
        let classroom = try catalog!.create(kind: .classroom, title: "Session", parentID: ca.id)
        try catalog!.link(documentID: note.id, sessionID: classroom.id)
        let metadata = try catalog!.metadataDirectory(documentID: note.id)
        try Data("annotation version".utf8).write(to: metadata.appendingPathComponent("annotations.json"))
        let sourceHash = try WorkspaceCatalog.contentHash(a.appendingPathComponent("Week1/notes.md"))
        try catalog!.move(id: folder.id, parentID: cb.id)
        try check(!fm.fileExists(atPath: a.appendingPathComponent("Week1").path) && fm.fileExists(atPath: b.appendingPathComponent("Week1/notes.md").path), "cross-project folder moves real files")
        try check(try WorkspaceCatalog.contentHash(catalog!.documentURL(id: note.id)) == sourceHash, "move keeps source bytes")
        try check(try library!.item(id: note.id)?.courseID == cb.id && library!.item(id: note.id)?.parentID == folder.id, "move keeps stable document and folder identities")
        try check(try catalog!.linkedDocumentIDs(sessionID: classroom.id).contains(note.id), "cross-project move preserves session reference")
        try check(try Data(contentsOf: catalog!.metadataDirectory(documentID: note.id).appendingPathComponent("annotations.json")) == Data("annotation version".utf8), "annotations and immutable source resources follow document")
        try rejects("cycles rejected without filesystem mutation") { try catalog!.move(id: folder.id, parentID: folder.id) }
        try catalog!.rename(id: note.id, title: "Renamed")
        try check(fm.fileExists(atPath: b.appendingPathComponent("Week1/Renamed.md").path), "rename changes actual filesystem name")
        try fm.moveItem(at: b.appendingPathComponent("Week1/Renamed.md"), to: b.appendingPathComponent("outside.txt"))
        try catalog!.scan(projectID: cb.id)
        try check(try library!.item(id: note.id)?.parentID == cb.id && catalog!.locator(id: note.id)?.format == "txt", "Finder rename/move preserves identity and refreshes parent and format")
        let anotherSource = base.appendingPathComponent("another.txt")
        try Data("new distinct content".utf8).write(to: anotherSource)
        let another = try catalog!.importDocument(from: anotherSource, parentID: cb.id)
        try rejects("same-name conflict never overwrites either file") { try catalog!.rename(id: another.id, title: "outside") }
        try check(try String(contentsOf: b.appendingPathComponent("another.txt")) == "new distinct content", "failed rename preserves source")
        try catalog!.reorder(id: cb.id, relativeTo: ca.id, after: false)
        try catalog!.reorder(id: another.id, relativeTo: note.id, after: false)
        try catalog!.trash(id: note.id)
        try check(!fm.fileExists(atPath: b.appendingPathComponent("outside.txt").path) && (try library!.item(id: note.id)?.deletedAt != nil), "delete is recoverable physical trash and durable deleted state")
        try catalog!.restore(id: note.id)
        try check(try WorkspaceCatalog.contentHash(b.appendingPathComponent("outside.txt")) == sourceHash, "restore returns exact bytes and stable identity")
        try catalog!.unmount(cb.id)
        try check(fm.fileExists(atPath: b.appendingPathComponent("outside.txt").path) && (try catalog!.mounts().count == 1), "unmount leaves all project files intact")
        try catalog!.restoreCourse(id: cb.id)
        try check(try catalog!.mounts().count == 2 && catalog!.mount(id: cb.id)?.mounted == true, "restore reveals only an already registered course without accepting a folder")
        let outside = base.appendingPathComponent("import.txt")
        try Data("keep external original".utf8).write(to: outside)
        let imported = try catalog!.importDocument(from: outside, parentID: cb.id)
        try check(fm.fileExists(atPath: outside.path) && (try String(contentsOf: catalog!.documentURL(id: imported.id))) == "keep external original", "external import copies and preserves external original")
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: b.path)
        try rejects("actual readonly project rejects mutation") { try catalog!.rename(id: another.id, title: "not-saved") }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: b.path)
        let transcripts = base.appendingPathComponent("separate-transcripts")
        try library!.configureTranscriptStorage(rootURL: transcripts)
        let row = TranscriptRecord(id: UUID().uuidString, classroomID: classroom.id, epochID: UUID().uuidString, startMS: 500, endMS: 1800, text: "Persistent independently from course files", language: "en")
        try library!.saveTranscript(row)
        let sessionDir = try library!.transcriptStore!.directory(for: classroom)
        try check(fm.fileExists(atPath: sessionDir.appendingPathComponent("session.sqlite").path), "confirmed transcript is durably saved in independent root without export")
        try check(try library!.transcriptStore!.records(for: classroom)!.contains(where: { $0.id == row.id && $0.collection == "transcripts" }), "independent session snapshot contains exact confirmed record")
        let snapshotURL = base.appendingPathComponent("snapshot.sqlite")
        try library!.snapshotDatabase(to: snapshotURL)
        let snap = try SQLiteDatabase(url: snapshotURL, readOnly: true)
        try check(try snap.rows("SELECT id FROM records WHERE collection='transcripts'").count == 1, "SQLite snapshot contains WAL commits")
        try fm.moveItem(at: transcripts, to: base.appendingPathComponent("disconnected-transcripts"))
        var failed = row; failed.id = UUID().uuidString; failed.text = "must not claim saved"
        try rejects("disconnected transcript root prevents false save") { try library!.saveTranscript(failed) }
        try check(try library!.transcripts(classroomID: classroom.id).count == 1, "session failure rolls back catalog commit")
        try fm.moveItem(at: base.appendingPathComponent("disconnected-transcripts"), to: transcripts)
        catalog = nil; library = nil
        library = try LibraryStore(rootURL: base.appendingPathComponent("catalog"))
        catalog = WorkspaceCatalog(library: library!)
        try library!.configureTranscriptStorage(rootURL: transcripts)
        try check(try library!.items().filter { $0.kind == .course }.sorted(by: WorkspaceCatalog.ordered).first?.id == cb.id, "course ordering persists after reopen")
        try check(try catalog!.documentURL(id: note.id).lastPathComponent == "outside.txt", "stable locator persists after reopen")
        try check(try library!.transcripts(classroomID: classroom.id).first?.text == row.text, "session data restores after process-lifetime reset")
        let readOnlyLibrary = try LibraryStore(rootURL: base.appendingPathComponent("catalog"))
        let readOnlyCatalog = WorkspaceCatalog(library: readOnlyLibrary)
        try check(readOnlyLibrary.isReadOnly, "second catalog is read-only for registration rollback checks")
        try rejects("failed note registration reports the error") { _ = try readOnlyCatalog.create(kind: .note, title: "Registration failure", parentID: ca.id) }
        try check(!fm.fileExists(atPath: a.appendingPathComponent("Registration failure.ulnote").path), "failed note registration removes its empty unregistered package")
        let retrySource = base.appendingPathComponent("Registration failure.txt")
        try Data("Original survives failed import".utf8).write(to: retrySource)
        try rejects("failed file registration reports the error") { _ = try readOnlyCatalog.importDocument(from: retrySource, parentID: ca.id) }
        try check(!fm.fileExists(atPath: a.appendingPathComponent(retrySource.lastPathComponent).path) && fm.fileExists(atPath: retrySource.path), "failed import registration removes only its unchanged copy and preserves source")
        let originalExport = try library!.transcriptExportFiles(itemID: note.id, format: .srt, bilingual: false)
        try check(originalExport.count == 1 && String(decoding: originalExport.values.first!, as: UTF8.self).contains("00:00:00,500 --> 00:00:01,800"), "linked document exports real session time without compressing gaps")
        try rejects("no associated transcript cannot export empty success") { _ = try library!.transcriptExportFiles(itemID: imported.id, format: .txt, bilingual: true) }
        let newTranscripts = base.appendingPathComponent("new-transcript-root")
        try fm.createDirectory(at: newTranscripts, withIntermediateDirectories: true)
        try library!.moveTranscriptStorage(to: newTranscripts)
        try check(try library!.transcriptStore!.records(for: classroom)!.contains { $0.id == row.id }, "changing transcript root preserves durable session records")
        try check(fm.fileExists(atPath: sessionDir.appendingPathComponent("session.sqlite").path), "transcript root change preserves rollback source")
        var afterMove = row; afterMove.id = UUID().uuidString; afterMove.text = "after root move"
        try library!.saveTranscript(afterMove)
        try check(try library!.transcriptStore!.records(for: classroom)!.contains { $0.id == afterMove.id }, "new confirmed segments save to newly selected transcript root")
        try fm.removeItem(at: b.appendingPathComponent("outside.txt"))
        try catalog!.scan(projectID: cb.id)
        try check(try catalog!.locator(id: note.id)?.missing == true && library!.item(id: note.id)?.id == note.id, "Finder deletion retains missing document identity for references")
        try check(try catalog!.recoverFileOperations().isEmpty, "completed journal operations do not replay")
        let reimportSource = base.appendingPathComponent("Reimport.md")
        try Data("Initial imported document".utf8).write(to: reimportSource)
        let beforeReimport = try catalog!.importDocument(from: reimportSource, parentID: ca.id)
        try catalog!.link(documentID: beforeReimport.id, sessionID: classroom.id)
        let reimportMetadata = try catalog!.metadataDirectory(documentID: beforeReimport.id)
        try Data("Existing annotation".utf8).write(to: reimportMetadata.appendingPathComponent("annotation.txt"))
        try fm.removeItem(at: catalog!.documentURL(id: beforeReimport.id))
        try catalog!.scan(projectID: ca.id)
        try Data("Reimported document content".utf8).write(to: reimportSource)
        let afterReimport = try catalog!.importDocument(from: reimportSource, parentID: ca.id)
        try catalog!.scan(projectID: ca.id)
        try check(afterReimport.id == beforeReimport.id && catalog!.locator(id: afterReimport.id)?.missing == false, "reimporting a deleted external file restores its registered document identity")
        try check(try catalog!.linkedDocumentIDs(sessionID: classroom.id).contains(afterReimport.id) && Data(contentsOf: catalog!.metadataDirectory(documentID: afterReimport.id).appendingPathComponent("annotation.txt")) == Data("Existing annotation".utf8), "same-path reimport preserves existing session references and metadata")
        let renamedReimport = a.appendingPathComponent("MovedReimport.md")
        try fm.moveItem(at: catalog!.documentURL(id: afterReimport.id), to: renamedReimport)
        let distinctReimport = try catalog!.importDocument(from: reimportSource, parentID: ca.id)
        try check(distinctReimport.id != afterReimport.id, "same-path import does not reuse an original document that moved elsewhere")
        try catalog!.scan(projectID: ca.id)
        try check(try catalog!.locator(id: afterReimport.id)?.relativePath == "MovedReimport.md" && catalog!.locator(id: distinctReimport.id)?.relativePath == "Reimport.md", "refresh resolves moved and new files without duplicate-path crashes")
        let duplicate = WorkspaceItem(id: UUID().uuidString, parentID: ca.id, courseID: ca.id, kind: .note, title: "Historical duplicate", createdAt: Date(), updatedAt: Date())
        try library!.writeItem(duplicate)
        var duplicateLocator = try catalog!.locator(id: distinctReimport.id)!
        duplicateLocator.id = duplicate.id; duplicateLocator.fileIdentity = "unavailable-old-file"; duplicateLocator.missing = true
        try library!.putRecord(collection: "document-locators", id: duplicate.id, ownerID: duplicate.id, value: duplicateLocator)
        try catalog!.scan(projectID: ca.id)
        try check(try catalog!.locator(id: distinctReimport.id)?.missing == false && catalog!.locator(id: duplicate.id)?.missing == true, "refresh tolerates historical duplicate paths and preserves the live document")
        let parentCourse = try catalog!.createCourse(title: "Reserved subtree safety")
        let documentsRoot = try catalog!.projectRoot(parentCourse.id)
        let reservedAncestor = try catalog!.create(kind: .folder, title: "ULecture", parentID: parentCourse.id)
        let reserved = documentsRoot.appendingPathComponent("ULecture/Transcripts")
        let reservedApplication = documentsRoot.appendingPathComponent("ManagedApplicationData")
        for folder in [reserved, reservedApplication] { try fm.createDirectory(at: folder, withIntermediateDirectories: true) }
        try Data("Never a course document".utf8).write(to: reserved.appendingPathComponent("Session.txt"))
        try Data("Never course data".utf8).write(to: reservedApplication.appendingPathComponent("Private.md"))
        catalog!.excludedRoots = [reserved, reservedApplication]
        try catalog!.scan(projectID: parentCourse.id)
        let parentItems = try library!.items().filter { $0.courseID == parentCourse.id }
        try check(!parentItems.contains { ["Transcripts", "Session", "ManagedApplicationData", "Private"].contains($0.title) }, "reserved and unknown subtrees stay out of course refresh")
        try rejects("relocation cannot bypass reserved root checks") { try catalog!.relocate(projectID: parentCourse.id, root: reservedApplication) }
        try rejects("relocation cannot overlap another registered course") { try catalog!.relocate(projectID: parentCourse.id, root: a) }
        let reservedBefore = try WorkspaceCatalog.manifest(reserved)
        try rejects("renaming a visible ancestor cannot relocate live transcript storage") { try catalog!.rename(id: reservedAncestor.id, title: "Renamed") }
        try rejects("moving a visible ancestor cannot relocate live transcript storage") { try catalog!.move(id: reservedAncestor.id, parentID: ca.id) }
        try rejects("trashing a visible ancestor cannot remove live transcript storage") { try catalog!.trash(id: reservedAncestor.id) }
        try check(try WorkspaceCatalog.manifest(reserved) == reservedBefore && library!.item(id: reservedAncestor.id)?.deletedAt == nil, "reserved bytes and catalog ancestor stay intact after rejected mutations")
        let metadataConflict = base.appendingPathComponent("MetadataConflict")
        let metadataReserved = metadataConflict.appendingPathComponent(".ulecture/Transcripts")
        try fm.createDirectory(at: metadataReserved, withIntermediateDirectories: true)
        try Data("Independent session bytes".utf8).write(to: metadataReserved.appendingPathComponent("session.txt"))
        catalog!.excludedRoots.append(metadataReserved)
        let metadataBefore = try WorkspaceCatalog.manifest(metadataConflict)
        try rejects("reserved subtree inside internal metadata rejects relocation") { try catalog!.relocate(projectID: ca.id, root: metadataConflict) }
        let legacy = try library!.createItem(kind: .course, title: "Legacy metadata conflict")
        try rejects("reserved subtree inside internal metadata rejects legacy migration") { try catalog!.materializeLegacyCourse(courseID: legacy.id, root: metadataConflict) }
        try check(try WorkspaceCatalog.manifest(metadataConflict) == metadataBefore && catalog!.mount(id: legacy.id) == nil, "metadata overlap failures preserve session tree and publish no course")
        let relocation = base.appendingPathComponent("RelocatedCourse")
        try fm.copyItem(at: b, to: relocation)
        try Data("unregistered additional material".utf8).write(to: relocation.appendingPathComponent("Unexpected.md"))
        let countBeforeRelocation = try library!.items().count
        try catalog!.relocate(projectID: cb.id, root: relocation)
        try check(try library!.items().count == countBeforeRelocation && !library!.items().contains(where: { $0.title == "Unexpected" }), "relocation retains known course documents without loading unknown folder contents")
        try catalog!.relocate(projectID: cb.id, root: b)
        catalog!.excludedRoots.append(b.appendingPathComponent(".ulecture"))
        let beforeConflict = try WorkspaceCatalog.manifest(b)
        try rejects("new reserved root blocks existing course sidecar access") { _ = try catalog!.metadataDirectory(documentID: another.id) }
        try rejects("new reserved root blocks existing course trash publication") { try catalog!.trash(id: another.id) }
        try check(try WorkspaceCatalog.manifest(b) == beforeConflict && library!.item(id: another.id)?.deletedAt == nil, "runtime metadata conflict preserves source sidecars and catalog")
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["passed": checks.count, "checks": checks], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
