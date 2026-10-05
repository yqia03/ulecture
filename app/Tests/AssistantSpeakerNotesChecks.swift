import Foundation

private final class NoSpeakerKey: CloudCredentialStore {
    var reads = 0
    func read(reference: String) throws -> String? { reads += 1; return nil }
    func save(_ value: String, reference: String) throws { throw DocumentFailure.invalidFormat }
    func remove(reference: String) throws {}
}
private final class NoSpeakerRequests: URLProtocol {
    static var requests = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.requests += 1; client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
@main struct AssistantSpeakerNotesChecks {
    @MainActor static func main() async throws {
        let fixture = URL(fileURLWithPath: CommandLine.arguments[1]), out = URL(fileURLWithPath: CommandLine.arguments[2]), fm = FileManager.default
        let library = try LibraryStore(rootURL: out.appendingPathComponent("catalog")), catalog = WorkspaceCatalog(library: library)
        let course = try catalog.createCourse(title: "course")
        let slide = try catalog.importDocument(from: fixture.appendingPathComponent("source.pptx"), parentID: course.id)
        let source = try catalog.documentURL(id: slide.id), hash = try DocumentDisk.hash(source)
        let job = try JSONSerialization.jsonObject(with: Data(contentsOf: fixture.appendingPathComponent("job.json"))) as! [String: Any]
        guard job["sourceHash"] as? String == hash else { throw DocumentFailure.message("Converted job source identity mismatch") }
        let actualNotes = try JSONDecoder().decode([DocumentSlideNote].self, from: JSONSerialization.data(withJSONObject: job["slideNotes"]!))
        let metadata = SlideMetadata(notes: actualNotes)
        guard !metadata.notes.isEmpty else { throw DocumentFailure.message("Actual PPTX has no notes") }
        let cache = try catalog.metadataDirectory(documentID: slide.id).appendingPathComponent("reading")
        try fm.createDirectory(at: cache, withIntermediateDirectories: true)
        let pdf = cache.appendingPathComponent(hash + "-" + ConversionResources.readingCacheVersion + ".pdf")
        try fm.copyItem(at: fixture.appendingPathComponent("normalized.pdf"), to: pdf)
        try JSONEncoder().encode(metadata).write(to: cache.appendingPathComponent(hash + "-slides.json"))
        let suite = "local.ulecture.speaker-notes-check." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = NoSpeakerKey(), config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [NoSpeakerRequests.self]
        let settings = CloudServiceSettings(initialConfiguration: CloudConfiguration(provider: .openAI), credentials: credentials, session: URLSession(configuration: config), defaults: defaults)
        let controller = AIAssistantController(library: library, catalog: catalog, settings: settings, flushEdits: { true })
        var checks: [String] = []
        func check(_ value: Bool, _ label: String) throws { guard value else { throw DocumentFailure.message(label) }; checks.append(label) }
        await controller.selectContext(itemID: slide.id)
        try check(controller.options.contains { $0.kind == .speakerNotes } && controller.selectedSourceIDs == ["pdf:" + slide.id] && credentials.reads == 0, "speaker notes appear as a separate unchecked option without credential reads")
        await controller.ask("Inspect default source selection")
        let ordinary = controller.snapshots[controller.turns.last!.snapshotID]!
        try check(!ordinary.sources.contains { $0.kind == .speakerNotes } && ordinary.exclusions.contains { $0.contains("speakerNotesNotSelected") }, "default generation excludes notes and records that coverage boundary")
        controller.selectSource("speakerNotes:" + slide.id, included: true)
        await controller.ask("Inspect explicitly selected notes")
        let chosen = controller.snapshots[controller.turns.last!.snapshotID]!
        let notes = chosen.sources.filter { $0.kind == .speakerNotes }
        try check(notes.count == metadata.notes.count && notes.first?.text == metadata.notes.first?.text && notes.first?.page == metadata.notes.first?.sourcePage, "actual PPTX notes are frozen with their real slide number")
        try check(notes.first?.sourceHash == hash && notes.first?.navigationHash == DocumentDisk.hash(pdf), "presentation and converted PDF identities remain distinct for note citations")
        try check(chosen.sources.contains { $0.kind == .pdf } && !chosen.exclusions.contains { $0.contains("speakerNotesNotSelected") || $0.contains("speakerNotesExcluded") }, "selected notes stay separate from PDF body and coverage reflects the selection")
        controller.selectSource("pdf:" + slide.id, included: false)
        await controller.ask("Use only the notes")
        let only = controller.snapshots[controller.turns.last!.snapshotID]!
        try check(only.sources.allSatisfy { $0.kind == .speakerNotes } && NoSpeakerRequests.requests == 0, "notes-only selection never uploads slide body and missing key sends no requests")
        try JSONSerialization.data(withJSONObject: ["checks": checks, "sourceHash": hash, "providerRequests": NoSpeakerRequests.requests, "boundary": "actual previously converted PDF and actual slide notes from its hash-matched persisted job; production cache/source freeze and no-key path; no live cloud or new LibreOffice run"], options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("speaker-notes-checks.json"))
        print("PASS: \(checks.count) speaker-note source selection/version/coverage checks")
    }
}
