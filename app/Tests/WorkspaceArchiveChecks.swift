import Foundation
import PDFKit
import AppKit
import AVFoundation
import Darwin

@main struct WorkspaceArchiveChecks {
    static func main() throws {
        let base = URL(fileURLWithPath: CommandLine.arguments[1]), fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        if CommandLine.arguments.count > 2 {
            let phase = CommandLine.arguments[2]
            let library = try LibraryStore(rootURL: base.appendingPathComponent("crash-catalog-" + phase))
            try library.configureTranscriptStorage(rootURL: base.appendingPathComponent("crash-transcripts-" + phase))
            let target = base.appendingPathComponent("crash-target-" + phase)
            try fm.createDirectory(at: target, withIntermediateDirectories: true)
            if phase == "session-persisted" { library.onSessionPersisted = { _ in kill(getpid(), SIGKILL) } }
            _ = try WorkspaceArchive(catalog: WorkspaceCatalog(library: library)).restore(from: base.appendingPathComponent("course.ulbackup"), into: target) { step in if step == phase { kill(getpid(), SIGKILL) } }
            fatalError("crash point not reached")
        }
        var checks: [String] = []
        func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws { guard try value() else { throw LibraryError.message("FAILED: " + name) }; checks.append(name); FileHandle.standardError.write(Data(("PASS " + name + "\n").utf8)) }
        func rejects(_ name: String, _ work: () throws -> Void) throws { do { try work() } catch { checks.append(name); return }; throw LibraryError.message("FAILED: " + name) }
        let courseRoot = base.appendingPathComponent("course"), linkedRoot = base.appendingPathComponent("linked-course")
        for root in [courseRoot, linkedRoot] { try fm.createDirectory(at: root, withIntermediateDirectories: true) }
        try Data("unchanged unrelated".utf8).write(to: linkedRoot.appendingPathComponent("unrelated.txt"))
        try Data("# Shared text\n".utf8).write(to: linkedRoot.appendingPathComponent("shared.md"))
        let package = courseRoot.appendingPathComponent("Blocks.ulnote")
        try fm.createDirectory(at: package.appendingPathComponent("assets"), withIntermediateDirectories: true)
        try fm.createDirectory(at: package.appendingPathComponent("revisions"), withIntermediateDirectories: true)
        let packageID = UUID().uuidString, blockID = UUID().uuidString, proseID = UUID().uuidString
        let noteObject: [String: Any] = ["format":"ulecture-block-note", "id":packageID, "revision":1, "blocks":[["id":blockID,"kind":"paragraph","text":"literal " + proseID]]]
        let noteData = try JSONSerialization.data(withJSONObject: noteObject, options: [.sortedKeys])
        try noteData.write(to: package.appendingPathComponent("note.json"))
        let originalHash = try LibraryStore.sha256(of: package.appendingPathComponent("note.json"))
        try noteData.write(to: package.appendingPathComponent("revisions/1-" + originalHash + ".json"))
        try Data([1,2,3,4]).write(to: package.appendingPathComponent("assets/image.png"))
        let pdfURL = courseRoot.appendingPathComponent("Slides.pdf")
        var bounds = CGRect(x: 0, y: 0, width: 200, height: 300)
        let context = CGContext(pdfURL as CFURL, mediaBox: &bounds, nil)!
        context.beginPDFPage(nil); context.setFillColor(CGColor(gray: 0.8, alpha: 1)); context.fill(CGRect(x: 10, y: 20, width: 60, height: 70)); context.endPDFPage(); context.closePDF()
        let library = try LibraryStore(rootURL: base.appendingPathComponent("catalog")), catalog = WorkspaceCatalog(library: library)
        let course = try catalog.createCourse(title: "course"), linked = try catalog.createCourse(title: "linked-course")
        for source in [package, pdfURL] { _ = try catalog.importDocument(from: source, parentID: course.id) }
        for filename in ["unrelated.txt", "shared.md"] { _ = try catalog.importDocument(from: linkedRoot.appendingPathComponent(filename), parentID: linked.id) }
        try library.configureTranscriptStorage(rootURL: base.appendingPathComponent("transcripts"))
        let note = try library.items().first { $0.title == "Blocks" }!, slides = try library.items().first { $0.title == "Slides" }!, shared = try library.items().first { $0.title == "shared" }!
        let classroom = try catalog.create(kind: .classroom, title: "Class", parentID: course.id)
        try catalog.link(documentID: shared.id, sessionID: classroom.id)
        try catalog.link(documentID: note.id, sessionID: classroom.id)
        let text = TranscriptRecord(id: UUID().uuidString, classroomID: classroom.id, epochID: UUID().uuidString, startMS: 1234, endMS: 6789, text: "Keep literal " + proseID, language: "en")
        try library.saveTranscript(text)
        let annotationID = UUID().uuidString, pdfHash = try LibraryStore.sha256(of: pdfURL)
        let metadata = try catalog.metadataDirectory(documentID: slides.id)
        let version = metadata.appendingPathComponent("versions/" + pdfHash)
        try fm.createDirectory(at: version, withIntermediateDirectories: true)
        try fm.copyItem(at: pdfURL, to: version.appendingPathComponent("source.pdf"))
        try JSONSerialization.data(withJSONObject: ["documentID": slides.id,"sourceHash":pdfHash,"annotations":[["id":annotationID,"text":"保留正文 " + proseID]]]).write(to: version.appendingPathComponent("annotations.json"))
        let wav = base.appendingPathComponent("silent.caf")
        let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        do { let output = try AVAudioFile(forWriting: wav, settings: format.settings); let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16000)!; buffer.frameLength = 16000; memset(buffer.floatChannelData![0], 0, 16000 * 4); try output.write(from: buffer) }
        let recording = try library.importRecording(from: wav, classroomID: classroom.id, epochID: text.epochID, startMS: 5000, endMS: 6000)
        let snapshotID = UUID().uuidString, turnID = UUID().uuidString
        let snapshot: [String:Any] = ["id":snapshotID,"sources":[["id":"S1","documentID":shared.id,"text":"unchanged snapshot " + proseID,"sourceHash":"frozen-hash","version":1]]]
        let turn: [String:Any] = ["id":turnID,"conversationID":classroom.id,"snapshotID":snapshotID,"question":"literal " + proseID,"runs":[["id":UUID().uuidString,"state":"running","text":"partial"]]]
        try library.withTransaction {
        try library.writePortableRecord(PortableRecord(collection:"assistant-snapshots",id:snapshotID,ownerID:classroom.id,json:String(decoding:try JSONSerialization.data(withJSONObject:snapshot),as:UTF8.self)))
        try library.writePortableRecord(PortableRecord(collection:"assistant-turns",id:turnID,ownerID:classroom.id,json:String(decoding:try JSONSerialization.data(withJSONObject:turn),as:UTF8.self)))
        }
        let archive = base.appendingPathComponent("course.ulbackup")
        try WorkspaceArchive(catalog: catalog).backup(itemID: course.id, to: archive)
        let manifest = try JSONDecoder().decode(WorkspaceArchiveManifest.self, from: Data(contentsOf: archive.appendingPathComponent("manifest.json")))
        try check(manifest.items.contains { $0.id == shared.id } && manifest.items.contains { $0.id == linked.id } && !manifest.items.contains { $0.title == "unrelated" }, "reference closure includes linked external document and only required ancestors")
        try check(!String(data: try Data(contentsOf: archive.appendingPathComponent("manifest.json")), encoding:.utf8)!.contains(try catalog.projectRoot(course.id).path), "portable manifest excludes original absolute project path")
        try check(manifest.payloads.contains { $0.path == "document-data/" + slides.id }, "PDF original versions and editable annotations are included")
        let restoredLibrary = try LibraryStore(rootURL: base.appendingPathComponent("restored-catalog")), restoredCatalog = WorkspaceCatalog(library: restoredLibrary)
        try restoredLibrary.configureTranscriptStorage(rootURL: base.appendingPathComponent("restored-transcripts"))
        let restoreRoot = base.appendingPathComponent("Restored")
        try fm.createDirectory(at: restoreRoot, withIntermediateDirectories: true)
        let restored = try WorkspaceArchive(catalog: restoredCatalog).restore(from: archive, into: restoreRoot)
        let rn = restored.first { $0.title == "Blocks" }!, rs = restored.first { $0.title == "Slides" }!, rc = restored.first { $0.title == "Class" }!
        try check(Set(restored.map(\.id)).isDisjoint(with: manifest.items.map(\.id)), "restore assigns new item identities without colliding with original library")
        let restoredNoteURL = try restoredCatalog.documentURL(id: rn.id)
        let restoredNote = try JSONSerialization.jsonObject(with: Data(contentsOf: restoredNoteURL.appendingPathComponent("note.json"))) as! [String:Any]
        let restoredBlock = (restoredNote["blocks"] as! [[String:Any]])[0]
        try check(restoredNote["id"] as? String != packageID && restoredBlock["id"] as? String != blockID && restoredBlock["text"] as? String == "literal " + proseID, "block identities remapped while arbitrary UUID prose remains exact")
        try check(try Data(contentsOf: restoredNoteURL.appendingPathComponent("assets/image.png")) == Data([1,2,3,4]), "note assets survive restore byte for byte")
        try check(try fm.contentsOfDirectory(atPath: restoredNoteURL.appendingPathComponent("revisions").path).first!.contains(LibraryStore.sha256(of: restoredNoteURL.appendingPathComponent("note.json"))), "rewritten immutable revision filename matches new content hash")
        let restoredMeta = try restoredCatalog.metadataDirectory(documentID: rs.id)
        let annotation = try JSONSerialization.jsonObject(with: Data(contentsOf: restoredMeta.appendingPathComponent("versions/" + pdfHash + "/annotations.json"))) as! [String:Any]
        try check(annotation["documentID"] as? String == rs.id && annotation["sourceHash"] as? String == pdfHash, "annotation document reference remapped without changing immutable PDF source hash")
        let restoredText = try restoredLibrary.transcripts(classroomID: rc.id).first!
        try check(restoredText.id != text.id && restoredText.text == text.text && restoredText.startMS == 1234 && restoredText.endMS == 6789, "transcript identities remapped with exact text and time mapping")
        let recording2 = try restoredLibrary.recordings(classroomID: rc.id).first!
        let recordingURL = try restoredLibrary.attachmentURL(assetID: recording2.assetID)
        try check(recording2.assetID != recording.assetID && recordingURL.path.contains("restored-transcripts") && (try LibraryStore.sha256(of: recordingURL)) == LibraryStore.sha256(of: wav), "recording bytes restored into independent session storage")
        try check(try restoredCatalog.linkedDocumentIDs(sessionID: rc.id).count == 2, "many-to-many session document links retain new identities")
        let restoredTurn = try restoredLibrary.databaseRows("SELECT json FROM records WHERE collection='assistant-turns'")[0]["json"]!
        try check(restoredTurn.contains("interrupted") && restoredTurn.contains("partial") && restoredTurn.contains(proseID) && !restoredTurn.contains(snapshotID), "AI partial text and fixed snapshot link survive with interrupted non-dispatching state")
        try check(try restoredLibrary.transcriptStore!.records(for: rc)!.contains { $0.collection == "assistant-snapshots" }, "restored session database immediately contains AI snapshot closure")
        try check(try WorkspaceCatalog.manifest(pdfURL) == WorkspaceCatalog.manifest(restoredCatalog.documentURL(id: rs.id)), "original and restored PDF bytes identical")
        let before = try restoredLibrary.items().count
        let corrupt = base.appendingPathComponent("corrupt.ulbackup")
        try fm.copyItem(at: archive, to: corrupt)
        try Data("broken".utf8).write(to: corrupt.appendingPathComponent("documents/" + note.id + ".ulnote/note.json"))
        try rejects("corrupt package aborts before mutation") { _ = try WorkspaceArchive(catalog: restoredCatalog).restore(from: corrupt, into: restoreRoot) }
        try check(try restoredLibrary.items().count == before, "failed restore leaves existing catalog and resources intact")
        for phase in ["published", "session-persisted", "committed"] {
            let process = Process(); process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); process.arguments = [base.path, phase]
            try process.run(); process.waitUntilExit()
            try check(process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGKILL, "real child process interrupted after " + phase)
            let retryLibrary = try LibraryStore(rootURL: base.appendingPathComponent("crash-catalog-" + phase))
            try retryLibrary.configureTranscriptStorage(rootURL: base.appendingPathComponent("crash-transcripts-" + phase))
            let result = try WorkspaceArchive(catalog: WorkspaceCatalog(library: retryLibrary)).restore(from: archive, into: base.appendingPathComponent("crash-target-" + phase))
            try check(result.count == manifest.items.count && (try retryLibrary.items().count) == manifest.items.count, "restart reuses restore journal and identities after " + phase)
        }
        let oldHash = try catalog.locator(id: note.id)!.contentHash
        let handle = try FileHandle(forWritingTo: catalog.documentURL(id: note.id).appendingPathComponent("note.json")); try handle.write(contentsOf: Data(" ".utf8)); try handle.close()
        try catalog.scan(projectID: course.id)
        try check(try catalog.locator(id: note.id)!.contentHash != oldHash, "in-place note content edits refresh catalog even without package mtime changes")
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["passed":checks.count,"checks":checks], options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
    }
}
