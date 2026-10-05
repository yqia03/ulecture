import Foundation
import AppKit
import PDFKit
import CoreText

private final class OCRCheckCredentials: CloudCredentialStore {
    var reads = 0
    func save(_ value: String, reference: String) throws {}
    func read(reference: String) throws -> String? { reads += 1; return "local-fixture-never-a-real-key" }
    func remove(reference: String) throws {}
}
private final class OCRCheckNetwork: URLProtocol {
    static var bodies: [String] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open(); defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable { let count = stream.read(&buffer, maxLength: buffer.count); if count <= 0 { break }; data.append(contentsOf: buffer.prefix(count)) }
        }
        Self.bodies.append(String(decoding: data, as: UTF8.self))
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "text/event-stream"])!, cacheStoragePolicy: .notAllowed)
        let events = "data: {\"type\":\"response.output_text.delta\",\"delta\":\"Text from the locally recognized page [S1]\"}\n\ndata: {\"type\":\"response.completed\",\"response\":{\"status\":\"completed\",\"usage\":{\"input_tokens\":10,\"output_tokens\":10}}}\n\n"
        client?.urlProtocol(self, didLoad: Data(events.utf8)); client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@main struct AssistantOCRChecks {
    @MainActor static func main() async throws {
        let out = URL(fileURLWithPath: CommandLine.arguments[1]), resources = ConversionResources(directory: URL(fileURLWithPath: CommandLine.arguments[2]))
        let fm = FileManager.default
        try fm.createDirectory(at: out, withIntermediateDirectories: true)
        var checks: [String] = []
        func require(_ value: Bool, _ label: String) throws { if !value { throw DocumentFailure.message(label) }; checks.append(label) }
        func bitmap() -> CGImage {
            let context = CGContext(data: nil, width: 1200, height: 1400, bitsPerComponent: 8, bytesPerRow: 4800, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
            context.setFillColor(NSColor.white.cgColor); context.fill(CGRect(x: 0, y: 0, width: 1200, height: 1400))
            for (index, text) in ["SCANNED CLASSROOM EVIDENCE", "Retrieval practice improves memory.", "Review the original page before relying on OCR."].enumerated() {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: 34), .foregroundColor: NSColor.black]))
                context.textPosition = CGPoint(x: 60, y: 1120 - index * 100); CTLineDraw(line, context)
            }
            return context.makeImage()!
        }
        let image = bitmap(), scanURL = out.appendingPathComponent("Bitmap evidence.pdf")
        var box = CGRect(x: 0, y: 0, width: 600, height: 700)
        let writer = CGContext(scanURL as CFURL, mediaBox: &box, nil)!
        for page in 1...3 {
            writer.beginPDFPage(nil)
            if page != 3 { writer.draw(image, in: box) }
            if page == 2 {
                let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Native page header", attributes: [.font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.black]))
                writer.textPosition = CGPoint(x: 30, y: 665); CTLineDraw(line, writer)
            }
            writer.endPDFPage()
        }
        writer.closePDF()
        let originalHash = try DocumentDisk.hash(scanURL), inspected = PDFDocument(url: scanURL)!
        try require(inspected.pageCount == 3 && (inspected.page(at: 0)?.string ?? "").isEmpty && inspected.page(at: 1)?.string?.contains("Native page header") == true && (inspected.page(at: 2)?.string ?? "").isEmpty, "real PDF has bitmap-only page, mixed native header plus bitmap page, and blank page")
        let library = try LibraryStore(rootURL: out.appendingPathComponent("catalog")), catalog = WorkspaceCatalog(library: library)
        let course = try catalog.createCourse(title: "Course"), document = try catalog.importDocument(from: scanURL, parentID: course.id)
        let suite = "local.ulecture.ocr-check." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = OCRCheckCredentials(), configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OCRCheckNetwork.self]
        let settings = CloudServiceSettings(initialConfiguration: CloudConfiguration(provider: .openAI), credentials: credentials, session: URLSession(configuration: configuration), defaults: defaults)
        try settings.saveCredential("local-fixture-never-a-real-key")
        let controller = AIAssistantController(library: library, catalog: catalog, settings: settings, conversionResources: resources, flushEdits: { true })
        await controller.selectContext(itemID: document.id)
        try require(controller.ocrLanguage == "en" && OCRCheckNetwork.bodies.isEmpty && credentials.reads == 0, "opening OCR source controls defaults to English and makes no OCR/provider/credential request")
        await controller.ask("Use the scanned evidence", intent: .summary)
        guard let turn = controller.turns.last, let snapshot = controller.snapshots[turn.snapshotID] else { throw DocumentFailure.message("Missing OCR snapshot: " + (controller.error ?? "unknown")) }
        try require(turn.runs.last?.state == "completed", "actual controller extracts local OCR and completes a real provider-adapter stream through local URLProtocol")
        let ocrSources = snapshot.sources.filter { $0.ocr != nil }
        try require(ocrSources.contains { $0.page == 1 && $0.text.contains("Retrieval practice") } && ocrSources.contains { $0.page == 2 && $0.text.contains("Retrieval practice") }, "Vision recognizes actual bitmap text on both scanned-only and mixed native/scanned pages")
        try require(ocrSources.allSatisfy { $0.sourceHash == originalHash && $0.ocr!.engine == "Vision-text-revision3" && $0.ocr!.language == "en-US" && $0.ocr!.confidence >= 0.85 && $0.ocr!.bounds.width > 0 && $0.ocr!.pageWidth == 600 }, "OCR citations retain original PDF SHA, page, engine revision, language, confidence and page-coordinate bounds")
        let coverage = snapshot.pdfCoverage ?? []
        let low = DocumentRegion(id: "low-confidence-fixture", page: 1, objectIDs: [], source: "Unreliable reading must be excluded", bounds: CGRect(x: 1, y: 1, width: 50, height: 12), fontSize: 12, color: [0, 0, 0, 1], kind: "unprocessedImageText", confidence: 0.4)
        var high = low; high.id = "complex-background-fixture"; high.confidence = 0.97
        var invalid = low; invalid.id = "invalid-confidence-fixture"; invalid.confidence = Double.nan
        try require(AssistantPDFExtraction.acceptedRegions([low, high, invalid]).map(\.id) == [high.id], "OCR-to-AI admission excludes low/nonfinite confidence while allowing reliable text on a complex background without claiming image understanding")
        try require(coverage.count == 3 && coverage[0].nativeCharacters == 0 && coverage[0].ocrCharacters > 0 && coverage[1].nativeCharacters > 0 && coverage[1].ocrCharacters > 0 && coverage[2].missing && coverage[2].ocrCharacters == 0 && snapshot.exclusions.contains { $0.contains("page 3 noExtractableText") }, "every page records exact native/OCR coverage and the blank page remains explicitly missing")
        try require(snapshot.sources.filter { $0.text.contains("Native page header") }.count == 1, "native header and OCR overlap are deduplicated")
        try require(OCRCheckNetwork.bodies.count == 1 && OCRCheckNetwork.bodies[0].contains("Retrieval practice") && OCRCheckNetwork.bodies[0].contains("Local OCR") && !OCRCheckNetwork.bodies[0].contains("image_url") && !OCRCheckNetwork.bodies[0].contains("data:image"), "provider receives extracted text and OCR provenance without PDF/page image payload")
        try require(try DocumentDisk.hash(scanURL) == originalHash && DocumentDisk.hash(catalog.documentURL(id: document.id)) == originalHash, "OCR extraction preserves both imported and original source PDF bytes")
        controller.setOCRLanguage("ja")
        let requestsBeforeRetry = OCRCheckNetwork.bodies.count
        await controller.retry(turn.id)
        try require(controller.snapshots[turn.snapshotID]?.hash == snapshot.hash && controller.snapshots[turn.snapshotID]?.sources.compactMap(\.ocr).allSatisfy { $0.language == "en-US" } == true && OCRCheckNetwork.bodies.count == requestsBeforeRetry + 1, "retry preserves fixed English OCR evidence after the user changes future OCR language to Japanese")
        let reopened = AIAssistantController(library: library, catalog: catalog, settings: settings, conversionResources: resources, flushEdits: { true })
        let readsBeforeReopen = credentials.reads, requestsBeforeReopen = OCRCheckNetwork.bodies.count
        await reopened.selectContext(itemID: document.id)
        try require(reopened.ocrLanguage == "ja" && reopened.snapshots[turn.snapshotID]?.pdfCoverage?.count == 3 && credentials.reads == readsBeforeReopen && OCRCheckNetwork.bodies.count == requestsBeforeReopen, "reopening restores selected OCR language and fixed per-page provenance without reading credentials or replaying OCR/requests")
        let unavailable = AssistantSources(library: library, catalog: catalog, conversionResources: ConversionResources(directory: out.appendingPathComponent("missing-resources")))
        let option = AssistantSourceOption(documentID: document.id, title: document.title, kind: .pdf)
        let failedOCR = try await unavailable.snapshotWithLocalOCR(options: [option], selection: nil, intent: .question)
        try require(failedOCR.sources.allSatisfy { $0.ocr == nil } && failedOCR.sources.contains { $0.text.contains("Native page header") } && failedOCR.pdfCoverage?.count == 3 && failedOCR.pdfCoverage?.allSatisfy { $0.warnings.contains("localOCRFailed") } == true && failedOCR.pdfCoverage?.filter(\.missing).count == 2, "missing local extraction resources retain native text and mark scanned pages unavailable without stale OCR reuse")
        var oldObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(snapshot)) as! [String: Any]
        oldObject.removeValue(forKey: "pdfCoverage")
        oldObject["sources"] = (oldObject["sources"] as! [[String: Any]]).map { source -> [String: Any] in var value = source; value.removeValue(forKey: "ocr"); return value }
        let oldSnapshot = try JSONDecoder().decode(AssistantSnapshot.self, from: JSONSerialization.data(withJSONObject: oldObject))
        try require(oldSnapshot.pdfCoverage == nil && oldSnapshot.sources.allSatisfy { $0.ocr == nil } && oldSnapshot.sources.map(\.text) == snapshot.sources.map(\.text), "older saved source records decode without invented OCR provenance or coverage")
        // A cancelled extraction must not reach a provider or publish a new turn.
        let cancellation = Task { await reopened.ask("Cancel local extraction", intent: .summary) }
        for _ in 0..<100 where !reopened.busy { await Task.yield() }
        reopened.cancel(); await cancellation.value
        try require(reopened.turns.count == controller.turns.count && OCRCheckNetwork.bodies.count == requestsBeforeReopen && !reopened.busy, "cancelled source extraction cannot publish a late turn or send a provider request")
        let blankURL = out.appendingPathComponent("Blank.pdf"), blank = PDFDocument()
        blank.insert(inspected.page(at: 2)!, at: 0); try require(blank.write(to: blankURL), "blank-page source fixture writes a genuine PDF")
        let blankItem = try catalog.importDocument(from: blankURL, parentID: course.id)
        await reopened.selectContext(itemID: blankItem.id); await reopened.ask("Summarize the empty page", intent: .summary)
        try require(reopened.turns.last?.runs.last?.state == "failed" && reopened.turns.last.flatMap { reopened.snapshots[$0.snapshotID] }?.pdfCoverage?.first?.missing == true && OCRCheckNetwork.bodies.count == requestsBeforeReopen, "no-text selected PDF saves visible missing-page coverage and fails without a cloud request")
        await reopened.retry(reopened.turns.last!.id)
        try require(OCRCheckNetwork.bodies.count == requestsBeforeReopen, "retry of a fixed empty-page snapshot cannot invent usable evidence or dispatch a cloud request")
        let archive = out.appendingPathComponent("ocr.ulbackup")
        try WorkspaceArchive(catalog: catalog).backup(itemID: document.id, to: archive)
        let restoredLibrary = try LibraryStore(rootURL: out.appendingPathComponent("restored-catalog")), restoredCatalog = WorkspaceCatalog(library: restoredLibrary)
        let destination = out.appendingPathComponent("restored-projects"); try fm.createDirectory(at: destination, withIntermediateDirectories: true)
        _ = try WorkspaceArchive(catalog: restoredCatalog).restore(from: archive, into: destination)
        let restored = try restoredLibrary.records(collection: "assistant-snapshots", as: AssistantSnapshot.self).first!
        let restoredSource = restored.sources.first!
        let restoredURL = try restoredCatalog.documentURL(id: restoredSource.documentID)
        let version = try PDFAnnotationStore(documentID: restoredSource.documentID, sourceURL: restoredURL, sidecarURL: restoredCatalog.metadataDirectory(documentID: restoredSource.documentID)).snapshotURL(originalHash)
        try require(restored.sources.map(\.ocr) == snapshot.sources.map(\.ocr) && restored.sources.map(\.text) == snapshot.sources.map(\.text) && restored.pdfCoverage?.count == 3 && restored.pdfCoverage?.allSatisfy { $0.documentID == restoredSource.documentID && $0.sourceHash == originalHash } == true && DocumentDisk.hash(version) == originalHash, "real backup/restore remaps document IDs while preserving exact OCR text, bounds, confidence, page coverage and immutable PDF hash")
        let restoredConversation = try restoredLibrary.records(collection: "assistant-conversations", as: AssistantConversation.self).first!
        try require(restoredConversation.ocrLanguage == "ja", "backup/restore preserves the explicit future OCR language separately from historical evidence")
        let report: [String: Any] = ["checks": checks, "requests": OCRCheckNetwork.bodies.count, "sourceHash": originalHash, "ocrSources": ocrSources.count, "pages": coverage.count, "boundary": "real bitmap PDF + PDFium + local Vision revision3 + production assistant + local URLProtocol + real typed archive; zero external requests, no audio/UI, not an OCR accuracy claim"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("assistant-ocr-checks.json"))
        print("PASS: \(checks.count) real local OCR/source/coverage/cancellation/archive checks")
    }
}
