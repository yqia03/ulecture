import Foundation

private final class ArchiveCheckCredentials: CloudCredentialStore {
    var reads = 0
    func save(_ value: String, reference: String) throws { throw CloudFailure.authentication }
    func read(reference: String) throws -> String? { reads += 1; return nil }
    func remove(reference: String) throws {}
}

/// Uses the actual typed records and authoritative documents from AssistantChecks.
/// No credential resolution, request, audio device or UI is involved.
@main struct AssistantArchiveChecks {
    @MainActor static func main() async throws {
        let input = URL(fileURLWithPath: CommandLine.arguments[1]), out = URL(fileURLWithPath: CommandLine.arguments[2])
        let fm = FileManager.default
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        let source = try LibraryStore(rootURL: input.appendingPathComponent("catalog"))
        try source.configureTranscriptStorage(rootURL: input.appendingPathComponent("transcripts"))
        let sourceCatalog = WorkspaceCatalog(library: source)
        let root = try source.items().first { $0.title == "Selected" }!
        let archive = out.appendingPathComponent("assistant.ulbackup")
        try WorkspaceArchive(catalog: sourceCatalog).backup(itemID: root.id, to: archive)
        let restored = try LibraryStore(rootURL: out.appendingPathComponent("catalog"))
        try restored.configureTranscriptStorage(rootURL: out.appendingPathComponent("transcripts"))
        let catalog = WorkspaceCatalog(library: restored), destination = out.appendingPathComponent("projects")
        try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = try WorkspaceArchive(catalog: catalog).restore(from: archive, into: destination)
        let snapshots = try restored.records(collection: "assistant-snapshots", as: AssistantSnapshot.self)
        let turns = try restored.records(collection: "assistant-turns", as: AssistantTurn.self)
        let conversations = try restored.records(collection: "assistant-conversations", as: AssistantConversation.self)
        var checks: [String] = [], failures: [String] = []
        func check(_ value: Bool, _ message: String) { if value { checks.append(message) } else { failures.append(message) } }
        check(!snapshots.isEmpty && !turns.isEmpty && !conversations.isEmpty, "real Codable AI conversation, turns and snapshots decode after restore")
        for conversation in conversations {
            check(try restored.item(id: conversation.contextID) != nil && conversation.turnIDs.allSatisfy { id in turns.contains { $0.id == id } }, "conversation context and turn links resolve")
            for scope in conversation.sourceScopes ?? [] {
                check(try restored.item(id: scope.documentID) != nil, "saved source-scope document identity resolves after restore")
                if scope.kind == .note, let version = scope.version {
                    let fixed = try BlockNoteStore(packageURL: catalog.documentURL(id: scope.documentID), noteID: scope.documentID).revisionSnapshot(version)
                    check(fixed.sourceHash == scope.sourceHash, "saved selected note version hash follows remapped immutable revision bytes")
                }
            }
        }
        for turn in turns {
            check(snapshots.contains { $0.id == turn.snapshotID }, "turn source snapshot resolves")
            check(!turn.runs.contains { ["running", "preparing", "synthesizing"].contains($0.state) }, "restored attempt cannot remain dispatching")
        }
        var checked = Set<String>()
        for snapshot in snapshots {
            for scope in snapshot.requestedScopes ?? [] {
                if scope.kind == .note, let version = scope.version {
                    let fixed = try BlockNoteStore(packageURL: catalog.documentURL(id: scope.documentID), noteID: scope.documentID).revisionSnapshot(version)
                    check(fixed.sourceHash == scope.sourceHash, "immutable request's selected note version survives archive hash remapping")
                } else if scope.kind == .transcript {
                    let range = try scope.transcriptRange()
                    check(snapshot.sources.filter { $0.documentID == scope.documentID && $0.kind == .transcript }.allSatisfy { (range.start == nil || ($0.endMS ?? -1) > range.start!) && (range.end == nil || ($0.startMS ?? Int64.max) < range.end!) }, "restored requested time range still matches exact included transcript timestamps")
                }
            }
            for source in snapshot.sources {
                let key = source.documentID + ":" + source.sourceHash + ":" + (source.blockID ?? source.id)
                guard checked.insert(key).inserted else { continue }
                let item = try restored.item(id: source.documentID)
                check(item != nil, "snapshot document resolves")
                if source.kind == .note, let item {
                    let store = BlockNoteStore(packageURL: try catalog.documentURL(id: item.id), noteID: item.id)
                    let fixed = try store.revisionSnapshot(source.version), note = fixed.document
                    check(note.blocks.contains { $0.id == source.blockID && $0.plainText.contains(source.text) }, "fixed note revision and remapped block resolve to exact source text")
                    check(fixed.sourceHash == source.sourceHash, "fixed immutable note revision bytes match restored AI source hash")
                } else if source.kind == .transcript, let item {
                    let rows = try restored.transcripts(classroomID: item.id)
                    let row = rows.first { $0.id == source.blockID }
                    let fixed = source.transcriptSnapshot ?? row
                    check(row?.id == fixed?.id && fixed?.startMS == source.startMS && fixed?.endMS == source.endMS && fixed?.text.contains(source.text) == true, "transcript identity and fixed original text and timestamp reference resolve")
                    if let fixed { check(DocumentDisk.hash(try DocumentDisk.json(fixed)) == source.sourceHash, "restored original transcript record hash matches AI source hash") }
                }
            }
        }
        let originalHistory = try source.records(collection: "cloud-state", as: CloudState.self).flatMap(\.summaries)
        let restoredHistory = try restored.records(collection: "cloud-state", as: CloudState.self).flatMap(\.summaries)
        if !originalHistory.isEmpty {
            check(restoredHistory.count == originalHistory.count, "archive closes over historical classroom summaries")
            for historical in originalHistory {
                let recovered = restoredHistory.first { $0.snapshot.hash == historical.snapshot.hash }
                check(recovered?.claims.map(\.text) == historical.claims.map(\.text) && recovered?.snapshot.sources.map(\.text) == historical.snapshot.sources.map(\.text), "historical summary prose and original Markdown/PDF/transcript excerpts survive restoration")
                let originalValid = historical.claims.flatMap(\.referenceIDs).filter { historical.source(for: $0) != nil }.count
                let recoveredValid = recovered?.claims.flatMap(\.referenceIDs).filter { recovered?.source(for: $0) != nil }.count
                check(recoveredValid == originalValid, "historical claim references still resolve to their fixed excerpts after identity remapping")
            }
        }
        let suite = "local.ulecture.scope-archive." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!, credentials = ArchiveCheckCredentials()
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CloudServiceSettings(credentials: credentials, defaults: defaults)
        for conversation in conversations where conversation.sourceScopes?.isEmpty == false {
            let reopened = AIAssistantController(library: restored, catalog: catalog, settings: settings, flushEdits: { true })
            await reopened.selectContext(itemID: conversation.contextID)
            for scope in conversation.sourceScopes ?? [] {
                guard let option = reopened.options.first(where: { $0.id == scope.id }) else { check(false, "restored scope is available in reopened source controls"); continue }
                check(reopened.scope(for: option) == scope, "reopened assistant restores exact selected time or saved-version controls")
                if scope.kind == .note {
                    check(reopened.sourceDetails[option.id]?.versions.contains(where: { $0.version == scope.version && $0.sourceHash == scope.sourceHash }) == true, "reopened saved-version picker contains the restored immutable note revision and updated hash")
                }
            }
            let options = reopened.options.filter { reopened.selectedSourceIDs.contains($0.id) }
            let captured = try reopened.sources.snapshot(options: options, selection: nil, intent: .question, scopes: reopened.conversation?.sourceScopes ?? [])
            check(captured.sources.contains { $0.kind == .note && $0.text.contains("SELECTED evidence") } && captured.sources.filter { $0.kind == .transcript }.count == 1, "source extraction after restoration still selects original historical note and requested transcript range")
            check(credentials.reads == 0, "reopening restored scope controls never reads credentials or sends a request")
        }
        let report: [String: Any] = ["checks": checks, "failures": failures, "boundary": "typed local archive/restore only; no cloud, UI or audio"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("assistant-archive-checks.json"))
        print("Assistant archive checks: \(checks.count) passed, \(failures.count) failed")
        guard failures.isEmpty else { throw DocumentFailure.message(failures.joined(separator: "\n")) }
    }
}
