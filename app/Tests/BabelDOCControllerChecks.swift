import Foundation
import PDFKit
import CoreText
import AppKit

@main @MainActor enum BabelDOCControllerChecks {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), output = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let source = output.appendingPathComponent("input.pdf")
        var box = CGRect(x: 0, y: 0, width: 300, height: 400)
        let context = CGContext(source as CFURL, mediaBox: &box, nil)!
        context.beginPDFPage(nil); context.textPosition = CGPoint(x: 20, y: 350)
        CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Document controller fixture", attributes: [.font: NSFont.systemFont(ofSize: 18)])), context)
        context.endPDFPage(); context.closePDF()
        let resources = ConversionResources(directory: root.appendingPathComponent("app/build/conversion"))
        let suite = "ulecture.babeldoc-controller." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = FeatureCredentials()
        let network = URLSessionConfiguration.ephemeral; network.protocolClasses = [FeatureNetwork.self]
        let session = URLSession(configuration: network); defer { session.invalidateAndCancel() }
        FeatureNetwork.reset { _ in throw URLError(.unsupportedURL) }
        let settings = CloudServiceSettings(initialConfiguration: CloudConfiguration(provider: .deepSeek), credentials: credentials, session: session, defaults: defaults, scope: "documentTranslation")
        try settings.saveCredential("fixture-document-key-never-persist")
        var checks = [String](), calls = 0
        func check(_ value: @autoclosure () -> Bool, _ label: String) throws {
            guard value() else { throw LibraryCheckFailure(description: label) }; checks.append(label)
        }
        func wait(_ predicate: () -> Bool) async throws {
            let deadline = Date().addingTimeInterval(20)
            while !predicate() { guard Date() < deadline else { throw URLError(.timedOut) }; try await Task.sleep(nanoseconds: 10_000_000) }
        }
        let runner: BabelDOCTranslate = { pdf, directory, job, authorization, progress in
            calls += 1
            try check(pdf.lastPathComponent == "normalized.pdf" && PDFDocument(url: pdf)?.pageCount == 1, "BabelDOC receives the locally validated normalized PDF")
            try check(job.effectiveEngine == .babelDOC && authorization.dispatch.configuration.credentialScope == "documentTranslation" && authorization.dispatch.configuration.provider == .deepSeek, "BabelDOC authorization freezes the document service scope and provider")
            try progress(0.42, "translating")
            let checkpointData = try Data(contentsOf: directory.appendingPathComponent("job.json"))
            let checkpoint = try JSONDecoder().decode(DocumentTranslationJob.self, from: checkpointData)
            try check(checkpoint.engineProgress == 0.42 && checkpoint.engineDispatches?.last?.id == authorization.dispatch.id, "Progress and dispatch metadata are checkpointed before worker completion")
            try check(!String(decoding: checkpointData, as: UTF8.self).contains("fixture-document-key"), "BabelDOC checkpoints never contain the key")
            let translated = directory.appendingPathComponent("translation.pdf")
            try FileManager.default.copyItem(at: pdf, to: translated)
            return BabelDOCResult(outputURL: translated, pageCount: 1, inputTokens: 7, outputTokens: 9, engineVersion: "fixture-engine")
        }
        let controller = DocumentTranslationController(settings: settings, directory: output.appendingPathComponent("jobs"), resources: resources, babelDOCTranslate: runner)
        controller.start(source: source, sourceLanguage: "en", targetLanguage: "zh-Hans", mode: .translated)
        try await wait { !controller.isRunning }
        try check(controller.selectedJob?.status == .completed && controller.selectedJob?.effectiveEngine == .babelDOC && calls == 1, "New PDF jobs use the BabelDOC runner by default")
        try check(controller.selectedJob?.engineProgress == 1 && controller.selectedJob?.engineVersion == "fixture-engine" && settings.usage.last?.inputTokens == 7 && controller.selectedJob?.mapping.first?.outputPages == [1], "Completed engine result, source-page mapping, and reported usage persist")
        let exported = try controller.export(to: output.appendingPathComponent("exported.pdf"))
        try check(PDFDocument(url: exported)?.pageCount == 1, "BabelDOC output uses the existing validated PDF export")
        let restored = DocumentTranslationController(settings: settings, directory: controller.directory, resources: resources, babelDOCTranslate: runner)
        try check(restored.selectedJob?.effectiveEngine == .babelDOC && restored.selectedJob?.status == .completed && calls == 1, "Reopening completed BabelDOC history performs no worker dispatch")
        var old = controller.selectedJob!; old.engine = nil; old.engineProgress = nil; old.engineDispatches = nil; old.engineVersion = nil
        let legacy = try JSONDecoder().decode(DocumentTranslationJob.self, from: JSONEncoder().encode(old))
        try check(legacy.effectiveEngine == .native, "Jobs without engine metadata remain native checkpoints")
        let broken = output.appendingPathComponent("broken.pdf"); try Data("not a PDF".utf8).write(to: broken)
        controller.start(source: broken, sourceLanguage: "en", targetLanguage: "zh-Hans", mode: .translated)
        try await wait { !controller.isRunning }
        try check(controller.selectedJob?.status == .failed && calls == 1 && controller.outputURL == nil, "Invalid PDF fails before BabelDOC dispatch without fabricated output")
        var entered = false
        let cancelling = DocumentTranslationController(settings: settings, directory: output.appendingPathComponent("cancel"), resources: resources, babelDOCTranslate: { _, _, _, _, progress in
            entered = true; try progress(0.2, "translating")
            try await Task.sleep(nanoseconds: 10_000_000_000)
            throw DocumentConversionError.invalidOutput
        })
        cancelling.start(source: source, sourceLanguage: "en", targetLanguage: "zh-Hans", mode: .bilingual)
        try await wait { entered }
        cancelling.cancel()
        let saved = await cancelling.prepareForExit()
        try check(saved && cancelling.selectedJob?.status == .cancelled && cancelling.selectedJob?.error == "babelDOCCancelled" && cancelling.outputURL == nil, "Cancellation drains worker work and preserves an honest rerun checkpoint")
        try check(settings.usage.last?.status == "unknown", "Cancelled engine dispatches retain unknown billing instead of disappearing")
        let interrupted = cancelling.selectedJob!
        var active = interrupted; active.status = .translating; active.error = nil
        try JSONEncoder().encode(active).write(to: cancelling.jobDirectory(active.id).appendingPathComponent("job.json"))
        let reopen = DocumentTranslationController(settings: settings, directory: cancelling.directory, resources: resources, babelDOCTranslate: runner)
        try check(reopen.selectedJob?.status == .interrupted && reopen.selectedJob?.error == "babelDOCInterrupted", "Interrupted BabelDOC jobs explain that rerunning may repeat requests")
        // Use translation-only mode for the one-page injected output fixture.
        active.mode = .translated; active.status = .interrupted
        try JSONEncoder().encode(active).write(to: cancelling.jobDirectory(active.id).appendingPathComponent("job.json"))
        let retrying = DocumentTranslationController(settings: settings, directory: cancelling.directory, resources: resources, babelDOCTranslate: runner)
        retrying.retry(); try await wait { !retrying.isRunning }
        try check(retrying.selectedJob?.status == .completed && retrying.selectedJob?.engineDispatches?.count == 2 && calls == 2, "Explicit BabelDOC retry preserves history and adds a new dispatch")
        let failing = DocumentTranslationController(settings: settings, directory: output.appendingPathComponent("failure"), resources: resources, babelDOCTranslate: { _, _, _, _, _ in throw CloudFailure.authentication })
        failing.start(source: source, sourceLanguage: "en", targetLanguage: "zh-Hans", mode: .translated)
        try await wait { !failing.isRunning }
        try check(failing.selectedJob?.error == "authentication" && settings.lastError == .authentication && settings.usage.last?.status == "unknown", "Worker authentication failures update only document settings and retain unknown usage")
        try check(FeatureNetwork.count == 0, "Controller contract tests make no real or mock HTTP requests")
        let report: [String: Any] = ["passed": checks.count, "checks": checks, "scope": "Injected BabelDOC runner, real PDF preparation/export, no real engine/provider request; output fixture is not a translation quality test"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("results.json"))
        print("PASS: \(checks.count) BabelDOC controller checks")
    }
    struct LibraryCheckFailure: Error, CustomStringConvertible { var description: String }
}
