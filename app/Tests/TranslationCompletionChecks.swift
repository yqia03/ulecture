import Foundation
import PDFKit

@main struct TranslationCompletionChecks {
    @MainActor static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var checks: [String] = []
        func check(_ value: Bool, _ label: String) throws { guard value else { throw NSError(domain: "TranslationCompletionChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }; checks.append(label) }
        func wait(_ predicate: @escaping @MainActor () -> Bool) async throws { let end = Date().addingTimeInterval(10); while !predicate() { guard Date() < end else { throw URLError(.timedOut) }; try await Task.sleep(nanoseconds: 10_000_000) } }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FeatureNetwork.self]; let session = URLSession(configuration: config)
        defer { session.invalidateAndCancel() }
        func reply(_ request: URLRequest) throws -> FeatureNetwork.Reply {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let input = try JSONSerialization.jsonObject(with: Data((body["input"] as! String).utf8)) as! [String: Any]
            let text = String(decoding: try JSONSerialization.data(withJSONObject: ["id": input["id"]!, "text": "工作记忆"]), as: UTF8.self)
            return FeatureNetwork.Reply(data: try JSONSerialization.data(withJSONObject: ["status": "completed", "output": [["content": [["type": "output_text", "text": text]]]]]))
        }
        let classID = UUID().uuidString, courseID = UUID().uuidString
        let cloud = CloudController(state: CloudState(classID: classID), configuration: CloudConfiguration(provider: .openAI), session: session, credentials: FeatureCredentials(), monitorNetwork: false)
        cloud.onPersist = { try JSONEncoder().encode($0).write(to: output.appendingPathComponent("classroom.json"), options: .atomic) }
        cloud.credentialResolver = { _ in "fixture-only" }; await cloud.setUserPaused(true)
        var term = TranslationTerm(source: "Working memory", translation: "工作记忆", scopeID: courseID)
        let snapshot = ClassroomTerminologySnapshot(scopeID: courseID, revision: 7, terms: [term])
        func segment(_ number: Int) -> CloudSegment { CloudSegment(id: "segment\(number)", classID: classID, revision: 1, text: "Working memory supports learning.", language: "en", startMS: Int64(number * 1000), endMS: Int64(number * 1000 + 500), confirmedAt: Date()) }
        FeatureNetwork.reset { try reply($0) }
        try await cloud.enqueueSavedSegment(segment(1), targetLanguage: "zh-Hans")
        try await cloud.configureTerminology(snapshot)
        try check(FeatureNetwork.count == 0 && cloud.state.translationUserPaused && cloud.state.jobs[0].terminology == nil, "explicit terminology selection persists without authorizing or unpausing cloud work")
        FeatureNetwork.reset { _ in FeatureNetwork.Reply(status: 401, data: Data("{}".utf8)) }
        await cloud.setUserPaused(false); try await wait { cloud.state.jobs.first?.status == .needsAttention }
        let firstID = cloud.state.jobs[0].id
        try check(cloud.state.jobs[0].terminology == snapshot && cloud.state.jobs[0].terminologyFrozen == true, "first dispatch freezes the explicitly enabled course table and revision")
        term.translation = "新的译法"
        try await cloud.configureTerminology(ClassroomTerminologySnapshot(scopeID: courseID, revision: 8, terms: [term]))
        FeatureNetwork.reset { try reply($0) }; await cloud.retry(jobID: firstID); try await wait { cloud.state.jobs[0].status == .completed }
        let retriedPrompt = String(decoding: FeatureNetwork.requests[0].httpBody!, as: UTF8.self)
        try check(retriedPrompt.contains("工作记忆") && !retriedPrompt.contains("新的译法") && cloud.state.jobs[0].terminology?.revision == 7, "retry uses the original terminology snapshot after the selected table changes")
        FeatureNetwork.reset { try reply($0) }; try await cloud.enqueueSavedSegment(segment(2), targetLanguage: "zh-Hans"); try await wait { cloud.state.jobs.last?.status == .completed }
        try check(cloud.state.jobs.last?.terminology?.revision == 8 && String(decoding: FeatureNetwork.requests[0].httpBody!, as: UTF8.self).contains("新的译法"), "a newly dispatched segment uses the explicitly updated table")
        try await cloud.configureTerminology(nil); FeatureNetwork.reset { try reply($0) }
        try await cloud.enqueueSavedSegment(segment(3), targetLanguage: "zh-Hans"); try await wait { cloud.state.jobs.last?.status == .completed }
        try check(cloud.state.jobs.last?.terminology == nil && !String(decoding: FeatureNetwork.requests[0].httpBody!, as: UTF8.self).contains("新的译法"), "disabling terminology affects subsequent first dispatches without rewriting prior jobs")
        var legacy = CloudState(classID: classID); legacy.jobs = [CloudTranslationJob(segment: segment(4), targetLanguage: "zh-Hans")]
        var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as! [String: Any]
        var rows = legacyJSON["jobs"] as! [[String: Any]]; rows[0].removeValue(forKey: "terminologyFrozen"); legacyJSON["jobs"] = rows
        let decoded = try JSONDecoder().decode(CloudState.self, from: JSONSerialization.data(withJSONObject: legacyJSON))
        let old = CloudController(state: decoded, configuration: CloudConfiguration(provider: .openAI), session: session, credentials: FeatureCredentials(), monitorNetwork: false)
        old.onPersist = { _ in }; old.credentialResolver = { _ in "fixture-only" }; try await old.configureTerminology(snapshot)
        FeatureNetwork.reset { try reply($0) }; await old.pump(); try await wait { old.state.jobs[0].status == .completed }
        try check(old.state.jobs[0].terminology == nil && !String(decoding: FeatureNetwork.requests[0].httpBody!, as: UTF8.self).contains("工作记忆"), "legacy queued checkpoints without a glossary marker remain explicitly glossary-free")
        var invalid = snapshot; invalid.terms[0].scopeID = "other-course"
        do { try await cloud.configureTerminology(invalid); throw CloudFailure.malformedResponse } catch CloudFailure.invalidConfiguration { }
        try check(cloud.state.terminologySelection == nil, "another course's table cannot be silently enabled")
        await cloud.shutdown(); await old.shutdown()

        let suite = "ulecture.version-check." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = CloudServiceSettings(credentials: FeatureCredentials(), session: session, defaults: defaults)
        for version in ["legacy", "future"] {
            let directory = output.appendingPathComponent("text-" + version); try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            var text = TextTranslationDocument(); text.input = "Working memory"; text.status = .interrupted
            text.run = TextTranslationRun(revision: 1, sourceLanguage: "en", targetLanguage: "zh-Hans", domain: .general, glossaryRevision: 1, terms: [], chunks: [TextTranslationChunk(source: "Working", result: "已有译文"), TextTranslationChunk(source: "memory")])
            var record = try JSONSerialization.jsonObject(with: JSONEncoder().encode(text)) as! [String: Any]; var run = record["run"] as! [String: Any]
            if version == "legacy" { run.removeValue(forKey: "promptVersion") } else { run["promptVersion"] = "unsupported-future" }; record["run"] = run
            let bytes = try JSONSerialization.data(withJSONObject: record), path = directory.appendingPathComponent("text-workspace.json"); try bytes.write(to: path)
            FeatureNetwork.reset { _ in throw URLError(.unsupportedURL) }
            let controller = TextTranslationController(settings: settings, directory: directory); controller.translate(retry: true)
            try check(controller.lastError == .incompatibleCheckpoint && controller.result == "已有译文" && FeatureNetwork.count == 0 && (try Data(contentsOf: path)) == bytes, "\(version) text checkpoint retains its result and file without dispatch under an incompatible prompt")
        }
        let sourceJob = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let sourceData = try Data(contentsOf: sourceJob.appendingPathComponent("job.json"))
        for version in ["legacy", "future"] {
            var record = try JSONSerialization.jsonObject(with: sourceData) as! [String: Any]
            record["status"] = "partial"
            if version == "legacy" { record.removeValue(forKey: "processingVersion") }
            else { var pipeline = try JSONSerialization.jsonObject(with: JSONEncoder().encode(DocumentProcessingVersion.current)) as! [String: Any]; pipeline["prompt"] = "unsupported-future"; record["processingVersion"] = pipeline }
            let directory = output.appendingPathComponent("documents-" + version), job = directory.appendingPathComponent(record["id"] as! String)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true); try FileManager.default.copyItem(at: sourceJob, to: job)
            let bytes = try JSONSerialization.data(withJSONObject: record), path = job.appendingPathComponent("job.json"); try bytes.write(to: path)
            let controller = DocumentTranslationController(settings: settings, directory: directory)
            let pdfHash = documentHash(try Data(contentsOf: controller.outputURL!)); FeatureNetwork.reset { _ in throw URLError(.unsupportedURL) }; controller.retry()
            let exported = try controller.export(to: output.appendingPathComponent(version + "-old-output.pdf"))
            try check(controller.lastError == "incompatibleCheckpoint" && FeatureNetwork.count == 0 && documentHash(try Data(contentsOf: exported)) == pdfHash && (try Data(contentsOf: path)) == bytes, "\(version) document checkpoint preserves and exports old PDF without mixing processing versions")
        }
        let report: [String: Any] = ["passed": true, "checks": checks, "realProviderRequests": 0, "realCredentialReads": 0]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("translation-completion-checks.json"))
        print("Passed \(checks.count) translation scope and checkpoint checks")
    }
}
