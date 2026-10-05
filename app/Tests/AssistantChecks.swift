import Foundation
import PDFKit
import CoreText

private final class AssistantCheckCredentials: CloudCredentialStore {
    var reads = 0
    var values: [String: String] = [:]
    func save(_ value: String, reference: String) throws { values[reference] = value }
    func read(reference: String) throws -> String? { reads += 1; return values[reference] }
    func remove(reference: String) throws { values[reference] = nil }
}
private final class AssistantCheckNetwork: URLProtocol {
    struct Reply { let text: String; var terminal = true; var delay = 0.0 }
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var handler: ((URLRequest) throws -> Reply)?
    private var delivery: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var request = self.request
        if request.httpBody == nil, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }; var data = Data(); var bytes = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&bytes, maxLength: bytes.count); if n <= 0 { break }; data.append(contentsOf: bytes.prefix(n)) }; request.httpBody = data
        }
        Self.lock.lock(); Self.requests.append(request); let handler = Self.handler; Self.lock.unlock()
        do {
            guard let reply = try handler?(request) else { throw URLError(.unsupportedURL) }
            client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
            let event: [String: Any] = ["type": "response.output_text.delta", "delta": reply.text]
            client?.urlProtocol(self, didLoad: Data(("data: " + String(decoding: try JSONSerialization.data(withJSONObject: event), as: UTF8.self) + "\n\n").utf8))
            let work = DispatchWorkItem { [weak self] in
                guard let self, self.delivery?.isCancelled == false else { return }
                if reply.terminal { self.client?.urlProtocol(self, didLoad: Data("data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":8,\"output_tokens\":5}}}\n\n".utf8)) }
                self.client?.urlProtocolDidFinishLoading(self)
            }
            delivery = work; DispatchQueue.global().asyncAfter(deadline: .now() + reply.delay, execute: work)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { delivery?.cancel() }
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
    static func respond(_ callback: @escaping (URLRequest) throws -> Reply) { lock.lock(); handler = callback; lock.unlock() }
    static func body(_ request: URLRequest) throws -> String { let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]; return body["input"] as! String }
}
@main struct AssistantChecks {
    @MainActor static func main() async throws {
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        var checks: [String] = []
        func require(_ value: Bool, _ label: String) throws { if !value { throw DocumentFailure.message(label) }; checks.append(label) }
        func wait(_ condition: @escaping @MainActor () -> Bool) async throws {
            for _ in 0..<1000 { if condition() { return }; try await Task.sleep(nanoseconds: 10_000_000) }
            throw DocumentFailure.message("Timed out waiting for asynchronous assistant state")
        }
        let library = try LibraryStore(rootURL: out.appendingPathComponent("catalog"))
        try library.configureTranscriptStorage(rootURL: out.appendingPathComponent("transcripts"))
        let catalog = WorkspaceCatalog(library: library)
        let course = try catalog.createCourse(title: "Course A"), otherCourse = try catalog.createCourse(title: "Course B")
        let session = try library.createItem(kind: .classroom, title: "Class", parentID: course.id)
        let selected = try catalog.create(kind: .note, title: "Selected", parentID: course.id)
        let excluded = try catalog.create(kind: .note, title: "Unselected", parentID: course.id)
        let other = try catalog.create(kind: .note, title: "Other", parentID: otherCourse.id)
        func writeNote(_ item: WorkspaceItem, _ text: String) throws -> BlockNoteDocument {
            let store = BlockNoteStore(packageURL: try catalog.documentURL(id: item.id), noteID: item.id)
            var doc = try store.create(title: item.title); doc.blocks = [NoteBlock(kind: .paragraph, text: text)]; return try store.save(doc)
        }
        let note = try writeNote(selected, "SELECTED evidence: working memory has limited capacity.")
        _ = try writeNote(excluded, "UNSELECTED-CONTENT"); _ = try writeNote(other, "OTHER-COURSE-CONTENT")
        try catalog.link(documentID: selected.id, sessionID: session.id)
        try library.saveTranscript(TranscriptRecord(id: UUID().uuidString, classroomID: session.id, epochID: UUID().uuidString, startMS: 3000, endMS: 7000, text: "Why does retrieval improve long-term learning?", language: "en"))
        var classRecord = try library.classroom(id: session.id)!; classRecord.state = "capturing"; try library.saveClassroom(classRecord)
        let suite = "local.ulecture.assistant-check." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = AssistantCheckCredentials(), cfg = URLSessionConfiguration.ephemeral
        cfg.protocolClasses = [AssistantCheckNetwork.self]
        let settings = CloudServiceSettings(initialConfiguration: CloudConfiguration(provider: .openAI), credentials: credentials, session: URLSession(configuration: cfg), defaults: defaults)
        let oldMarkdown = "# Original Markdown revision\n\nLegacy citation text must not be mapped to a converted block.\n"
        let oldRevision = try library.saveNote(noteID: selected.id, markdown: oldMarkdown)
        let oldSource = SummarySource(kind: .note, entityID: selected.id, version: oldRevision.version, text: oldMarkdown)
        let oldTranscript = try library.transcripts(classroomID: session.id)[0]
        let oldTranscriptSource = SummarySource(kind: .transcript, entityID: oldTranscript.id, version: oldTranscript.revision, text: oldTranscript.text, startMS: oldTranscript.startMS, endMS: oldTranscript.endMS)
        let removedSource = SummarySource(kind: .pdf, entityID: "removed-legacy-asset", version: 3, text: "Original PDF excerpt survives the removed file.", page: 4)
        let oldSummary = CloudSummary(snapshot: SummarySnapshot(classID: session.id, sources: [oldSource, oldTranscriptSource, removedSource], excluded: ["Historical excluded scope"]),
            dispatch: CloudDispatch(version: 1, configuration: CloudConfiguration(provider: .openAI), preset: .current(for: .openAI), sentAt: Date()),
            claims: [SummaryClaim(text: "Saved historical claim", referenceIDs: [oldSource.id, oldTranscriptSource.id, removedSource.id, "missing-reference"])], status: "running")
        try library.putRecord(collection: "cloud-state", id: session.id, ownerID: session.id, value: CloudState(classID: session.id, summaries: [oldSummary]))
        let controller = AIAssistantController(library: library, catalog: catalog, settings: settings, flushEdits: { true })
        await controller.selectContext(itemID: selected.id, classroomID: session.id)
        try require(credentials.reads == 0 && AssistantCheckNetwork.count == 0 && controller.selectedSourceIDs.count == 2, "opening context selects current note and classroom without secret reads or network")
        try require(!controller.options.contains { $0.documentID == other.id } && !controller.selectedSourceIDs.contains("note:" + excluded.id), "other courses unavailable and unselected notes remain excluded")
        let historical = controller.legacySummaries[0]
        try require(historical.id == oldSummary.id && historical.claims == oldSummary.claims && historical.snapshot.hash == oldSummary.snapshot.hash && historical.snapshot.excluded == oldSummary.snapshot.excluded, "migrated cloud-state summaries expose original claims, references, exclusions and immutable source text")
        var openedCurrent = 0
        controller.onOpenReference = { _ in openedCurrent += 1 }
        controller.openLegacyReference(summaryID: oldSummary.id, sourceID: oldSource.id)
        try require(controller.legacySource?.text == oldMarkdown && controller.legacySource?.version == oldRevision.version && controller.legacySource?.hash == oldSource.hash && controller.fixedSource == nil && openedCurrent == 0, "legacy Markdown citation opens original saved Markdown and version without approximating current note blocks")
        controller.openLegacyReference(summaryID: oldSummary.id, sourceID: removedSource.id)
        try require(controller.legacySource?.text == removedSource.text && controller.legacySource?.page == 4 && openedCurrent == 0, "historical PDF excerpt remains readable even when its original asset is unavailable")
        controller.openLegacyReference(summaryID: oldSummary.id, sourceID: oldTranscriptSource.id)
        let historicalState = try library.record(collection: "cloud-state", id: session.id, as: CloudState.self)!
        try require(controller.legacySource?.startMS == oldTranscript.startMS && controller.legacySource?.endMS == oldTranscript.endMS && historicalState.summaries[0].status == "running" && credentials.reads == 0 && AssistantCheckNetwork.count == 0, "historical transcript keeps original time and read-only history neither rewrites status nor reads secrets or replays requests")
        controller.legacySource = nil
        await controller.selectContext(itemID: other.id)
        try require(controller.legacySummaries.isEmpty, "unrelated document context does not expose another classroom's historical summaries")
        await controller.selectContext(itemID: session.id)
        try require(controller.legacySummaries.first?.id == oldSummary.id, "opening classroom directly exposes its historical summaries")
        await controller.selectContext(itemID: selected.id, classroomID: session.id)
        try settings.saveCredential("fixture-assistant-not-a-real-key")
        AssistantCheckNetwork.respond { request in
            let body = try AssistantCheckNetwork.body(request)
            guard body.contains("SELECTED evidence"), !body.contains("UNSELECTED-CONTENT"), !body.contains("OTHER-COURSE-CONTENT") else { throw DocumentFailure.message("Source isolation failed") }
            return .init(text: "真实适配器测试文本 [S1]")
        }
        await controller.ask("Explain the selected evidence", language: "zh-Hans")
        let first = controller.turns[0], snapshot = controller.snapshots[first.snapshotID]!
        try require(first.runs.last?.state == "completed" && first.runs.last?.text == "真实适配器测试文本 [S1]", "production streaming adapter publishes and durably completes Unicode reply")
        try require(snapshot.sources.contains { $0.documentID == selected.id && $0.version == note.revision && $0.blockID == note.blocks[0].id } && snapshot.cutoffMS == 7000 && !snapshot.classroomEnded, "snapshot uses actual block revision and live transcript cutoff")
        let originalTranscript = snapshot.sources.first { $0.kind == .transcript }!
        var revisedTranscript = originalTranscript.transcriptSnapshot!
        revisedTranscript.text = "Current corrected transcript differs from the frozen reply source"; revisedTranscript.revision += 1
        try library.saveTranscript(revisedTranscript)
        controller.open(originalTranscript)
        try require(controller.fixedSource?.text == originalTranscript.text && controller.fixedSource?.transcriptSnapshot?.revision == 1, "citation to revised transcript opens its fixed original excerpt and complete original record")
        controller.fixedSource = nil
        _ = try writeNote(selected, "NEW VERSION must not replace the previous request snapshot")
        await controller.retry(first.id)
        try require(controller.turns[0].runs.count == 2 && controller.turns[0].runs.last?.state == "completed" && controller.snapshots[first.snapshotID]?.hash == snapshot.hash, "retry preserves original immutable source version and prior attempt")
        AssistantCheckNetwork.respond { _ in .init(text: "Invalid source [S999]") }
        await controller.ask("Check citations")
        try require(controller.turns.last?.runs.last?.state == "needsReview" && controller.turns.last?.runs.last?.invalidCitations == ["S999"], "unknown citation IDs are flagged rather than treated as usable evidence")
        AssistantCheckNetwork.respond { _ in .init(text: "Partial saved answer [S1]", terminal: false) }
        await controller.ask("Keep partial output")
        let partialID = controller.turns.last!.id
        try require(controller.turns.last?.runs.last?.state == "partial" && controller.resultText(partialID).contains("Partial"), "missing stream terminal preserves partial text and failure")
        AssistantCheckNetwork.respond { _ in .init(text: "Retried answer [S1]") }
        await controller.retry(partialID)
        try require(controller.turns.last!.runs.count == 2 && controller.turns.last!.runs[0].text.contains("Partial") && controller.turns.last!.runs.last!.state == "completed", "retry retains failed partial attempt and saves new complete attempt")
        AssistantCheckNetwork.respond { _ in .init(text: "Cancellable partial [S1]", delay: 5) }
        let cancellable = Task { await controller.ask("Cancel while streaming") }
        try await wait { controller.turns.last?.runs.last?.text.contains("Cancellable") == true }
        controller.cancel(); await cancellable.value
        try require(controller.turns.last?.runs.last?.state == "cancelled" && controller.turns.last?.runs.last?.text.contains("Cancellable") == true, "cancelling actual adapter stream retains partial text")
        let before = AssistantCheckNetwork.count
        await controller.ask("Explain old selection", intent: .explain, selection: DocumentSelection(documentID: selected.id, text: "SELECTED evidence", blockID: note.blocks[0].id, revision: note.revision))
        try require(AssistantCheckNetwork.count == before && controller.error == "selectionChanged", "stale selection is rejected before any provider request")
        let currentBeforeAppend = try BlockNoteStore(packageURL: catalog.documentURL(id: selected.id), noteID: selected.id).load()
        try await controller.append(turnID: first.id, noteID: selected.id)
        let appended = try BlockNoteStore(packageURL: catalog.documentURL(id: selected.id), noteID: selected.id).load()
        try require(appended.blocks.starts(with: currentBeforeAppend.blocks) && appended.markdown.contains("真实适配器"), "explicit AI append preserves current note blocks and adds generated result with provenance")
        await controller.saveAsNote(turnID: partialID, parentID: course.id, title: "Saved AI response")
        let saved = try library.items().first { $0.title == "Saved AI response" }!
        let savedNote = try BlockNoteStore(packageURL: catalog.documentURL(id: saved.id), noteID: saved.id).load()
        try require(savedNote.markdown.contains("Retried answer") && savedNote.markdown.contains("snapshot"), "explicit save creates a real .ulnote with reply and snapshot provenance")
        _ = try writeNote(selected, String(repeating: "Long selected source. ", count: 1100))
        AssistantCheckNetwork.respond { request in
            let body = try AssistantCheckNetwork.body(request)
            return .init(text: "Processed supplied portion [\(AssistantCitation.identifiers(in: body).first ?? "S1")]")
        }
        let initialCount = AssistantCheckNetwork.count
        await controller.ask("Summarize all selected text", intent: .summary)
        let long = controller.turns.last!, longSnapshot = controller.snapshots[long.snapshotID]!, run = long.runs.last!
        try require(run.state == "completed" && run.chunks.count > 1 && run.chunks.allSatisfy { $0.status == "completed" } && AssistantCheckNetwork.count - initialCount == run.chunks.count + 1, "long material uses multiple map streams and final synthesis")
        try require(Set(run.chunks.flatMap(\.sourceIDs)) == Set(longSnapshot.sources.map(\.id)), "chunk coverage includes every selected source unit")
        let pdfURL = out.appendingPathComponent("source.pdf")
        var media = CGRect(x: 0, y: 0, width: 500, height: 700)
        let context = CGContext(pdfURL as CFURL, mediaBox: &media, nil)!
        context.beginPDFPage(nil)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "PDF page evidence", attributes: [.font: NSFont.systemFont(ofSize: 16)]))
        context.textPosition = CGPoint(x: 30, y: 600); CTLineDraw(line, context); context.endPDFPage(); context.closePDF()
        let pdf = try catalog.importDocument(from: pdfURL, parentID: course.id)
        let actualPDF = try catalog.documentURL(id: pdf.id), originalHash = try DocumentDisk.hash(actualPDF)
        let annotations = PDFAnnotationStore(documentID: pdf.id, sourceURL: actualPDF, sidecarURL: try catalog.metadataDirectory(documentID: pdf.id))
        var loaded = try annotations.load().annotations
        let annotation = StoredPDFAnnotation(kind: .stickyNote, page: 1, bounds: CGRect(x: 30, y: 400, width: 40, height: 40), text: "Annotation evidence")
        loaded.annotations.append(annotation); _ = try annotations.save(loaded)
        let pdfSources = try controller.sources.snapshot(options: [.init(documentID: pdf.id, title: pdf.title, kind: .pdf), .init(documentID: pdf.id, title: pdf.title, kind: .annotation)], selection: nil, intent: .question)
        try require(pdfSources.sources.contains { $0.kind == .pdf && $0.page == 1 && $0.text.contains("PDF page evidence") } && pdfSources.sources.contains { $0.kind == .annotation && $0.annotationID == annotation.id && $0.text == "Annotation evidence" }, "PDF page and actual annotation record produce distinct citations")
        try require(try DocumentDisk.hash(actualPDF) == originalHash, "source extraction preserves original PDF")
        for ext in ["md", "txt"] {
            let file = out.appendingPathComponent("actual-source." + ext)
            let body = "Actual " + ext + " file content, never a hidden empty block-note package"
            try Data(body.utf8).write(to: file)
            let item = try catalog.importDocument(from: file, parentID: course.id)
            let options = try controller.sources.options(itemID: item.id, classroomID: nil)
            let own = options.first { $0.documentID == item.id }!
            let frozen = try controller.sources.snapshot(options: [own], selection: nil, intent: .question)
            try require(own.kind == .text && frozen.sources.first?.text == body && frozen.sources.first?.sourceHash == DocumentDisk.hash(Data(body.utf8)) && !controller.notes.contains { $0.id == item.id }, "actual " + ext + " document uses text-file source and is not a false block-note append target")
        }
        let activeEditor = BlockNoteEditorModel(packageURL: try catalog.documentURL(id: excluded.id), noteID: excluded.id)
        await activeEditor.load(title: excluded.title, language: "en")
        activeEditor.mutate("Pending user edit") { $0.blocks.append(NoteBlock(kind: .paragraph, text: "UNSAVED USER EDIT")) }
        try await controller.append(turnID: first.id, noteID: excluded.id)
        let activeSaved = try activeEditor.store.load()
        try require(activeSaved.markdown.contains("UNSAVED USER EDIT") && activeSaved.markdown.contains("真实适配器") && activeEditor.document == activeSaved, "append flushes an active editor and preserves pending user edits in the live document")
        AssistantCheckNetwork.respond { _ in
            try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: library.rootURL.path)
            return .init(text: "Must retain after write failure [S1]")
        }
        await controller.ask("Retain unsaved streamed text")
        try require(controller.unsaved && controller.error == "assistantUnsaved" && controller.resultText(controller.turns.last!.id).contains("Must retain"), "actual catalog write denial retains streamed output and reports saving failure distinctly from network failure")
        let protectedContext = controller.conversation?.id
        await controller.selectContext(itemID: pdf.id)
        let mayExitWithUnsaved = await controller.prepareForExit()
        try require(controller.conversation?.id == protectedContext && !mayExitWithUnsaved, "unsaved output blocks context switching and successful exit")
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: library.rootURL.path)
        controller.retrySaving()
        let persistedRetry = try library.record(collection: "assistant-turns", id: controller.turns.last!.id, as: AssistantTurn.self)!.runs.last!
        try require(!controller.unsaved && (persistedRetry.text + persistedRetry.chunks.map(\.text).joined()).contains("Must retain"), "retry saving commits retained output after the directory becomes writable")
        try settings.removeCredential()
        let beforeMissing = AssistantCheckNetwork.count
        await controller.ask("No key should not create an answer")
        try require(AssistantCheckNetwork.count == beforeMissing && controller.turns.last?.runs.last?.state == "failed" && controller.turns.last?.runs.last?.text.isEmpty == true, "missing credential makes no provider request and creates no answer")
        var interrupted = controller.turns.last!
        interrupted.runs[interrupted.runs.count - 1].state = "running"
        interrupted.runs[interrupted.runs.count - 1].text = "Durable pre-interruption text [S1]"
        try library.putRecord(collection: "assistant-turns", id: interrupted.id, ownerID: selected.id, value: interrupted)
        let requestsBeforeReopen = AssistantCheckNetwork.count, readsBeforeReopen = credentials.reads
        let reopened = AIAssistantController(library: library, catalog: catalog, settings: settings, flushEdits: { true })
        await reopened.selectContext(itemID: selected.id, classroomID: session.id)
        try require(reopened.turns.count == controller.turns.count && reopened.snapshots[first.snapshotID]?.hash == snapshot.hash && AssistantCheckNetwork.count == requestsBeforeReopen && credentials.reads == readsBeforeReopen, "recreation restores conversation and snapshots without requests or secret reads")
        try require(reopened.turns.last?.runs.last?.state == "interrupted" && reopened.turns.last?.runs.last?.text == "Durable pre-interruption text [S1]", "restoring an unfinished run preserves partial text and pauses it without replay")
        let records = try library.records(collection: "assistant-turns", as: AssistantTurn.self)
        try require(!String(decoding: JSONEncoder().encode(records), as: UTF8.self).contains("fixture-assistant"), "persistent attempts contain no secret")
        let selectedRangeRow = TranscriptRecord(id: UUID().uuidString, classroomID: session.id, epochID: UUID().uuidString, startMS: 10000, endMS: 20000, text: "ONLY-SELECTED-TIME-RANGE", language: "en")
        let outsideRangeRow = TranscriptRecord(id: UUID().uuidString, classroomID: session.id, epochID: UUID().uuidString, startMS: 20000, endMS: 24000, text: "OUTSIDE-END-BOUNDARY", language: "en")
        try library.saveTranscript(selectedRangeRow); try library.saveTranscript(outsideRangeRow)
        await reopened.refreshSourceDetails()
        let noteOption = reopened.options.first { $0.documentID == selected.id && $0.kind == .note }!
        let transcriptOption = reopened.options.first { $0.documentID == session.id && $0.kind == .transcript }!
        let originalNoteSnapshot = try BlockNoteStore(packageURL: catalog.documentURL(id: selected.id), noteID: selected.id).revisionSnapshot(note.revision)
        try require(reopened.scope(for: noteOption).version == nil && reopened.sourceDetails[noteOption.id]?.versions.contains { $0.version == note.revision && $0.sourceHash == originalNoteSnapshot.sourceHash } == true && reopened.sourceDetails[transcriptOption.id]?.firstMS == 3000 && reopened.sourceDetails[transcriptOption.id]?.lastMS == 24000, "source controls default to current saved version and list actual immutable revisions and saved transcript times")
        reopened.selectNoteVersion(noteOption, version: note.revision)
        reopened.setTranscriptRange(transcriptOption, start: "00:00:11", end: "20")
        try settings.saveCredential("fixture-assistant-not-a-real-key")
        AssistantCheckNetwork.respond { request in
            let body = try AssistantCheckNetwork.body(request)
            guard body.contains("ONLY-SELECTED-TIME-RANGE"), body.contains("SELECTED evidence"), !body.contains("OUTSIDE-END-BOUNDARY"), !body.contains("Current corrected transcript"), !body.contains("Long selected source") else { throw DocumentFailure.message("Source scope leaked outside selected time/version") }
            return .init(text: "Selected saved version and time range [S1]")
        }
        // Earlier conversation remains in the prompt for continuity; start a clean
        // source-scoped conversation so this assertion can inspect material alone.
        var cleanConversation = reopened.conversation!; cleanConversation.turnIDs = []
        try library.putRecord(collection: "assistant-conversations", id: cleanConversation.id, ownerID: cleanConversation.contextID, value: cleanConversation)
        let scoped = AIAssistantController(library: library, catalog: catalog, settings: settings, flushEdits: { true })
        await scoped.selectContext(itemID: selected.id, classroomID: session.id)
        await scoped.ask("Use only this saved note revision and transcript range")
        let scopedTurn = scoped.turns.last!, scopedSnapshot = scoped.snapshots[scopedTurn.snapshotID]!
        let scopedTranscript = scopedSnapshot.sources.filter { $0.kind == .transcript }
        try require(scopedTurn.runs.last?.state == "completed" && scopedTranscript.count == 1 && scopedTranscript[0].transcriptSnapshot?.id == selectedRangeRow.id && scopedTranscript[0].startMS == 10000 && scopedTranscript[0].endMS == 20000, "user time range includes overlapping full confirmed segments with original timestamps and excludes the end boundary")
        try require(scopedSnapshot.sources.filter { $0.kind == .note }.allSatisfy { $0.version == note.revision && $0.sourceHash == originalNoteSnapshot.sourceHash } && scopedSnapshot.requestedScopes?.count == 2 && scoped.scope(for: noteOption).sourceHash == originalNoteSnapshot.sourceHash, "chosen historical note freezes its real immutable revision hash and persists requested scope")
        let oldScopedCount = AssistantCheckNetwork.count
        scoped.setTranscriptRange(transcriptOption, start: "00:70:00", end: "1")
        await scoped.ask("Invalid range must not send")
        try require(AssistantCheckNetwork.count == oldScopedCount && scoped.error == "invalidTranscriptRange", "invalid time syntax and ordering are rejected before any provider attempt")
        scoped.setTranscriptRange(transcriptOption, start: "30", end: "40")
        let emptyScope = try scoped.sources.snapshot(options: [transcriptOption], selection: nil, intent: .summary, scopes: [scoped.scope(for: transcriptOption)])
        try require(emptyScope.sources.isEmpty && emptyScope.exclusions.contains { $0.contains("noConfirmedTranscript") } && emptyScope.cutoffMS == nil, "empty chosen time range explicitly reports no confirmed transcript rather than substituting all rows")
        var changedVersion = scoped.scope(for: noteOption); changedVersion.sourceHash = "invalid-pinned-hash"
        var rejectedVersion = false
        do { _ = try scoped.sources.snapshot(options: [noteOption], selection: nil, intent: .question, scopes: [changedVersion]) }
        catch { rejectedVersion = error.localizedDescription == "sourceVersionUnavailable" }
        try require(rejectedVersion, "historical revision hash mismatch cannot silently fall back to current saved note")
        scoped.setTranscriptRange(transcriptOption, start: "", end: "")
        scoped.selectNoteVersion(noteOption, version: nil)
        let currentScope = try scoped.sources.snapshot(options: [noteOption, transcriptOption], selection: nil, intent: .question, scopes: scoped.conversation?.sourceScopes ?? [])
        try require(currentScope.sources.contains { $0.kind == .note && $0.text.contains("Long selected source") } && currentScope.sources.filter { $0.kind == .transcript }.count == 3, "clearing scope explicitly restores current saved note and all confirmed transcript")
        scoped.setTranscriptRange(transcriptOption, start: "30", end: "40")
        let choiceBeforeRetry = scopedSnapshot.hash
        await scoped.retry(scopedTurn.id)
        try require(scoped.turns.last?.runs.last?.state == "completed" && scoped.snapshots[scopedTurn.snapshotID]?.hash == choiceBeforeRetry && scoped.scope(for: noteOption).version == nil && scoped.scope(for: transcriptOption).startTime == "30", "retry uses fixed scoped snapshot despite changed current version and time-bound controls")
        let slowMetadata = Task { await scoped.refreshSourceDetails() }
        await scoped.selectContext(itemID: other.id)
        await slowMetadata.value
        try require(scoped.sourceDetails.keys.allSatisfy { key in scoped.options.contains { $0.id == key } }, "late source metadata cannot replace options after a context switch")
        // Preserve the complete original conversation for archive closure and add
        // the scoped turn so both generations of immutable references are checked.
        var archivedConversation = try library.record(collection: "assistant-conversations", id: selected.id, as: AssistantConversation.self)!
        archivedConversation.turnIDs = cleanConversation.turnIDs + controller.turns.map(\.id) + [scopedTurn.id]
        archivedConversation.sourceScopes = [AssistantSourceScope(documentID: session.id, kind: .transcript, startTime: "11", endTime: "20"), AssistantSourceScope(documentID: selected.id, kind: .note, version: note.revision, sourceHash: originalNoteSnapshot.sourceHash)]
        try library.putRecord(collection: "assistant-conversations", id: selected.id, ownerID: selected.id, value: archivedConversation)
        let report: [String: Any] = ["checks": checks, "requests": AssistantCheckNetwork.count, "boundary": "actual CloudHTTPProvider SSE via local URLProtocol fixture; zero actual provider requests, no quality claim", "capture": false, "playback": false, "noteID": selected.id, "snapshotHash": snapshot.hash]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("assistant-checks.json"))
        print("PASS: \(checks.count) assistant source/persistence/streaming/cancellation/retry/save checks; local adapter fixture only")
    }
}
