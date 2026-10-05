import Foundation
import PDFKit

@main struct DocumentTranslationChecks {
    @MainActor static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fixture = root.appendingPathComponent("app/Tests/Fixtures/Conversion")
        let output = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        var resources = ConversionResources(directory: CommandLine.arguments.count > 3 ? URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true) : root.appendingPathComponent("app/build/conversion"))
        if CommandLine.arguments.count <= 3 { resources.libreOffice = root.appendingPathComponent("app/Dependencies/libreoffice-26.8.0/LibreOffice.app/Contents/MacOS/soffice") }
        var checks: [String] = []
        func check(_ value: @autoclosure () -> Bool, _ label: String) throws { guard value() else { throw NSError(domain: "DocumentTranslationChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }; checks.append(label) }
        func wait(_ predicate: @escaping @MainActor () -> Bool, seconds: Double = 120) async throws { let end = Date().addingTimeInterval(seconds); while !predicate() { if Date() > end { throw URLError(.timedOut) }; try await Task.sleep(nanoseconds: 20_000_000) } }
        let config = URLSessionConfiguration.ephemeral; config.protocolClasses = [FeatureNetwork.self]
        let session = URLSession(configuration: config)
        let suite = "ulecture.documents.contract." + UUID().uuidString; let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite); session.invalidateAndCancel() }
        let credentials = FeatureCredentials()
        let settings = CloudServiceSettings(initialConfiguration: CloudConfiguration(provider: .openAI), credentials: credentials, session: session, defaults: defaults)
        try settings.saveCredential("fixture-openai"); try settings.selectProvider(.geminiDeveloper); try settings.saveCredential("fixture-aistudio"); try settings.selectProvider(.openAI)
        func input(_ request: URLRequest) throws -> [[String: String]] {
            let body = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
            let source: String
            if let value = body["input"] as? String { source = value }
            else { source = ((body["contents"] as! [[String: Any]])[0]["parts"] as! [[String: Any]])[0]["text"] as! String }
            return (try JSONSerialization.jsonObject(with: Data(source.utf8)) as! [String: Any])["blocks"] as! [[String: String]]
        }
        func envelope(_ request: URLRequest, delay: Double = 0) throws -> FeatureNetwork.Reply {
            let translations = try input(request).map { ["id": $0["id"]!, "text": "译文：上下文促进学习，练习帮助记忆。"] }
            let text = String(decoding: try JSONSerialization.data(withJSONObject: ["translations": translations]), as: UTF8.self)
            let data: [String: Any] = request.url!.host == "api.openai.com" ? ["status": "completed", "output": [["content": [["type": "output_text", "text": text]]]], "usage": ["input_tokens": 20, "output_tokens": 30]] : ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": text]]]]], "usageMetadata": ["promptTokenCount": 20, "candidatesTokenCount": 30]]
            return FeatureNetwork.Reply(data: try JSONSerialization.data(withJSONObject: data), delay: delay)
        }
        FeatureNetwork.reset { try envelope($0) }
        let controller = DocumentTranslationController(settings: settings, directory: output.appendingPathComponent("jobs"), resources: resources)
        try check(credentials.reads == 0 && FeatureNetwork.count == 0, "construction and saved-key setup perform no credential reads or requests")
        let originalHash = documentHash(try Data(contentsOf: fixture.appendingPathComponent("complex.pdf")))
        var dispatch = 0
        settings.onUsage = { _ in dispatch += 1; if dispatch == 1 { try? settings.selectProvider(.geminiDeveloper) } }
        controller.start(source: fixture.appendingPathComponent("complex.pdf"), sourceLanguage: "en", targetLanguage: "zh-Hans", mode: .translated, engine: .native)
        try await wait { !controller.isRunning }
        guard let first = controller.selectedJob else { throw DocumentConversionError.invalidOutput }
        print("PDF status=\(first.status) error=\(first.error ?? "none") directory=\(controller.jobDirectory(first.id).path)")
        try check(first.status == .completed && first.completedCount == 15, "real PDF native and local OCR regions complete through production provider adapters")
        let pdf = PDFDocument(url: controller.outputURL!)!
        try check(pdf.pageCount >= 3 && pdf.string?.contains("上下文") == true && pdf.string?.contains("nested Form") == false, "translation-only output has searchable Chinese and no removed nested Form original text")
        let coverage = try JSONSerialization.jsonObject(with: Data(contentsOf: controller.jobDirectory(first.id).appendingPathComponent("background.pdf.coverage.json"))) as! [String: Any]
        try check(first.pages.filter { $0.rasterDPI == 300 }.map(\.number) == coverage["rasterPages"] as? [Int] && first.mapping.count == 3 && first.mapping.allSatisfy { !$0.outputPages.isEmpty }, "actual raster fallback coverage and source-to-output mapping are persisted without false claims")
        try check(Set(first.regions.flatMap(\.dispatches).map { $0.configuration.provider }) == Set([CloudProvider.openAI, .geminiDeveloper]), "next document batch uses changed provider while earlier dispatch retains frozen metadata")
        let unchangedHash = documentHash(try Data(contentsOf: fixture.appendingPathComponent("complex.pdf")))
        try check(unchangedHash == originalHash, "original PDF bytes are unchanged")
        let saved = try controller.export(to: output.appendingPathComponent("translated.pdf")); let savedAgain = try controller.export(to: saved)
        try check(saved != savedAgain && PDFDocument(url: savedAgain)?.pageCount == pdf.pageCount, "PDF save validates actual output and prevents collisions")
        settings.onUsage = nil
        controller.start(source: fixture.appendingPathComponent("complex.pdf"), sourceLanguage: "en", targetLanguage: "zh-Hant", mode: .bilingual, engine: .native)
        try await wait { !controller.isRunning }
        let bilingual = controller.selectedJob!, both = PDFDocument(url: controller.outputURL!)!
        try check(bilingual.status == .completed && both.pageCount >= 6 && both.string?.contains("Working memory") == true && both.string?.contains("上下文") == true, "bilingual PDF preserves source pages alongside searchable translated pages")
        try check(bilingual.mapping.allSatisfy { $0.outputPages.count >= 2 }, "bilingual source pages map to source and translated output pages")
        for name in ["lesson.md", "lesson.txt", "lesson.ulnote", "lesson.pptx", "lesson.ppt", "fidelity.pptx", "rotated.pdf"] {
            controller.start(source: fixture.appendingPathComponent(name), sourceLanguage: "en", targetLanguage: "zh-Hans", mode: .translated, engine: .native)
            try await wait { !controller.isRunning }
            let job = controller.selectedJob!
            print("\(name) status=\(job.status) error=\(job.error ?? "none") directory=\(controller.jobDirectory(job.id).path)")
            try check([.completed, .partial].contains(job.status) && controller.outputURL.flatMap { PDFDocument(url: $0)?.string }?.contains("上下文") == true, "\(name) produces a real searchable translated PDF")
            if name == "lesson.md" {
                try check(job.regions.contains { $0.kind == "code" && $0.translation == nil } && job.regions.filter { $0.id.contains(".r") }.count == 4, "Markdown code is preserved while table cells translate individually")
                let exported = try controller.export(to: output.appendingPathComponent("translated-notes.md"), companion: true)
                let text = try String(contentsOf: exported, encoding: .utf8)
                try check(text.contains("print(\"preserve code\")") && text.contains("-assets-") && !text.contains("](flow-assets/"), "editable Markdown export includes preserved code and portable copied image references")
            }
            if name == "lesson.ulnote" {
                let exported = try controller.export(to: output.appendingPathComponent("translated-note.ulnote"), companion: true)
                let note = try JSONSerialization.jsonObject(with: Data(contentsOf: exported.appendingPathComponent("note.json"))) as! [String: Any]
                try check(note["id"] as? String != "fixture-note" && note["revision"] as? Int == 1 && FileManager.default.fileExists(atPath: exported.appendingPathComponent("assets/scan.png").path), "new editable note retains structure and image assets with separate identity")
            }
            if ["lesson.ppt", "lesson.pptx"].contains(name) {
                let extracted = job.regions.map(\.source).joined(separator: "\n")
                try check(extracted.contains("日本語") && extracted.contains("中文") && extracted.contains("Effect") && extracted.contains("Practice") && !extracted.contains("\u{000C}"), "\(name) preserves real Japanese Chinese and Latin ligature source text")
                try check(job.slideNotes?.first?.sourcePage == 1 && job.slideNotes?.first?.text.contains("Speaker notes") == true && job.regions.allSatisfy { !$0.source.contains("Speaker notes") }, "\(name) notes retain source page mapping and stay outside cloud-translated body")
                try check(job.fontReports?.contains { $0.requestedFont == "FixtureMissingFont" && $0.sourcePages == [1] && !$0.renderedFonts.isEmpty } == true, "\(name) missing font and observed output fonts are reported with affected pages")
            }
            if name == "fidelity.pptx" {
                try check(job.warnings.contains("animationsDetected") && job.regions.contains { $0.kind == "formula" && $0.translation == nil } && job.pages.count == 1, "animated chart and formula slide preserves static page mapping and excludes formula from translation")
            }
            if name == "rotated.pdf" {
                let nested = job.regions.filter { $0.source.contains("nested Form") || $0.source.contains("Context improves") }
                try check(nested.count == 2 && nested.allSatisfy { abs($0.angle + .pi/2) < 0.01 }, "rotated nested Form translations inherit the actual page-space text angle")
            }
        }
        let requestsBeforeRestore = FeatureNetwork.count
        controller.start(source: fixture.appendingPathComponent("lesson.pptx"), sourceLanguage: "ja", targetLanguage: "zh-Hant", mode: .bilingual, engine: .native)
        try await wait { !controller.isRunning }
        let bilingualSlideText = controller.outputURL.flatMap { PDFDocument(url: $0)?.string } ?? ""
        try check(controller.selectedJob?.status == .completed && bilingualSlideText.contains("日本語") && bilingualSlideText.contains("中文") && bilingualSlideText.contains("Practice") && bilingualSlideText.contains("Context"), "bilingual slide imports original pages with intact CJK and Latin ToUnicode maps")
        let restoreRequests = FeatureNetwork.count
        let restored = DocumentTranslationController(settings: settings, directory: controller.directory, resources: resources)
        try check(restored.jobs.count == controller.jobs.count && FeatureNetwork.count == restoreRequests && restoreRequests >= requestsBeforeRestore, "restart restores all durable document jobs without a provider request")
        FeatureNetwork.reset { try envelope($0, delay: 0.3) }
        restored.start(source: fixture.appendingPathComponent("lesson.txt"), sourceLanguage: "en", targetLanguage: "zh-Hans", mode: .translated, engine: .native)
        try await wait { FeatureNetwork.count > 0 }; restored.cancel()
        try await Task.sleep(nanoseconds: 400_000_000)
        try check(restored.selectedJob?.status == .cancelled && restored.selectedJob?.completedCount == 0, "cancellation rejects delayed cloud responses")
        FeatureNetwork.reset { try envelope($0) }; restored.retry(); try await wait { !restored.isRunning }
        try check(restored.selectedJob?.status == .completed, "explicit retry resumes durable cancelled source")
        FeatureNetwork.reset { try envelope($0, delay: 0.3) }
        restored.start(source: fixture.appendingPathComponent("lesson.txt"), sourceLanguage: "en", targetLanguage: "zh-Hans", mode: .translated, engine: .native)
        try await wait { FeatureNetwork.count > 0 }; restored.cancel()
        FeatureNetwork.reset { try envelope($0) }; restored.retry()
        try await wait { !restored.isRunning }
        try check(restored.selectedJob?.status == .completed && restored.outputURL != nil, "immediate cancel and retry waits for the retiring task before publishing output")
        var number = 0
        FeatureNetwork.reset { request in
            number += 1
            if number == 2 { return FeatureNetwork.Reply(status: 401, data: Data("{\"error\":{\"code\":\"invalid_api_key\"}}".utf8)) }
            return try envelope(request)
        }
        restored.start(source: fixture.appendingPathComponent("complex.pdf"), sourceLanguage: "en", targetLanguage: "zh-Hans", mode: .translated, engine: .native)
        try await wait { !restored.isRunning }
        let partial = restored.selectedJob!
        try check(partial.status == .partial && partial.completedCount == 8 && restored.outputURL != nil, "partial provider failure retains translated regions and creates explicitly partial readable output")
        var resumedIDs: [String] = []
        FeatureNetwork.reset { request in resumedIDs += try input(request).compactMap { $0["id"] }; return try envelope(request) }
        restored.retry(); try await wait { !restored.isRunning }
        let completedIDs = Set(partial.regions.filter { $0.translation != nil }.map(\.id))
        try check(restored.selectedJob?.status == .completed && Set(resumedIDs).isDisjoint(with: completedIDs) && resumedIDs.count == 7, "partial retry dispatches only seven unfinished regions and retains prior results")
        let longNote = output.appendingPathComponent("retry-source.ulnote")
        try FileManager.default.copyItem(at: fixture.appendingPathComponent("lesson.ulnote"), to: longNote)
        var noteSource = try JSONSerialization.jsonObject(with: Data(contentsOf: longNote.appendingPathComponent("note.json"))) as! [String: Any]
        let paragraph = (noteSource["blocks"] as! [[String: Any]]).first { $0["kind"] as? String == "paragraph" }!
        noteSource["blocks"] = (0..<12).map { index -> [String: Any] in var row = paragraph; row["id"] = UUID().uuidString; row["text"] = "Learning paragraph \(index): practice improves retention."; return row }
        try JSONSerialization.data(withJSONObject: noteSource).write(to: longNote.appendingPathComponent("note.json"), options: .atomic)
        number = 0
        FeatureNetwork.reset { request in number += 1; if number == 2 { return FeatureNetwork.Reply(status: 401, data: Data("{}".utf8)) }; return try envelope(request) }
        restored.start(source: longNote, sourceLanguage: "en", targetLanguage: "zh-Hans", mode: .translated, engine: .native)
        try await wait { !restored.isRunning }
        try check(restored.selectedJob?.status == .partial && restored.selectedJob?.completedCount == 8, "editable note partial output is published after eight of twelve blocks")
        let package = restored.companionURL!
        let firstNoteBytes = try Data(contentsOf: package.appendingPathComponent("note.json"))
        let firstNote = try JSONSerialization.jsonObject(with: firstNoteBytes) as! [String: Any]
        FeatureNetwork.reset { try envelope($0) }; restored.retry(); try await wait { !restored.isRunning }
        let finalNoteBytes = try Data(contentsOf: package.appendingPathComponent("note.json"))
        let finalNote = try JSONSerialization.jsonObject(with: finalNoteBytes) as! [String: Any]
        let revisionFiles = try FileManager.default.contentsOfDirectory(at: package.appendingPathComponent("revisions"), includingPropertiesForKeys: nil)
        let expectedNames = Set(["1-" + documentHash(firstNoteBytes) + ".json", "2-" + documentHash(finalNoteBytes) + ".json"])
        try check(restored.selectedJob?.status == .completed && firstNote["id"] as? String == finalNote["id"] as? String && finalNote["revision"] as? Int == 2 && Set(revisionFiles.map(\.lastPathComponent)) == expectedNames, "note retry keeps identity and publishes exactly one immutable snapshot for each increasing revision")
        let publishedFiles = try FileManager.default.contentsOfDirectory(at: package.deletingLastPathComponent(), includingPropertiesForKeys: nil)
        try check(FileManager.default.fileExists(atPath: package.appendingPathComponent("assets/scan.png").path) && !publishedFiles.contains { $0.lastPathComponent.hasPrefix("note-") }, "atomic note replacement retains assets and leaves no abandoned staging package")
        let exitSaved = await restored.prepareForExit()
        try check(exitSaved, "document exit awaits pending work and checkpoints actual disk records")
        var historyWrites = 0
        let readOnly = DocumentTranslationController(settings: settings, directory: controller.directory, resources: resources, saveData: { _, _ in historyWrites += 1; throw CocoaError(.fileWriteNoPermission) })
        let historyExit = await readOnly.prepareForExit()
        try check(historyExit && historyWrites == 0, "unchanged read-only document history exits without rewriting saved jobs")
        let failedSave = DocumentTranslationController(settings: settings, directory: output.appendingPathComponent("failed-save"), resources: resources, saveData: { _, _ in throw CocoaError(.fileWriteNoPermission) })
        failedSave.start(source: fixture.appendingPathComponent("lesson.txt"), sourceLanguage: "en", targetLanguage: "zh-Hans", mode: .translated, engine: .native)
        let failedExit = await failedSave.prepareForExit()
        try check(!failedExit && failedSave.selectedJob?.title == "lesson", "unsaved document task remains visible and blocks exit until disk save succeeds")
        for name in ["encrypted.pdf", "corrupt.pptx", "encrypted.pptx"] {
            FeatureNetwork.reset { _ in throw URLError(.unsupportedURL) }
            restored.start(source: fixture.appendingPathComponent(name), sourceLanguage: "en", targetLanguage: "zh-Hans", mode: .translated, engine: .native)
            try await wait { !restored.isRunning }
            try check(restored.selectedJob?.status == .failed && FeatureNetwork.count == 0 && restored.outputURL == nil, "\(name) fails before cloud dispatch without a fake output")
        }
        let invalid = output.appendingPathComponent("broken.pdf"); try Data("not a PDF".utf8).write(to: invalid)
        FeatureNetwork.reset { _ in throw URLError(.unsupportedURL) }; restored.start(source: invalid, sourceLanguage: "en", targetLanguage: "zh-Hans", mode: .translated, engine: .native)
        try await wait { !restored.isRunning }
        try check(restored.selectedJob?.status == .failed && FeatureNetwork.count == 0 && restored.outputURL == nil, "corrupt input fails visibly without cloud traffic or fake PDF result")
        let report: [String: Any] = ["passed": true, "checks": checks, "realProviderRequests": 0, "realCredentialReads": 0, "evidenceDirectory": output.path]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("document-translation-checks.json"), options: .atomic)
        print("Passed \(checks.count) document translation contract checks")
    }
}
