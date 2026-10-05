import Foundation

@main struct CloudBackupChecks {
    @MainActor static func main() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("cloud-backup-shape-\(UUID().uuidString)")
        let library = try LibraryStore(rootURL: root.appendingPathComponent("source"))
        let course = try library.createItem(kind: .course, title: "Cloud backup contract")
        let classroom = try library.createItem(kind: .classroom, title: "Snapshot", parentID: course.id)
        let note = try library.createItem(kind: .note, title: "Note", parentID: classroom.id)
        let revision = try library.saveNote(noteID: note.id, markdown: "# Notes\n原始笔记版本")
        let row = TranscriptRecord(id: UUID().uuidString, classroomID: classroom.id, epochID: UUID().uuidString, startMS: 7000, endMS: 9000, text: "The condition is necessary.", language: "en")
        try library.saveTranscript(row)
        let source = CloudSegment(id: row.id, classID: classroom.id, revision: row.revision, text: row.text, language: row.language, startMS: row.startMS, endMS: row.endMS, confirmedAt: row.confirmedAt)
        let dispatch = CloudDispatch(version: 2, configuration: CloudConfiguration(provider: .googleCloudStandard, projectID: "project-test", version: 4), preset: .current(for: .googleCloudStandard), sentAt: Date())
        var running = CloudTranslationJob(segment: source, targetLanguage: "zh-Hans", status: .running, attempts: 1, dispatchVersion: 2, dispatches: [dispatch])
        running.historical = false
        var completed = CloudTranslationJob(segment: source, targetLanguage: "zh-Hant", status: .completed, attempts: 1, dispatchVersion: 2, dispatches: [dispatch])
        completed.translation = CloudTranslation(id: completed.id, segmentID: row.id, classID: classroom.id, sourceRevision: row.revision, targetLanguage: "zh-Hant", text: "該條件是必要的。", dispatch: dispatch, savedAt: Date(), historical: false)
        let noteSource = SummarySource(kind: .note, entityID: note.id, version: revision.version, text: revision.markdown)
        let transcriptSource = SummarySource(kind: .transcript, entityID: row.id, version: row.revision, text: row.text, startMS: row.startMS, endMS: row.endMS)
        let snapshot = SummarySnapshot(classID: classroom.id, sources: [noteSource, transcriptSource])
        var summary = CloudSummary(snapshot: snapshot, dispatch: dispatch)
        summary.claims = [SummaryClaim(text: "已处理部分的结论。", referenceIDs: [noteSource.id])]
        summary.chunks = [SummaryChunkCoverage(spans: [SummaryCoverageSpan(sourceID: noteSource.id, startCharacter: 0, characterCount: noteSource.text.count)], status: "completed"), SummaryChunkCoverage(spans: [SummaryCoverageSpan(sourceID: transcriptSource.id, startCharacter: 0, characterCount: transcriptSource.text.count)])]
        summary.completedChunkIDs = [summary.chunks[0].id]; summary.missingChunkIDs = [summary.chunks[1].id]
        let state = CloudState(classID: classroom.id, jobs: [running, completed], summaries: [summary], usage: [CloudUsage(id: dispatch.id, provider: .googleCloudStandard, model: dispatch.preset.model, inputTokens: nil, outputTokens: nil, status: "unknown", at: Date())])
        try library.putRecord(collection: "cloud-state", id: classroom.id, ownerID: classroom.id, value: state)
        try library.saveNote(noteID: note.id, markdown: "后来的笔记版本，不可改变旧总结")
        let backup = root.appendingPathComponent("full.uwaybackup")
        try library.backup(itemID: course.id, to: backup)
        let target = try LibraryStore(rootURL: root.appendingPathComponent("restored"))
        let items = try target.restoreBackup(from: backup)
        let newClass = items.first { $0.kind == .classroom }!
        let newNote = items.first { $0.kind == .note }!
        let newRow = try target.transcripts(classroomID: newClass.id).first!
        let restored = try target.record(collection: "cloud-state", id: newClass.id, as: CloudState.self)!
        var checks: [String] = []
        func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try condition() else { throw NSError(domain: "CloudBackupChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }; checks.append(label)
        }
        try check(restored.translationUserPaused && restored.jobs[0].status == .needsAttention && restored.jobs[0].historical, "restored in-flight translation paused with unknown outcome")
        try check(restored.classID == newClass.id && restored.jobs.allSatisfy { $0.segment.classID == newClass.id && $0.segment.id == newRow.id }, "typed CloudState class and transcript links remapped")
        let newSummary = restored.summaries[0]
        let restoredNoteSource = newSummary.snapshot.sources.first { $0.kind == .note }!
        try check(restoredNoteSource.entityID == newNote.id && restoredNoteSource.version == 1 && restoredNoteSource.text == revision.markdown, "fixed old note version survives newer saved notes and identity remap")
        try check(newSummary.snapshot.id != snapshot.id && newSummary.id != summary.id && restored.jobs[0].dispatches[0].id != dispatch.id, "snapshot summary and dispatch identities remapped")
        try check(newSummary.claims[0].referenceIDs == [restoredNoteSource.id] && newSummary.chunks[0].spans[0].sourceID == restoredNoteSource.id, "claim and exact coverage source IDs remap consistently")
        try check(newSummary.completedChunkIDs == [newSummary.chunks[0].id] && newSummary.missingChunkIDs == [newSummary.chunks[1].id], "partial snapshot completed and missing chunks retained")
        try check(restored.usage[0].id == restored.jobs[0].dispatches[0].id && restored.jobs[1].translation?.dispatch.id == restored.usage[0].id, "usage dispatch and translation provenance stays connected")
        try check(restored.jobs[1].translation?.segmentID == newRow.id && restored.jobs[1].translation?.classID == newClass.id && restored.jobs[1].translation?.id == restored.jobs[1].id, "completed result identities and source links remapped")
        let controller = CloudController(state: restored, monitorNetwork: false)
        try check(controller.state.summaries[0].status == "interrupted" && !controller.summaryRunning && !controller.credentialUnlocked && !controller.speech.enabled, "reopened partial summary inert and visibly interrupted; no credential access or playback")
        let encoded = String(data: try JSONEncoder().encode(restored), encoding: .utf8)!
        try check(!encoded.contains("credentialReference") && !encoded.contains("access_token") && !encoded.contains("private_key") && !encoded.contains("Authorization"), "actual CloudState representation contains no credentials or credential references")
        // Probe corrupt result provenance separately; record actual acceptance.
        let tampered = root.appendingPathComponent("tampered-result.uwaybackup")
        try FileManager.default.copyItem(at: backup, to: tampered)
        let manifestURL = tampered.appendingPathComponent("manifest.json")
        var manifest = try JSONDecoder().decode(LibraryBackupManifest.self, from: Data(contentsOf: manifestURL))
        let cloudIndex = manifest.records.firstIndex { $0.collection == "cloud-state" }!
        var badState = state
        badState.jobs[1].translation!.segmentID = UUID().uuidString
        manifest.records[cloudIndex].json = String(data: try JSONEncoder().encode(badState), encoding: .utf8)!
        try JSONEncoder().encode(manifest).write(to: manifestURL)
        var acceptsDanglingTranslation = false
        do { _ = try target.restoreBackup(from: tampered); acceptsDanglingTranslation = true } catch { }
        func accepts(_ name: String, mutate: (inout CloudState) -> Void) throws -> Bool {
            let destination = root.appendingPathComponent(name + ".uwaybackup")
            try FileManager.default.copyItem(at: backup, to: destination)
            var payload = state; mutate(&payload)
            var doc = try JSONDecoder().decode(LibraryBackupManifest.self, from: Data(contentsOf: backup.appendingPathComponent("manifest.json")))
            doc.records[cloudIndex].json = String(data: try JSONEncoder().encode(payload), encoding: .utf8)!
            try JSONEncoder().encode(doc).write(to: destination.appendingPathComponent("manifest.json"))
            do { _ = try target.restoreBackup(from: destination); return true } catch { return false }
        }
        let acceptsUnknownCitation = try accepts("tampered-citation") { $0.summaries[0].claims[0].referenceIDs = [UUID().uuidString] }
        let acceptsWrongTranscriptTime = try accepts("tampered-transcript-time") { $0.summaries[0].snapshot.sources[1].startMS = 900000; $0.summaries[0].snapshot.sources[1].endMS = 999000 }
        let acceptsUnknownCompletedChunk = try accepts("tampered-completed-chunk") { $0.summaries[0].completedChunkIDs = [UUID().uuidString] }
        try check(!acceptsDanglingTranslation, "backup rejects result provenance with dangling transcript ID")
        try check(!acceptsUnknownCitation, "backup rejects citation ID outside fixed snapshot")
        try check(!acceptsWrongTranscriptTime, "backup rejects same revision snapshot text with forged transcript time")
        try check(!acceptsUnknownCompletedChunk, "backup rejects completed chunk IDs outside declared coverage")
        let orphanURL = root.appendingPathComponent("tampered-cloud-record-id.uwaybackup")
        try FileManager.default.copyItem(at: backup, to: orphanURL)
        var orphanManifest = try JSONDecoder().decode(LibraryBackupManifest.self, from: Data(contentsOf: backup.appendingPathComponent("manifest.json")))
        orphanManifest.records[cloudIndex].id = UUID().uuidString
        try JSONEncoder().encode(orphanManifest).write(to: orphanURL.appendingPathComponent("manifest.json"))
        var acceptsOrphanRecord = false
        do { _ = try target.restoreBackup(from: orphanURL); acceptsOrphanRecord = true } catch { }
        try check(!acceptsOrphanRecord, "backup rejects inaccessible cloud state record ID outside its owning classroom")
        let report: [String: Any] = ["kind":"real LibraryStore backup restore with full production CloudState types; no provider calls", "passed":checks.count,"checks":checks,"directory":root.path,"providerCalls":0,"keychainReads":0,"audioPlayback":0,"corruptTranslationReferenceAccepted":acceptsDanglingTranslation,"corruptCitationAccepted":acceptsUnknownCitation,"corruptTranscriptTimeAccepted":acceptsWrongTranscriptTime,"corruptCompletedChunkAccepted":acceptsUnknownCompletedChunk,"corruptCloudRecordIDAccepted":acceptsOrphanRecord]
        print(String(data: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys]), encoding: .utf8)!)
    }
}
