import Foundation

@main enum InterpretationPersistenceChecks {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        var checks = [String]()
        func check(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try condition() else { throw LibraryError.message("FAILED: " + label) }; checks.append(label)
        }
        func rejects(_ label: String, _ action: () throws -> Void) throws {
            do { try action() } catch { checks.append(label); return }; throw LibraryError.message("FAILED: " + label)
        }
        let library = try LibraryStore(rootURL: root.appendingPathComponent("catalog"))
        try library.configureTranscriptStorage(rootURL: root.appendingPathComponent("transcripts"))
        let catalog = WorkspaceCatalog(library: library), course = try catalog.createCourse(title: "course")
        let session = try catalog.create(kind: .classroom, title: "Online fixture", parentID: course.id)
        var runtime = InterpretationRuntimeRecord(sessionID: session.id)
        runtime.modelID = "fixture-translate"; runtime.state = "running"; runtime.generation = 1
        try library.saveInterpretationRuntime(runtime)
        var source = InterpretationCaptionRecord(sessionID: session.id, generation: 1, track: "source", text: "Source one.", language: "en", receivedAtMS: 100)
        source.sequence = 2; source.providerItemReference = session.id; source.originalText = "literal " + session.id
        source.providerElapsedMS = 25
        var translation = InterpretationCaptionRecord(sessionID: session.id, generation: 1, track: "translation", text: "译文先到。", language: "zh-Hans", receivedAtMS: 100)
        translation.sequence = 1; translation.providerEventReference = session.id
        try library.saveInterpretationCaption(source); try library.saveInterpretationCaption(translation)
        try library.saveInterpretationCaption(source)
        try check(try library.interpretationCaptions(sessionID: session.id).map(\.id) == [translation.id, source.id], "separate tracks keep receive sequence and duplicate saves are idempotent")
        try check(try library.interpretationCaptions(sessionID: session.id).last?.providerElapsedMS == 25 && source.startMS == nil, "raw provider elapsed metadata is preserved without inventing alignment")
        source.revision = 2; source.text = "Source one revised."; source.isFinal = true; source.completionBasis = "localBoundary"
        try library.saveInterpretationCaption(source)
        var late = source; late.revision = 1; late.text = "stale"
        try library.saveInterpretationCaption(late)
        try check(try library.interpretationCaptions(sessionID: session.id).last?.text == source.text, "older revisions do not overwrite durable text")
        late = source; late.text = "conflicting same revision"
        try rejects("same revision conflict is rejected") { try library.saveInterpretationCaption(late) }
        late = source; late.startMS = 0; late.endMS = 10
        try rejects("unknown time cannot masquerade as speech timing") { try library.saveInterpretationCaption(late) }
        let text = try library.transcriptExportFiles(itemID: session.id, format: .txt, bilingual: true).values.first!
        let exported = String(decoding: text, as: UTF8.self)
        try check(exported.contains(source.text) && exported.contains(translation.text) && exported.contains("untimed"), "untimed dual tracks export independently without invented timestamps")
        try rejects("untimed SRT requires actual or labeled display intervals") { _ = try library.transcriptExportFiles(itemID: session.id, format: .srt, bilingual: true) }
        var usage = InterpretationUsageRecord(sessionID: session.id, generation: 1, provider: "google", modelID: runtime.modelID)
        usage.uploadedSeconds = 1.25; usage.generatedSeconds = 0.8; usage.playedSeconds = 0; usage.estimatedCostUSD = 0.001
        usage.observations = [InterpretationUsageObservation(sequence: 3, eventID: session.id, observedAt: Date(), inputTokens: 20, outputTokens: 4, totalTokens: 24), InterpretationUsageObservation(sequence: 4, observedAt: Date(), inputTokens: 22, outputTokens: 5, totalTokens: 27)]
        usage.observationCount = 2
        try library.saveInterpretationUsage(usage); try library.saveInterpretationUsage(usage)
        try check(try library.interpretationUsage(sessionID: session.id).count == 1, "usage snapshots deduplicate rather than double-counting")
        let usageSaved = try library.interpretationUsage(sessionID: session.id).first!
        try check(usageSaved.observations?.map(\.inputTokens) == [20, 22] && usageSaved.inputTokens == nil && usageSaved.measurementSource == "observed", "unknown cumulative semantics retain provider samples without summing")
        var previousCaption = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as! [String: Any]
        previousCaption.removeValue(forKey: "providerElapsedMS")
        let oldCaption = try JSONDecoder().decode(InterpretationCaptionRecord.self, from: JSONSerialization.data(withJSONObject: previousCaption))
        var previousUsage = try JSONSerialization.jsonObject(with: JSONEncoder().encode(usage)) as! [String: Any]
        previousUsage.removeValue(forKey: "observations"); previousUsage.removeValue(forKey: "observationCount")
        let oldUsage = try JSONDecoder().decode(InterpretationUsageRecord.self, from: JSONSerialization.data(withJSONObject: previousUsage))
        try check(oldCaption.providerElapsedMS == nil && oldUsage.observations == nil && oldUsage.observationCount == nil, "earlier online records decode missing optional provider metadata")
        var invalid = usage; invalid.uploadedSeconds = .infinity
        try rejects("invalid usage cannot be persisted") { try library.saveInterpretationUsage(invalid) }
        let backup = root.appendingPathComponent("session.uwaybackup")
        try library.backup(itemID: session.id, to: backup)
        let restored = try LibraryStore(rootURL: root.appendingPathComponent("restored"))
        let restoredItems = try restored.restoreBackup(from: backup)
        let restoredID = restoredItems.first { $0.kind == .classroom }!.id
        try check(restoredID != session.id, "restore assigns a fresh local session identity")
        try check(try restored.interpretationRuntime(sessionID: restoredID)?.state == "interrupted", "restored live runtime remains interrupted")
        let restoredCaptions = try restored.interpretationCaptions(sessionID: restoredID)
        try check(restoredCaptions.first?.providerEventReference == session.id && restoredCaptions.last?.providerItemReference == session.id && restoredCaptions.last?.originalText == source.originalText, "opaque provider references and original text are not remapped")
        try check(try restored.interpretationUsage(sessionID: restoredID).first?.status == "interrupted", "restored usage never restarts work")
        try check(try restored.interpretationUsage(sessionID: restoredID).first?.observations?.first?.eventID == session.id, "legacy archive preserves opaque provider usage event identity")
        let archive = root.appendingPathComponent("session.ulbackup")
        try WorkspaceArchive(catalog: WorkspaceCatalog(library: library)).backup(itemID: session.id, to: archive)
        let workspaceRestored = try LibraryStore(rootURL: root.appendingPathComponent("workspace-restored"))
        try workspaceRestored.configureTranscriptStorage(rootURL: root.appendingPathComponent("restored-transcripts"))
        let destination = root.appendingPathComponent("restore-target"); try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        let workspaceItems = try WorkspaceArchive(catalog: WorkspaceCatalog(library: workspaceRestored)).restore(from: archive, into: destination)
        let workspaceID = workspaceItems.first { $0.kind == .classroom }!.id
        try check(try workspaceRestored.interpretationRuntime(sessionID: workspaceID)?.state == "interrupted", "workspace archive freezes live interpretation")
        try check(try workspaceRestored.interpretationCaptions(sessionID: workspaceID).last?.providerItemReference == session.id, "workspace archive preserves provider opaque UUIDs")
        try check(try workspaceRestored.interpretationUsage(sessionID: workspaceID).first?.observations?.first?.eventID == session.id, "workspace archive preserves provider usage samples and opaque event identity")
        let schema = try library.databaseRows("PRAGMA user_version").first?["user_version"]
        try check(schema == "1", "new online collections require no SQL schema migration")
        let timedSession = try library.createStandaloneSession(title: "Timed display fixture")
        var timedSource = InterpretationCaptionRecord(sessionID: timedSession.id, generation: 1, track: "source", text: "timed source", language: "en", receivedAtMS: 0)
        timedSource.startMS = 0; timedSource.endMS = 400; timedSource.timingSource = "receiveTime"
        var timedTranslation = InterpretationCaptionRecord(sessionID: timedSession.id, generation: 1, track: "translation", text: "timed translation", language: "zh", receivedAtMS: 300)
        timedTranslation.startMS = 300; timedTranslation.endMS = 900; timedTranslation.timingSource = "receiveTime"
        try library.saveInterpretationCaption(timedSource); try library.saveInterpretationCaption(timedTranslation)
        for format in [TranscriptExportFormat.srt, .vtt] {
            let split = try library.transcriptExportFiles(itemID: timedSession.id, format: format, bilingual: true)
            let sourceText = String(decoding: split.first { $0.key.hasSuffix("-source." + format.rawValue) }!.value, as: UTF8.self)
            let translationText = String(decoding: split.first { $0.key.hasSuffix("-translation." + format.rawValue) }!.value, as: UTF8.self)
            try check(split.count == 2 && sourceText.contains("timed source") && !sourceText.contains("timed translation") && translationText.contains("timed translation") && !translationText.contains("timed source"), "online \(format.rawValue) exports source and translation as separate tracks")
            let separator = format == .srt ? "," : "."
            try check(sourceText.contains("00:00:00" + separator + "000 --> 00:00:00" + separator + "400") && translationText.contains("00:00:00" + separator + "300 --> 00:00:00" + separator + "900"), "online \(format.rawValue) preserves each track's own estimated time interval")
        }
        try check(try library.transcriptExportFiles(itemID: timedSession.id, format: .srt, bilingual: false).count == 1, "source-only export excludes the translation file")
        var standaloneRuntime = InterpretationRuntimeRecord(sessionID: timedSession.id)
        standaloneRuntime.modelID = "fixture-translate"; standaloneRuntime.state = "paused"; standaloneRuntime.startedAt = Date()
        try library.saveInterpretationRuntime(standaloneRuntime)
        let standaloneArchive = root.appendingPathComponent("standalone.ulbackup")
        try WorkspaceArchive(catalog: catalog).backup(itemID: timedSession.id, to: standaloneArchive)
        let standaloneItems = try WorkspaceArchive(catalog: WorkspaceCatalog(library: workspaceRestored)).restore(from: standaloneArchive, into: destination)
        let standaloneID = standaloneItems.first { $0.kind == .classroom }!.id
        try check(try workspaceRestored.interpretationCaptions(sessionID: standaloneID).count == 2 && workspaceRestored.interpretationRuntime(sessionID: standaloneID)?.state == "interrupted", "standalone interpretation history restores without a course or automatic resumption")
        let legacy = try library.createStandaloneSession(title: "Legacy")
        try library.saveTranscript(TranscriptRecord(id: UUID().uuidString, classroomID: legacy.id, epochID: UUID().uuidString, startMS: 0, endMS: 1000, text: "old chain", language: "en"))
        try check(try library.interpretationRuntime(sessionID: legacy.id) == nil && !library.transcriptExportFiles(itemID: legacy.id, format: .srt, bilingual: true).isEmpty, "legacy records and timed export remain compatible")
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["passed": true, "checks": checks, "realServiceRequests": 0], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
