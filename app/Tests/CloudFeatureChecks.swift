import Foundation

final class FeatureCredentials: CloudCredentialStore {
    var values: [String: String] = [:]; var reads = 0; var metadataReads = 0
    func save(_ value: String, reference: String) throws { values[reference] = value }
    func read(reference: String) throws -> String? { reads += 1; return values[reference] }
    func contains(reference: String) throws -> Bool { metadataReads += 1; return values[reference] != nil }
    func remove(reference: String) throws { values[reference] = nil }
}
final class FeatureNetwork: URLProtocol {
    struct Reply { var status = 200; var data: Data; var delay: Double = 0; var contentType = "application/json" }
    static let lock = NSLock()
    static var requests: [URLRequest] = []
    static var handler: ((URLRequest) throws -> Reply)?
    private var work: DispatchWorkItem?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var captured = request
        if captured.httpBody == nil, let stream = captured.httpBodyStream {
            stream.open(); defer { stream.close() }; var data = Data(); var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; data.append(contentsOf: buffer.prefix(n)) }; captured.httpBody = data
        }
        Self.lock.lock(); Self.requests.append(captured); let handler = Self.handler; Self.lock.unlock()
        do {
            guard let handler else { throw URLError(.unsupportedURL) }; let reply = try handler(captured)
            let next = DispatchWorkItem { [weak self] in
                guard let self, self.work?.isCancelled == false else { return }
                self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": reply.contentType])!, cacheStoragePolicy: .notAllowed)
                self.client?.urlProtocol(self, didLoad: reply.data); self.client?.urlProtocolDidFinishLoading(self)
            }; work = next; DispatchQueue.main.asyncAfter(deadline: .now() + reply.delay, execute: next)
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { work?.cancel() }
    static func reset(_ handler: @escaping (URLRequest) throws -> Reply) { lock.lock(); requests = []; self.handler = handler; lock.unlock() }
    static var count: Int { lock.lock(); defer { lock.unlock() }; return requests.count }
}

#if !DOCUMENT_TRANSLATION_TESTING
@main struct CloudFeatureChecks {
    @MainActor static func main() async throws {
        var checks: [String] = []
        func check(_ value: @autoclosure () -> Bool, _ label: String) throws { guard value() else { throw NSError(domain: "CloudFeatureChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }; checks.append(label) }
        func wait(_ predicate: @escaping @MainActor () -> Bool) async throws { let end = Date().addingTimeInterval(8); while !predicate() { if Date() > end { throw URLError(.timedOut) }; try await Task.sleep(nanoseconds: 10_000_000) } }
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("ulecture-features-" + UUID().uuidString)
        let cfg = URLSessionConfiguration.ephemeral; cfg.protocolClasses = [FeatureNetwork.self]; let session = URLSession(configuration: cfg)
        let suite = "ulecture.contract." + UUID().uuidString; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); session.invalidateAndCancel() }
        let credentials = FeatureCredentials()
        FeatureNetwork.reset { _ in throw URLError(.unsupportedURL) }
        let settings = CloudServiceSettings(initialConfiguration: CloudConfiguration(provider: .openAI), credentials: credentials, session: session, defaults: defaults)
        try check(credentials.reads == 0 && credentials.metadataReads == 0 && FeatureNetwork.count == 0, "constructing settings reads no secret or credential metadata and sends no request")
        try settings.saveCredential("fixture-openai-secret")
        try check(settings.status == .savedUnverified && credentials.reads == 0 && FeatureNetwork.count == 0, "save persists credential without reading it or testing connection")
        settings.refreshCredentialStatus()
        try check(credentials.reads == 0 && credentials.metadataReads == 1 && settings.status == .savedUnverified, "opening settings checks presence only")
        let old = try settings.authorize()
        try settings.selectProvider(.geminiDeveloper)
        try check(settings.status == .unconfigured && FeatureNetwork.count == 0, "provider switch immediately shows matching unsaved state without traffic")
        try settings.saveCredential("fixture-aistudio-secret")
        func envelope(_ request: URLRequest, _ content: [String: Any], delay: Double = 0) throws -> FeatureNetwork.Reply {
            let text = String(decoding: try JSONSerialization.data(withJSONObject: content), as: UTF8.self)
            let json: [String: Any] = request.url!.host == "api.openai.com" ? ["status": "completed", "output": [["content": [["type": "output_text", "text": text]]]], "usage": ["input_tokens": 3, "output_tokens": 4]] : ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": text]]]]], "usageMetadata": ["promptTokenCount": 3, "candidatesTokenCount": 4]]
            return FeatureNetwork.Reply(data: try JSONSerialization.data(withJSONObject: json), delay: delay)
        }
        FeatureNetwork.reset { try envelope($0, ["ok": true]) }
        _ = try await settings.perform(old, instruction: "Return JSON", input: "test")
        try check(FeatureNetwork.requests.first?.value(forHTTPHeaderField: "Authorization") == "Bearer fixture-openai-secret" && settings.status == .savedUnverified, "old authorization retains its provider and key and cannot verify the new provider")
        await settings.testConnection()
        try check(FeatureNetwork.requests.last?.value(forHTTPHeaderField: "x-goog-api-key") == "fixture-aistudio-secret" && FeatureNetwork.requests.last?.url?.query == nil && settings.status == .requestSucceeded, "AI Studio explicit test uses header key and verifies only current configuration")
        let persistedSettings = defaults.data(forKey: "ulecture.cloud-settings.v1")!
        try check(!String(decoding: persistedSettings, as: UTF8.self).contains("fixture-"), "settings persistence excludes all secret values")
        try settings.removeCredential(); try check(settings.status == .unconfigured && credentials.values["classroom.openAI"] != nil, "remove key affects selected product only")
        try settings.saveCredential("fixture-aistudio-secret")

        for path in CloudProvider.selectable {
            try settings.selectProvider(path)
            try settings.saveCredential("fixture-" + path.rawValue)
            let chunks = path == .openAI ? ["data: {\"type\":\"response.output_text.delta\",\"delta\":\"你好\"}\n\n", "data: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":4,\"output_tokens\":2}}}\n\n"] : path.usesChatCompletions ? ["data: {\"choices\":[{\"delta\":{\"content\":\"你好\"},\"finish_reason\":null}]}\n\n", "data: {\"choices\":[{\"delta\":{},\"finish_reason\":\"stop\"}]}\n\ndata: {\"choices\":[],\"usage\":{\"prompt_tokens\":4,\"completion_tokens\":2}}\n\ndata: [DONE]\n\n"] : ["data: {\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"你好\"}]}}]}\n\n", "data: {\"candidates\":[{\"finishReason\":\"STOP\"}],\"usageMetadata\":{\"promptTokenCount\":4,\"candidatesTokenCount\":2}}\n\n"]
            FeatureNetwork.reset { _ in FeatureNetwork.Reply(data: Data(chunks.joined().utf8), contentType: "text/event-stream") }
            var deltas = ""
            let stream = try await settings.stream(settings.authorize(), instruction: "Answer", input: "hello") { deltas += $0 }
            try check(stream.text == "你好" && deltas == "你好" && stream.usage.inputTokens == 4, "\(path.rawValue) SSE delivers Unicode deltas and terminal usage")
            let body = try JSONSerialization.jsonObject(with: FeatureNetwork.requests[0].httpBody!) as! [String: Any]
            if path == .openAI { try check(body["stream"] as? Bool == true && body["text"] == nil, "OpenAI chat streaming requests free text without JSON-only schema") }
            else if path.usesChatCompletions { try check(body["stream"] as? Bool == true && body["response_format"] == nil && FeatureNetwork.requests[0].url!.path.hasSuffix("/chat/completions"), "Chat Completions streams plain text") }
            else { try check(FeatureNetwork.requests[0].url!.absoluteString.contains(":streamGenerateContent?alt=sse"), "AI Studio streaming uses the documented endpoint") }
            FeatureNetwork.reset { _ in FeatureNetwork.Reply(data: Data(chunks[0].utf8), contentType: "text/event-stream") }
            do { _ = try await settings.stream(settings.authorize(), instruction: "Answer", input: "hello") { _ in }; throw CloudFailure.invalidConfiguration } catch CloudFailure.malformedResponse { }
            try check(settings.lastError == .malformedResponse, "\(path.rawValue) missing terminal event is a partial failure")
        }

        FeatureNetwork.reset { _ in throw URLError(.unsupportedURL) }
        let text = TextTranslationController(settings: settings, directory: temp)
        let multiline = TranslationTerm(source: "context", translation: "上下文", note: "quote \"test\", next\nline", scopeID: "text")
        try text.saveTerm(multiline)
        let exported = try text.exportTerms(format: "csv")
        let decoded = try TranslationTermFile.decode(exported, csv: true, scopeID: "course-a")
        try check(decoded.count == 1 && decoded[0].note == multiline.note && decoded[0].scopeID == "course-a", "CSV round trips quotes commas multiline Unicode and imports only into selected scope")
        do { try text.saveTerm(TranslationTerm(source: "CONTEXT", translation: "语境")); throw CloudFailure.invalidConfiguration } catch is TranslationTermConflict { }
        try check(text.glossary.terms.count == 1, "same language pair scope source conflict cannot silently overwrite")
        let revision = text.glossary.revision
        do { _ = try text.importTerms(exported, format: "csv", policy: .rejectConflicts); throw CloudFailure.invalidConfiguration } catch is TranslationTermConflict { }
        try check(text.glossary.revision == revision, "conflicting import is atomic")
        _ = try text.importTerms(exported, format: "csv", policy: .replaceExisting)
        try check(text.glossary.terms.count == 1 && text.glossary.terms[0].id == multiline.id, "explicit replacement preserves stable term identity")
        text.setScope("course-b"); try check(text.currentTerms.isEmpty, "another course does not inherit text terminology")
        text.setScope("text"); text.updateInput("context " + String(repeating: "x", count: 2600)); text.flush()
        func input(_ request: URLRequest) throws -> [String: Any] {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let source: String
            if let value = body["input"] as? String { source = value }
            else {
                let contents = body["contents"] as! [[String: Any]]
                let parts = contents[0]["parts"] as! [[String: Any]]
                source = parts[0]["text"] as! String
            }
            return try JSONSerialization.jsonObject(with: Data(source.utf8)) as! [String: Any]
        }
        try settings.selectProvider(.openAI)
        var usageCount = 0
        settings.onUsage = { _ in usageCount += 1; if usageCount == 1 { try? settings.selectProvider(.geminiDeveloper) } }
        FeatureNetwork.reset { request in try envelope(request, ["id": try input(request)["id"]!, "text": "上下文译文"]) }
        text.translate(); try await wait { !text.isRunning }
        try check(text.document.status == .completed && text.completedChunks == 2 && FeatureNetwork.count == 2, "text production pipeline translates and durably completes all chunks")
        try check(text.document.run!.chunks[0].dispatches[0].configuration.provider == .openAI && text.document.run!.chunks[1].dispatches[0].configuration.provider == .geminiDeveloper, "each next dispatch uses current provider while retaining immutable prior dispatch metadata")
        let firstBody = String(decoding: FeatureNetwork.requests[0].httpBody!, as: UTF8.self)
        try check(firstBody.contains("Custom terminology overrides") && firstBody.contains("上下文"), "production translation sends explicit custom-term precedence and matching terminology")
        let restored = TextTranslationController(settings: settings, directory: temp)
        try check(restored.result == text.result && restored.document.input == text.document.input && FeatureNetwork.count == 2, "restart restores input results and terminology without dispatch")
        settings.onUsage = nil
        text.updateInput("cancel this source"); FeatureNetwork.reset { request in try envelope(request, ["id": try input(request)["id"]!, "text": "late"], delay: 0.2) }
        text.translate(); try await wait { FeatureNetwork.count == 1 }; text.cancel(); text.updateInput("new source")
        try await Task.sleep(nanoseconds: 300_000_000)
        try check(text.result.isEmpty && text.document.input == "new source" && text.document.status == .ready, "cancel and source edit isolate delayed response from replacement workspace")
        FeatureNetwork.reset { _ in throw URLError(.unsupportedURL) }
        let failed = TextTranslationController(settings: settings, directory: temp.appendingPathComponent("unwritable"), saveData: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        failed.updateInput("retained source"); failed.translate()
        try check(failed.lastError == .persistence && failed.document.input == "retained source" && FeatureNetwork.count == 0, "failed dispatch checkpoint preserves draft and prevents request")
        let failedExit = await failed.prepareForExit()
        try check(!failedExit, "exit refuses only actual unsaved text after a failed disk checkpoint")
        let damagedDirectory = temp.appendingPathComponent("damaged")
        try FileManager.default.createDirectory(at: damagedDirectory, withIntermediateDirectories: true)
        try Data("invalid record".utf8).write(to: damagedDirectory.appendingPathComponent("text-workspace.json"))
        let damaged = TextTranslationController(settings: settings, directory: damagedDirectory)
        let cleanExit = await damaged.prepareForExit()
        try check(damaged.storageBlocked && cleanExit, "unchanged corrupt text history can exit without overwriting or claiming repair")
        var partial = text.document
        partial.status = .running
        partial.run = TextTranslationRun(revision: partial.revision, sourceLanguage: "en", targetLanguage: "zh-Hans", domain: .general, glossaryRevision: 1, terms: [], chunks: [TextTranslationChunk(source: "first", result: "already saved"), TextTranslationChunk(source: "second")])
        try JSONEncoder().encode(partial).write(to: temp.appendingPathComponent("text-workspace.json"), options: .atomic)
        let interrupted = TextTranslationController(settings: settings, directory: temp)
        try check(interrupted.document.status == .interrupted && FeatureNetwork.count == 0 && interrupted.canRetry, "restart marks in-flight translation interrupted without auto replay")
        FeatureNetwork.reset { request in try envelope(request, ["id": try input(request)["id"]!, "text": "recovered"]) }
        interrupted.translate(retry: true); try await wait { !interrupted.isRunning }
        try check(FeatureNetwork.count == 1 && interrupted.result == "already saved\n\nrecovered", "retry dispatches unfinished chunks only")
        let classroom = CloudController(state: CloudState(classID: "active"), configuration: settings.configuration, session: session, credentials: credentials, monitorNetwork: false)
        classroom.onPersist = { _ in }; classroom.credentialResolver = { try settings.credential(for: $0) }; await classroom.setClassActive(true)
        let source = SummarySource(kind: .note, entityID: "n", version: 1, text: "saved note")
        FeatureNetwork.reset { request in try envelope(request, ["claims": [["text": "总结", "referenceIDs": [source.id]]]]) }
        await classroom.generateSummary(SummarySnapshot(classID: "active", sources: [source]), classEnded: false)
        try await wait { !classroom.summaryRunning }
        try check(classroom.state.summaries.first?.status == "completed" && FeatureNetwork.count == 1, "active class accepts explicit saved-material summary without end-class gate")
        await classroom.shutdown()
        let output: [String: Any] = ["passed": true, "checks": checks, "realProviderRequests": 0, "realCredentialReads": 0, "evidenceDirectory": temp.path]
        print(String(decoding: try JSONSerialization.data(withJSONObject: output, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
#endif
