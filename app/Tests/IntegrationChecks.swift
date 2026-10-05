import Foundation
import AppKit
import AVFoundation
import PDFKit
import Combine

@main struct IntegrationChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        guard let index = CommandLine.arguments.firstIndex(of: "--ui-test-library"), index + 1 < CommandLine.arguments.count else { fatalError("--ui-test-library <fresh isolated path> is required") }
        let root = URL(fileURLWithPath: CommandLine.arguments[index + 1])
        guard !FileManager.default.fileExists(atPath: root.path) else { fatalError("Use a fresh directory") }
        var checks: [[String: Any]] = []
        func check(_ name: String, _ condition: Bool) { checks.append(["name": name, "pass": condition]); print("\(condition ? "PASS" : "FAIL") \(name)") }
        let model = AppModel()
        guard let library = model.library else { throw LibraryError.message(model.error ?? "No test library") }
        check("startup_has_no_capture_or_speech_or_cloud_credentials", model.audio.phase == .ready && model.probe.phase != .capturing && !model.serviceSettings.credentialUnlocked && model.clouds.isEmpty)
        model.create(.course, title: "Integration course")
        let course = model.selected!
        model.create(.classroom, title: "Local coordinator test", parentID: course.id)
        let classroom = model.selected!
        let note = model.classroomNote(classroom.id)!
        let selection = DocumentSelection(documentID: note.id, text: "Fictional selected context")
        var selectionPublications = 0
        let selectionObserver = model.objectWillChange.sink { selectionPublications += 1 }
        model.documentSelection = selection
        check("native_selection_reaches_assistant_without_global_publication", model.assistant?.selection == selection && selectionPublications == 0)
        model.documentSelection = nil
        check("native_selection_clear_reaches_assistant", model.assistant?.selection == nil && selectionPublications == 0)
        selectionObserver.cancel()
        check("classroom_has_stable_linked_note", note.classroomID == classroom.id && model.currentClass?.state == "draft")
        model.loadDraft(note.id); model.editNote(note.id, value: "# Saved notes\n\n- **Version one**")
        model.openItem(course)
        _ = model.flushDrafts()
        check("navigation_flush_keeps_note", try library.noteRevision(noteID: note.id)?.markdown.contains("Version one") == true)
        model.openItem(classroom)
        check("new_classroom_from_classroom_uses_course_parent", model.suitableParent(for: .classroom) == course.id)
        model.create(.note, title: "Second classroom note", parentID: classroom.id)
        let secondNote = model.selected!
        model.loadDraft(secondNote.id); model.editNote(secondNote.id, value: "Second note material"); _ = model.flushDrafts()
        check("tree_note_selection_opens_exact_note", model.classroomNote(classroom.id)?.id == secondNote.id)
        check("new_classroom_from_note_uses_course_parent", model.suitableParent(for: .classroom) == course.id)
        let allNotesSnapshot = try model.buildSummarySnapshot(classroom.id, assetIDs: [], useTranscript: false, useNotes: true)
        check("summary_uses_all_saved_class_notes", Set(allNotesSnapshot.sources.map(\.entityID)) == Set([note.id, secondNote.id]))
        let summary = CloudSummary(snapshot: allNotesSnapshot, dispatch: CloudDispatch(version: 1, configuration: model.cloudConfiguration, preset: .current(for: model.cloudConfiguration.provider), sentAt: Date()))
        check("unchanged_summary_snapshot_is_current", !model.summaryIsStale(summary))
        model.editNote(secondNote.id, value: "Second note changed"); _ = model.flushDrafts()
        check("editing_any_included_note_marks_summary_stale", model.summaryIsStale(summary))
        model.openItem(note)
        check("switching_back_restores_first_note", model.classroomNote(classroom.id)?.id == note.id)
        model.openLibrary(root, remember: false)
        check("reselect_library_keeps_writer", model.library === library && !library.isReadOnly)
        let pdfURL = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-lecture.pdf")
        let data = NSMutableData()
        let consumer = CGDataConsumer(data: data)!
        var bounds = CGRect(x: 0, y: 0, width: 595, height: 842)
        let context = CGContext(consumer: consumer, mediaBox: &bounds, nil)!
        for page in 1...3 {
            context.beginPDFPage(nil); NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            ("Internal PDF check — page \(page)" as NSString).draw(at: CGPoint(x: 45, y: 740), withAttributes: [.font: NSFont.systemFont(ofSize: 24)])
            ("Saved notes and PDF page links stay local." as NSString).draw(at: CGPoint(x: 45, y: 700), withAttributes: [.font: NSFont.systemFont(ofSize: 15)])
            NSGraphicsContext.restoreGraphicsState(); context.endPDFPage()
        }
        context.closePDF(); try (data as Data).write(to: pdfURL)
        let pdf = try library.importPDF(from: pdfURL, parentID: classroom.id)
        try model.reload()
        check("managed_real_pdf_has_three_text_pages", try library.pdfPages(assetID: pdf.assetID!).filter { !$0.text.isEmpty }.count == 3)
        model.create(.classroom, title: "Interrupted timeline fixture", parentID: course.id)
        let interruptedID = model.selected!.id
        var interrupted = try library.classroom(id: interruptedID)!
        interrupted.state = "interrupted"; interrupted.timelineMilliseconds = 12_000
        interrupted.updatedAt = Date()
        try library.saveClassroom(interrupted)
        let recoveredOffset = try await model.resumeOffset(interrupted, in: library, now: interrupted.updatedAt.addingTimeInterval(45))
        check("restart_gap_retains_saved_offset_and_labels_estimate", try recoveredOffset == 57 && model.gapsByClass[interruptedID]?.last?.reason == "recovered-interruption-wall-clock-estimate" && (try library.classroom(id: interruptedID)?.timelineMilliseconds) == 57_000)
        var changed = try library.classroom(id: interruptedID)!
        changed.state = "interrupted"; changed.mainLanguage = "ja"
        try library.saveClassroom(changed); model.classRecords[interruptedID] = changed
        let oldEnd = changed.timelineMilliseconds
        model.pendingClassRecords[interruptedID] = changed
        var refusedPendingCheckpoint = false
        do { _ = try await model.prepareClassAudio(interruptedID, in: library) } catch { refusedPendingCheckpoint = true }
        check("audio_prepare_refuses_unrepaired_lifecycle_checkpoint", refusedPendingCheckpoint && model.audio.phase != .capturing)
        model.pendingClassRecords[interruptedID] = nil
        let preparedOffset = try await model.prepareClassAudio(interruptedID, in: library)
        check("recovery_gap_survives_configuration_pause", model.gapsByClass[interruptedID]?.count == 2 && preparedOffset >= Double(oldEnd) / 1000 && model.audio.phase != .capturing && model.audio.configuration.language == "ja")
        var pausedRecord = try library.classroom(id: interruptedID)!
        pausedRecord.state = "paused"; pausedRecord.timelineMilliseconds = 70_000
        try library.saveClassroom(pausedRecord); model.pauseAnchors[interruptedID] = 100
        let resumedOtherClassOffset = try await model.resumeOffset(pausedRecord, in: library, uptime: 125)
        let switchedGap = try library.records(collection: "gaps", ownerID: interruptedID, as: TimelineGap.self).last
        check("cross_class_resume_persists_full_pause_interval", resumedOtherClassOffset == 95 && switchedGap?.startMS == 70_000 && switchedGap?.endMS == 95_000 && switchedGap?.reason == "paused-no-audio")
        model.activeClassID = nil
        model.openItem(classroom)
        let cloud = model.clouds[classroom.id]!
        let term = TranslationTerm(source: "working memory", translation: "工作记忆", scopeID: course.id)
        try model.textTranslation.saveTerm(term)
        try model.textTranslation.saveTerm(TranslationTerm(source: "other scope", translation: "其他范围", scopeID: "text"))
        let pausedBeforeTerminology = cloud.state.translationUserPaused
        try await model.configureClassTerminology(classroom.id, enabled: true)
        let frozenTerms = cloud.state.terminologySelection
        check("class_terminology_explicit_enable_persists_exact_course_without_dispatch", try frozenTerms?.terms == [term] && frozenTerms?.scopeID == course.id && !cloud.credentialUnlocked && cloud.state.translationUserPaused == pausedBeforeTerminology && library.record(collection: "cloud-state", id: classroom.id, as: CloudState.self)?.terminologySelection == frozenTerms)
        var revisedTerm = term; revisedTerm.translation = "工作記憶"
        try model.textTranslation.saveTerm(revisedTerm)
        check("editing_glossary_does_not_silently_change_class_snapshot", cloud.state.terminologySelection == frozenTerms)
        try await model.configureClassTerminology(classroom.id, enabled: true)
        check("explicit_update_uses_new_glossary_snapshot", cloud.state.terminologySelection?.terms == [revisedTerm])
        try await model.configureClassTerminology(classroom.id, enabled: false)
        check("class_terminology_disable_persists_without_unpausing", try cloud.state.terminologySelection == nil && cloud.state.translationUserPaused == pausedBeforeTerminology && library.record(collection: "cloud-state", id: classroom.id, as: CloudState.self)?.terminologySelection == nil)
        let segment = AudioTranscript(id: UUID().uuidString, sessionID: classroom.id, epochID: UUID().uuidString, language: "en", text: "Injected persistence boundary sample; not ASR evidence.", sequence: 1, revision: 1, start: 5, end: 7, confirmedAt: Date())
        let usageRevisionBefore = model.usageRevision
        model.acceptTranscript(segment); model.acceptTranscript(segment); await model.drainSessionWork()
        check("saved_class_cloud_update_invalidates_usage_snapshot", model.usageRevision > usageRevisionBefore)
        check("duplicate_confirmation_is_idempotent", try library.transcripts(classroomID: classroom.id).count == 1 && cloud.state.jobs.count == 1)
        check("unconfigured_translation_waits_without_request", cloud.state.jobs.first?.status == .waitingConfiguration && !cloud.credentialUnlocked)
        let persistedOnly = TranscriptRecord(id: UUID().uuidString, classroomID: classroom.id, epochID: segment.epochID, startMS: 7000, endMS: 7500, text: "Persisted before queue insertion", language: "en", revision: 1, confirmedAt: Date())
        try library.putRecord(collection: "transcripts", id: persistedOnly.id, ownerID: classroom.id, value: persistedOnly)
        await cloud.setUserPaused(true); model.reconcileTranslations(classroom.id); await model.drainSessionWork()
        check("reconcile_missing_translation_preserves_user_pause", cloud.state.translationUserPaused && cloud.state.jobs.contains { $0.segment.id == persistedOnly.id && $0.historical })
        let revision = AudioTranscript(id: segment.id, sessionID: classroom.id, epochID: segment.epochID, language: "en", text: "Updated injected persistence sample", sequence: 1, revision: 2, start: 5, end: 7, confirmedAt: Date())
        model.acceptTranscript(revision); await model.drainSessionWork()
        check("new_revision_replaces_visible_original", model.transcriptRows[classroom.id]?.first?.revision == 2 && model.transcriptRows[classroom.id]?.first?.text == revision.text)
        model.endClass(classroom.id)
        await cloud.setUserPaused(true) // Race: end started using an older ClassroomRecord.
        try await Task.sleep(nanoseconds: 100_000_000)
        check("ending_does_not_clear_new_translation_pause", try library.classroom(id: classroom.id)?.translationUserPaused == true)
        check("ended_remains_terminal_without_capture", model.classRecords[classroom.id]?.state == "ended" && model.audio.phase != .capturing)
        let before = try library.transcripts(classroomID: classroom.id)
        model.startClass(classroom.id)
        check("ended_start_is_inert", try library.transcripts(classroomID: classroom.id).count == before.count && model.audio.phase != .capturing)
        await cloud.setUserPaused(true)
        let backup = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-backup.uwaybackup")
        try library.backup(itemID: course.id, to: backup)
        let fresh = try LibraryStore(rootURL: root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-restored"))
        let restored = try fresh.restoreBackup(from: backup)
        let restoredClass = restored.first { $0.kind == .classroom && $0.title == classroom.title }!
        let restoredState = try fresh.record(collection: "cloud-state", id: restoredClass.id, as: CloudState.self)!
        check("restored_cloud_jobs_remap_class_and_segment", restoredState.classID == restoredClass.id && restoredState.jobs.first?.segment.classID == restoredClass.id && restoredState.jobs.first?.segment.id != segment.id)
        check("restored_translation_stays_paused", restoredState.translationUserPaused)
        let failedSegment = AudioTranscript(id: UUID().uuidString, sessionID: classroom.id, epochID: UUID().uuidString, language: "en", text: "Recoverable save failure injection", sequence: 2, revision: 1, start: 8, end: 9, confirmedAt: Date())
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        model.acceptTranscript(failedSegment)
        let failedRevision = AudioTranscript(id: failedSegment.id, sessionID: classroom.id, epochID: failedSegment.epochID, language: "en", text: "Newer confirmed revision retained during save failure", sequence: 2, revision: 2, start: 8, end: 9, confirmedAt: Date())
        model.acceptTranscript(failedRevision); await model.drainSessionWork()
        check("failed_revision_replaces_pending_original", model.pendingTranscripts.count == 1 && model.pendingTranscripts.first?.revision == 2 && model.pendingTranscripts.first?.text == failedRevision.text)
        model.activeClassID = interruptedID
        model.audioPhaseChanged(.paused); await model.drainSessionWork()
        check("failed_lifecycle_checkpoint_shows_stopped_and_remains_pending", model.classRecords[interruptedID]?.state == "paused" && model.pendingClassRecords[interruptedID] != nil)
        model.activeClassID = nil
        check("save_failure_preserves_confirmed_memory", model.pendingTranscripts.count == 1 && model.hasUnsavedFacts)
        model.endClass(classroom.id)
        try await Task.sleep(nanoseconds: 100_000_000)
        check("ending_save_failure_preserves_end_intent", model.pendingEndIDs.contains(classroom.id))
        model.openLibrary(root.deletingLastPathComponent().appendingPathComponent("blocked-library-swap"), remember: false)
        check("unsaved_facts_block_library_swap", model.library === library)
        check("unsaved_facts_block_exit", await model.prepareForExit() == false)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        model.retryUnsaved(); await model.drainSessionWork()
        check("recovered_confirmed_content_enters_translation_queue", try model.pendingTranscripts.isEmpty && cloud.state.jobs.contains { $0.segment.id == failedSegment.id && $0.segment.revision == 2 } && (try library.transcripts(classroomID: classroom.id).first { $0.id == failedSegment.id })?.text == failedRevision.text)
        check("retry_finishes_requested_end_without_capture", model.pendingEndIDs.isEmpty && model.classRecords[classroom.id]?.state == "ended" && model.audio.phase != .capturing)
        model.audio.pausePlayback(); try model.audio.resumePlayback()
        check("no_player_pause_resume_is_inert", model.audio.playbackPosition == nil && !model.audio.playbackPaused)
        for lang in ["zh-Hans", "zh-Hant", "en", "ja"] {
            check("complete_core_catalog_\(lang)", Localizer.table.keys.allSatisfy { Localizer.table[$0]?.count == 4 && !Localizer.string($0, language: lang).isEmpty })
        }
        check("system_language_first_supported", AppPreferences.resolve(["fr-FR", "ja-JP", "en"]) == "ja" && AppPreferences.resolve(["zh-HK"]) == "zh-Hant" && AppPreferences.resolve(["de"]) == "en")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: root.path)
        model.openLibrary(root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-rejected-swap"), remember: false)
        await model.drainSessionWork()
        check("shutdown_checkpoint_failure_blocks_library_swap", model.library === library && model.hasUnsavedFacts)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: root.path)
        model.retryUnsaved(); await model.drainSessionWork()
        #if AUDIO_TESTING
        var admittedOrder: [Int] = []
        let previousPhase = model.audio.onPhaseChanged, previousGap = model.audio.onGap
        model.audio.onGap = { _ in }
        model.audio.onPhaseChanged = { phase in if phase == .paused { model.enqueueSessionWork { admittedOrder.append(64) } } }
        _ = try await model.audio.beginSyntheticCapture(sessionID: "bounded-queue-fixture", recordingDirectory: nil, onFrame: { _ in true })
        for value in 0..<64 { model.enqueueSessionWork { admittedOrder.append(value) } }
        await model.drainSessionWork(); await model.audio.pause(reason: "check-complete")
        check("backpressure_stops_producer_and_preserves_reentrant_checkpoint_order", admittedOrder == Array(0...64) && model.pendingSessionOperations == 0 && model.audio.phase == .paused && !model.audio.draining)
        model.audio.onPhaseChanged = previousPhase; model.audio.onGap = previousGap
        #endif
        let reader = AppModel() // The first model still owns the library writer lock.
        reader.openItem(classroom)
        check("second_instance_reads_classroom_without_writer", reader.library?.isReadOnly == true && reader.clouds[classroom.id] != nil)
        check("readonly_history_can_exit_without_phantom_unsaved_work", await reader.prepareForExit())
        let readonlyCatalog = WorkspaceCatalog(library: library)
        let readonlyProject = try readonlyCatalog.createCourse(title: "Readonly project")
        _ = try readonlyCatalog.create(kind: .note, title: "Readable workspace", parentID: readonlyProject.id)
        reader.workspaceCatalog = WorkspaceCatalog(library: reader.library!)
        reader.refreshProjects()
        check("readonly_workspace_refresh_does_not_mark_readable_course_offline", reader.items.contains { $0.id == readonlyProject.id } && !reader.unavailableProjectIDs.contains(readonlyProject.id) && !reader.busy)
        reader.workspaceDirectoryObserver.stop()
        for cloud in model.clouds.values { await cloud.shutdown() }; model.audio.stopPlayback()
        let pass = checks.allSatisfy { $0["pass"] as? Bool == true }
        let report: [String: Any] = ["suite":"AppModel production integration / injected persistence boundaries", "checks":checks, "passed":pass, "providerCalls":0, "keychainReads":0, "hardwareCapture":0, "audioPlayback":0, "doesNotProve":"ASR quality, live capture, cloud semantics, or three-hour classroom"]
        let reportURL = root.deletingLastPathComponent().appendingPathComponent(root.lastPathComponent + "-report.json")
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: reportURL)
        print(reportURL.path)
        if !pass { exit(1) }
    }
}
