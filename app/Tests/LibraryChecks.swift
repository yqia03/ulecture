import Foundation
import CoreGraphics
import CoreText
import AVFoundation
import Darwin

@main enum LibraryChecks {
    static var checks: [String] = []
    static func require(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw LibraryError.message("CHECK FAILED: \(label)") }
        checks.append(label)
    }
    static func rejects(_ label: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { checks.append(label); return }
        throw LibraryError.message("CHECK FAILED (accepted invalid action): \(label)")
    }
    static func main() throws {
        if CommandLine.arguments.count >= 3 && CommandLine.arguments[1] == "--crash-child" {
            try crashChild(URL(fileURLWithPath: CommandLine.arguments[2])); return
        }
        let fm = FileManager.default
        let base = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/uway-library-checks-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let libraryURL = base.appendingPathComponent("library")
        var store: LibraryStore? = try LibraryStore(rootURL: libraryURL)
        let libraryID = store!.libraryID
        let course = try store!.createItem(kind: .course, title: "语言课程")
        let otherCourse = try store!.createItem(kind: .course, title: "其他课程")
        let folder = try store!.createItem(kind: .folder, title: "第一周", parentID: course.id)
        let classroom = try store!.createItem(kind: .classroom, title: "课堂一", parentID: folder.id)
        let note = try store!.createItem(kind: .note, title: "课堂笔记", parentID: classroom.id)
        let independent = try store!.createItem(kind: .note, title: "课程独立笔记", parentID: course.id)
        let unrelated = try store!.createItem(kind: .note, title: "根层私人笔记")
        let revision = try store!.saveNote(noteID: note.id, markdown: "# 标题\n- 列表\n**重点**\n原始笔记")
        try store!.saveNote(noteID: independent.id, markdown: "课程相关笔记")
        try store!.saveNote(noteID: unrelated.id, markdown: "不得出现在课程备份")
        try require(revision.version == 1, "first note revision durable")
        try require(try store!.saveNote(noteID: note.id, markdown: revision.markdown).id == revision.id, "duplicate note save idempotent")
        try store!.saveNote(noteID: note.id, markdown: "修改后笔记")
        try require(try store!.noteRevision(noteID: note.id, version: 1)?.markdown == revision.markdown, "immutable note revision survives current edits")
        try rejects("reject classroom outside course") { _ = try store!.createItem(kind: .classroom, title: "invalid") }
        try rejects("reject course nesting") { _ = try store!.createItem(kind: .course, title: "invalid", parentID: folder.id) }
        try rejects("reject hierarchy cycle") { try store!.move(id: folder.id, parentID: classroom.id) }
        try rejects("reject cross-course classroom move") { try store!.move(id: classroom.id, parentID: otherCourse.id) }
        try rejects("reject folder carrying classroom across course") { try store!.move(id: folder.id, parentID: otherCourse.id) }
        try rejects("reject classroom note detachment") { try store!.move(id: note.id, parentID: course.id) }
        try store!.rename(id: classroom.id, title: "已重命名课堂")
        try store!.move(id: classroom.id, parentID: course.id)
        try require(try store!.item(id: classroom.id)?.id == classroom.id && store!.noteRevision(noteID: note.id)?.version == 2, "move rename preserve identity and note revisions")
        let inputPDF = base.appendingPathComponent("slides.pdf")
        try makePDF(inputPDF)
        let imported = try store!.importPDF(from: inputPDF, parentID: classroom.id)
        let pages = try store!.pdfPages(assetID: imported.assetID!)
        try require(pages.count == 2 && pages[0].text.contains("Memory") && pages[1].status == "no-extractable-text", "PDFKit real text extraction and scan/empty disclosure")
        let hash = try LibraryStore.sha256(of: inputPDF)
        try fm.moveItem(at: inputPDF, to: base.appendingPathComponent("moved-original.pdf"))
        try require(try LibraryStore.sha256(of: store!.attachmentURL(assetID: imported.assetID!)) == hash, "managed PDF independent from moved original")
        let corruptPDF = base.appendingPathComponent("broken.pdf")
        try Data("not a PDF".utf8).write(to: corruptPDF)
        let itemCount = try store!.items().count
        try rejects("corrupt PDF rejected without fake imported item") { _ = try store!.importPDF(from: corruptPDF, parentID: classroom.id) }
        try require(try store!.items().count == itemCount, "failed import leaves item set unchanged")
        var classState = try store!.classroom(id: classroom.id)!
        classState.state = "capturing"; classState.translationUserPaused = true
        classState.timelineMilliseconds = 19000
        try store!.saveClassroom(classState)
        try rejects("active classroom delete is blocked") { try store!.softDelete(id: course.id) }
        let segment = TranscriptRecord(id: UUID().uuidString, classroomID: classroom.id, epochID: UUID().uuidString, startMS: 7000, endMS: 9000, text: "Do not omit the condition.", language: "en")
        try store!.saveTranscript(segment); try store!.saveTranscript(segment)
        try require(try store!.transcripts(classroomID: classroom.id).count == 1, "confirmed transcript repeated delivery idempotent")
        var conflicting = segment; conflicting.text = "different"
        try rejects("conflicting same-revision transcript rejected") { try store!.saveTranscript(conflicting) }
        let cloud: [String: String] = ["segmentID": segment.id, "translation": "不要遗漏条件。", "noteRevisionID": revision.id]
        try store!.putRecord(collection: "translations", id: segment.id, ownerID: classroom.id, value: cloud)
        try rejects("outer transaction rollback protects all records") {
            try store!.withTransaction {
                try store!.saveNote(noteID: note.id, markdown: "UNCOMMITTED")
                throw LibraryError.message("injected transaction failure")
            }
        }
        try require(try store!.noteRevision(noteID: note.id)?.markdown == "修改后笔记", "failed transaction does not claim saved note")
        do {
            let second = try LibraryStore(rootURL: libraryURL)
            try require(second.isReadOnly, "second writer instance opens read-only")
            try rejects("read-only second writer rejects edit") { try second.rename(id: course.id, title: "forbidden") }
        }
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: libraryURL.path)
        try rejects("actual directory permission failure surfaced") { _ = try store!.saveNote(noteID: note.id, markdown: "CANNOT SAVE") }
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: libraryURL.path)
        try require(try store!.noteRevision(noteID: note.id)?.markdown == "修改后笔记", "previous durable note survives write permission failure")
        let disconnectedURL = base.appendingPathComponent("disconnected")
        try fm.moveItem(at: libraryURL, to: disconnectedURL)
        try rejects("directory loss prevents false save") { _ = try store!.saveNote(noteID: note.id, markdown: "LOST DIRECTORY") }
        try fm.moveItem(at: disconnectedURL, to: libraryURL)
        store = nil
        store = try LibraryStore(rootURL: libraryURL)
        try require(store!.libraryID == libraryID, "reopen library identity preserved")
        classState = try store!.classroom(id: classroom.id)!
        try require(classState.state == "interrupted" && classState.translationUserPaused, "reopen interrupted state retains translation pause intent")
        let gaps = try store!.records(collection: "gaps", ownerID: classroom.id, as: TimelineGap.self)
        try require(gaps.count == 1 && gaps[0].startMS == 19000, "recovery gap preserves saved timeline boundary")
        classState.state = "ended"; try store!.saveClassroom(classState)
        var restarted = classState; restarted.state = "capturing"
        try rejects("ended classroom capture terminal") { try store!.saveClassroom(restarted) }
        try store!.softDelete(id: course.id)
        try require(try store!.items().allSatisfy { $0.courseID != course.id }, "soft deletion hides entire course")
        try store!.restore(id: course.id)
        try require(try store!.item(id: note.id)?.deletedAt == nil && store!.noteRevision(noteID: note.id, version: 1)?.id == revision.id, "restore preserves tree content and historical references")
        let literalIdentity = UUID().uuidString
        let pageLinkText = "Literal identifier \(literalIdentity) and [page](uway-pdf://\(imported.assetID!)?page=1)"
        try store!.saveNote(noteID: note.id, markdown: pageLinkText)
        let recordingSource = base.appendingPathComponent("silent-recording-fixture.caf")
        let audioFormat = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
        do {
            let audioFile = try AVAudioFile(forWriting: recordingSource, settings: audioFormat.settings)
            let buffer = AVAudioPCMBuffer(pcmFormat: audioFormat, frameCapacity: 16000)!
            buffer.frameLength = 16000
            buffer.floatChannelData![0].initialize(repeating: 0, count: 16000)
            try audioFile.write(from: buffer)
        }
        let recording = try store!.importRecording(from: recordingSource, classroomID: classroom.id, epochID: segment.epochID, startMS: 5000, endMS: 6000)
        try require(try store!.recordings(classroomID: classroom.id).count == 1 && store!.attachment(id: recording.assetID)?.byteCount ?? 0 > 0, "silent file fixture recording verified without capture or playback")
        try rejects("recording duration mismatch rejected") { _ = try store!.importRecording(from: recordingSource, classroomID: classroom.id, epochID: segment.epochID, startMS: 5000, endMS: 9000) }
        let sourceID = UUID().uuidString
        let summaryID = UUID().uuidString
        let completedJobID = UUID().uuidString
        let dispatchObject: [String:Any] = ["id":UUID().uuidString,"version":1]
        let cloudObject: [String:Any] = ["classID":classroom.id,"translationUserPaused":false,
            "jobs":[["id":UUID().uuidString,"segment":["id":segment.id,"classID":classroom.id],"status":"running","historical":false],
                    ["id":completedJobID,"segment":["id":segment.id,"classID":classroom.id,"revision":1],"status":"completed","targetLanguage":"zh-Hans","dispatchVersion":1,"dispatches":[dispatchObject],"translation":["id":completedJobID,"classID":classroom.id,"segmentID":segment.id,"sourceRevision":1,"targetLanguage":"zh-Hans","dispatch":dispatchObject,"text":"不要遗漏条件。"]]],
            "summaries":[["id":summaryID,"snapshot":["id":UUID().uuidString,"classID":classroom.id,"sources":[["id":sourceID,"kind":"note","entityID":note.id,"version":1,"text":revision.markdown]]],
                "status":"completed","claims":[["id":UUID().uuidString,"text":"已保留原始笔记依据。","referenceIDs":[sourceID]]],"chunks":[],"missingChunkIDs":[]]]]
        let cloudJSON = String(decoding: try JSONSerialization.data(withJSONObject: cloudObject), as: UTF8.self)
        try store!.withTransaction { try store!.writePortableRecord(PortableRecord(collection: "cloud-state", id: classroom.id, ownerID: classroom.id, json: cloudJSON)) }
        let backup = base.appendingPathComponent("course.uwaybackup")
        try store!.backup(itemID: course.id, to: backup)
        let manifest = try store!.decoder.decode(LibraryBackupManifest.self, from: Data(contentsOf: backup.appendingPathComponent("manifest.json")))
        try require(manifest.items.contains { $0.id == independent.id } && !manifest.items.contains { $0.id == unrelated.id || $0.id == otherCourse.id }, "course backup includes scoped standalone notes excludes unrelated roots")
        let restoredStore = try LibraryStore(rootURL: base.appendingPathComponent("restored-library"))
        let restored = try restoredStore.restoreBackup(from: backup)
        let restoredClass = restored.first { $0.kind == .classroom }!
        let restoredNote = restored.first { $0.kind == .note && $0.classroomID == restoredClass.id }!
        let restoredPDF = restored.first { $0.kind == .pdf }!
        try require(Set(restored.map { $0.id }).isDisjoint(with: Set(manifest.items.map { $0.id })), "restore remaps all workspace identities")
        try require(try restoredStore.noteRevision(noteID: restoredNote.id, version: 1)?.markdown == revision.markdown, "clean restore contains historical note snapshot")
        try require(try LibraryStore.sha256(of: restoredStore.attachmentURL(assetID: restoredPDF.assetID!)) == hash, "clean restore retains exact PDF attachment")
        let latestRestoredNote = try restoredStore.noteRevision(noteID: restoredNote.id)!.markdown
        try require(latestRestoredNote.contains(literalIdentity) && latestRestoredNote.contains("uway-pdf://" + restoredPDF.assetID!), "restore preserves literal UUID prose while remapping local PDF links")
        let restoredRecording = try restoredStore.recordings(classroomID: restoredClass.id).first!
        try require(restoredRecording.startMS == 5000 && restoredRecording.endMS == 6000 && restoredRecording.assetID != recording.assetID, "restore retains only actual recorded interval with remapped attachment")
        let restoredCloudRow = try restoredStore.databaseRows("SELECT json FROM records WHERE collection='cloud-state' AND owner_id=?", [restoredClass.id]).first!
        let restoredCloud = try JSONSerialization.jsonObject(with: Data(restoredCloudRow["json"]!.utf8)) as! [String:Any]
        let restoredJobs = restoredCloud["jobs"] as! [[String:Any]]
        try require(restoredCloud["translationUserPaused"] as? Bool == true && restoredJobs[0]["status"] as? String == "needsAttention" && restoredJobs[0]["historical"] as? Bool == true, "restore pauses cloud dispatch and marks in-flight outcome unknown")
        let restoredSegment = try restoredStore.transcripts(classroomID: restoredClass.id).first!
        let restoredTranslation: [String:String] = try restoredStore.record(collection: "translations", id: restoredSegment.id, as: [String:String].self)!
        try require(restoredTranslation["segmentID"] == restoredSegment.id && restoredTranslation["noteRevisionID"] == restoredStore.noteRevision(noteID: restoredNote.id, version: 1)?.id, "opaque generic record references remap consistently")
        try require(try restoredStore.classroom(id: restoredClass.id)?.translationUserPaused == true, "restored cloud work paused until local service confirmed")
        let restoredAgain = try restoredStore.restoreBackup(from: backup)
        try require(Set(restoredAgain.map { $0.id }).isDisjoint(with: Set(restored.map { $0.id })), "repeat restore creates new identities without overwriting")
        let classBackup = base.appendingPathComponent("classroom.uwaybackup")
        try store!.backup(itemID: classroom.id, to: classBackup)
        let classManifest = try store!.decoder.decode(LibraryBackupManifest.self, from: Data(contentsOf: classBackup.appendingPathComponent("manifest.json")))
        try require(classManifest.items.contains { $0.id == course.id } && !classManifest.items.contains { $0.id == independent.id }, "single classroom backup only includes course dependency and classroom")
        let exported = base.appendingPathComponent("readable-export")
        try store!.exportReadable(itemID: course.id, to: exported)
        let srt = try String(contentsOf: exported.appendingPathComponent("subtitles-\(classroom.id).srt"), encoding: .utf8)
        try require(srt.contains("00:00:07,000 --> 00:00:09,000") && srt.contains("不要遗漏条件。"), "bilingual SRT preserves actual gap/time origin")
        let summaryFiles = try fm.contentsOfDirectory(at: exported, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("summary-") }
        let summaryText = try String(contentsOf: summaryFiles.first!, encoding: .utf8)
        try require(summaryText.contains("AI 生成总结") && summaryText.contains(revision.markdown) && summaryText.contains(sourceID), "cloud summary Markdown includes immutable source text and citations")
        let notesExport = base.appendingPathComponent("notes-and-summaries")
        try store!.exportReadable(itemID: course.id, to: notesExport, selection: .notesAndSummaries)
        let noteNames = try fm.contentsOfDirectory(atPath: notesExport.path)
        try require(noteNames.contains { $0.hasPrefix("note-") } && noteNames.contains { $0.hasPrefix("summary-") } && !noteNames.contains { $0.hasPrefix("transcript-") || $0.hasPrefix("subtitles-") }, "selected notes and summaries export excludes transcripts and subtitles")
        let transcriptsExport = base.appendingPathComponent("transcripts-and-translations")
        try store!.exportReadable(itemID: course.id, to: transcriptsExport, selection: .transcriptsAndTranslations)
        let transcriptNames = try fm.contentsOfDirectory(atPath: transcriptsExport.path)
        try require(transcriptNames.contains { $0.hasSuffix(".txt") } && transcriptNames.contains { $0.hasSuffix(".srt") } && transcriptNames.contains { $0.hasSuffix(".vtt") } && !transcriptNames.contains { $0.hasPrefix("note-") || $0.hasPrefix("summary-") }, "selected transcript and translation export includes subtitles without notes")
        let badReferenceBackup = base.appendingPathComponent("bad-reference.uwaybackup")
        try fm.copyItem(at: backup, to: badReferenceBackup)
        var badReferenceManifest = manifest
        let cloudIndex = badReferenceManifest.records.firstIndex { $0.collection == "cloud-state" }!
        badReferenceManifest.records[cloudIndex].json = badReferenceManifest.records[cloudIndex].json.replacingOccurrences(of: "\"version\":1", with: "\"version\":999")
        try store!.encoder.encode(badReferenceManifest).write(to: badReferenceBackup.appendingPathComponent("manifest.json"))
        try rejects("restore rejects missing summary note revision reference") { _ = try restoredStore.restoreBackup(from: badReferenceBackup) }
        let corruptBackup = base.appendingPathComponent("corrupt.uwaybackup")
        try fm.copyItem(at: backup, to: corruptBackup)
        let corruptedAsset = corruptBackup.appendingPathComponent(manifest.attachments[0].relativePath)
        try Data("truncated".utf8).write(to: corruptedAsset)
        let existingRestoredCount = try restoredStore.items().count
        try rejects("corrupt backup attachment rejected") { _ = try restoredStore.restoreBackup(from: corruptBackup) }
        try require(try restoredStore.items().count == existingRestoredCount, "failed restore leaves existing data unchanged")
        let unsafe = base.appendingPathComponent("unsafe.uwaybackup")
        try fm.copyItem(at: backup, to: unsafe)
        var unsafeManifest = manifest; unsafeManifest.attachments[0].relativePath = "../outside.pdf"
        try store!.encoder.encode(unsafeManifest).write(to: unsafe.appendingPathComponent("manifest.json"))
        try rejects("backup path traversal rejected before import") { _ = try restoredStore.restoreBackup(from: unsafe) }
        let duplicateKeys = base.appendingPathComponent("duplicate-remapped-keys.uwaybackup")
        try fm.copyItem(at: backup, to: duplicateKeys)
        let duplicateManifestURL = duplicateKeys.appendingPathComponent("manifest.json")
        var duplicateManifest = try JSONDecoder().decode(LibraryBackupManifest.self, from: Data(contentsOf: duplicateManifestURL))
        let keyID = UUID().uuidString
        let duplicateJSON = String(decoding: try JSONSerialization.data(withJSONObject: [keyID.uppercased(): "a", keyID.lowercased(): "b"]), as: UTF8.self)
        duplicateManifest.records.append(PortableRecord(collection: "custom-refs", id: UUID().uuidString, ownerID: course.id, json: duplicateJSON))
        try JSONEncoder().encode(duplicateManifest).write(to: duplicateManifestURL)
        try rejects("case-colliding portable reference keys rejected without process crash") { _ = try restoredStore.restoreBackup(from: duplicateKeys) }
        let symbolic = base.appendingPathComponent("symlink.uwaybackup")
        try fm.copyItem(at: backup, to: symbolic)
        let symbolicAsset = symbolic.appendingPathComponent(manifest.attachments[0].relativePath)
        try fm.removeItem(at: symbolicAsset)
        try fm.createSymbolicLink(at: symbolicAsset, withDestinationURL: base.appendingPathComponent("moved-original.pdf"))
        try rejects("backup symlink escape rejected") { _ = try restoredStore.restoreBackup(from: symbolic) }
        try Data("unfinished".utf8).write(to: libraryURL.appendingPathComponent("staging/interrupted.partial"))
        store = nil; store = try LibraryStore(rootURL: libraryURL)
        try require(store!.recoveryWarnings.contains { $0.contains("未完成导入") }, "interrupted import disclosed and not marked complete")
        let futureLibrary = base.appendingPathComponent("future-library")
        try fm.createDirectory(at: futureLibrary, withIntermediateDirectories: true)
        let futureDatabaseURL = futureLibrary.appendingPathComponent("library.sqlite")
        do {
            let database = try SQLiteDatabase(url: futureDatabaseURL, readOnly: false)
            try database.execute("PRAGMA user_version=99")
            try database.execute("CREATE TABLE future_content(value TEXT)")
            try database.execute("INSERT INTO future_content(value) VALUES('retain')")
        }
        let futureHash = try LibraryStore.sha256(of: futureDatabaseURL)
        try rejects("future schema refused without speculative migration") { _ = try LibraryStore(rootURL: futureLibrary) }
        try require(try LibraryStore.sha256(of: futureDatabaseURL) == futureHash, "unsupported schema database remains byte-identical")
        let crashDirectory = base.appendingPathComponent("crash-library")
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        child.arguments = ["--crash-child", crashDirectory.path]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run(); child.waitUntilExit()
        try require(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL, "real helper process terminated with SIGKILL")
        let afterCrash = try LibraryStore(rootURL: crashDirectory)
        let crashItems = try afterCrash.items()
        let crashNote = crashItems.first { $0.kind == .note }!
        try require(try afterCrash.noteRevision(noteID: crashNote.id)?.markdown == "committed-before-kill", "SIGKILL preserves committed note and rejects uncommitted tail")
        let crashClass = crashItems.first { $0.kind == .classroom }!
        try require(try afterCrash.classroom(id: crashClass.id)?.state == "interrupted" && afterCrash.transcripts(classroomID: crashClass.id).count == 1, "SIGKILL recovery keeps committed transcript and marks capture interrupted")
        let recoveredClass = try afterCrash.classroom(id: crashClass.id)!
        let lastCommit = Double(try String(contentsOf: crashDirectory.appendingPathComponent("last-commit.txt"), encoding: .utf8))!
        let crashGaps = try afterCrash.records(collection: "gaps", ownerID: crashClass.id, as: TimelineGap.self)
        try require(recoveredClass.timelineMilliseconds == 2000 && crashGaps.first?.startMS == 2000 && abs(recoveredClass.updatedAt.timeIntervalSinceReferenceDate - lastCommit) < 0.001, "SIGKILL recovery anchors gap at last committed transcript end and preserves wall time")
        let report: [String:Any] = ["suite":"LibraryChecks", "passed":checks.count, "checks":checks, "evidenceDirectory":base.path,
            "scope":"Real local SQLite/PDFKit/filesystem/process checks only. No audio capture, playback, account, cloud request, or full product acceptance."]
        let output = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
        try output.write(to: base.appendingPathComponent("library-checks.json"), options: .atomic)
        print(String(decoding: output, as: UTF8.self))
    }
    static func makePDF(_ url: URL) throws {
        var bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let context = CGContext(url as CFURL, mediaBox: &bounds, nil) else { throw LibraryError.message("Cannot create PDF fixture") }
        context.beginPDFPage(nil)
        let font = CTFontCreateWithName("Helvetica" as CFString, 16, nil)
        let attributes: [NSAttributedString.Key:Any] = [NSAttributedString.Key(kCTFontAttributeName as String):font]
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Memory does not improve without practice.", attributes: attributes))
        context.textPosition = CGPoint(x: 40, y: 740); CTLineDraw(line, context)
        context.endPDFPage()
        context.beginPDFPage(nil); context.setFillColor(CGColor(gray: 0.6, alpha: 1)); context.fill(CGRect(x: 50, y: 50, width: 200, height: 100)); context.endPDFPage()
        context.closePDF()
    }
    static func crashChild(_ directory: URL) throws {
        let store = try LibraryStore(rootURL: directory)
        let course = try store.createItem(kind: .course, title: "Crash course")
        let classroom = try store.createItem(kind: .classroom, title: "Crash class", parentID: course.id)
        let note = try store.createItem(kind: .note, title: "Crash note", parentID: classroom.id)
        try store.saveNote(noteID: note.id, markdown: "committed-before-kill")
        var state = try store.classroom(id: classroom.id)!; state.state = "capturing"; state.timelineMilliseconds = 0; try store.saveClassroom(state)
        try store.saveTranscript(TranscriptRecord(id: UUID().uuidString, classroomID: classroom.id, epochID: UUID().uuidString, startMS: 1000, endMS: 2000, text: "committed", language: "en"))
        let committed = try store.classroom(id: classroom.id)!
        try String(committed.updatedAt.timeIntervalSinceReferenceDate).write(to: directory.appendingPathComponent("last-commit.txt"), atomically: true, encoding: .utf8)
        try store.withTransaction {
            try store.saveNote(noteID: note.id, markdown: "uncommitted-before-kill")
            kill(getpid(), SIGKILL)
        }
    }
}
