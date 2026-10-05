import AppKit
import PDFKit
import CoreText

@main @MainActor enum PDFReassociationChecks {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var checks: [String] = []
        func require(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw DocumentFailure.message("FAILED: " + label) }; checks.append(label)
        }
        let source = root.appendingPathComponent("Source.pdf")
        try makePDF(source, pages: 2)
        let oldBytes = try Data(contentsOf: source), oldHash = DocumentDisk.hash(oldBytes)
        let model = PDFEditorModel(documentID: UUID().uuidString, sourceURL: source, sidecarURL: root.appendingPathComponent("annotations"), page: 2)
        guard await model.load() else { throw DocumentFailure.invalidFormat }
        let original = StoredPDFAnnotation(kind: .rectangle, page: 2, bounds: CGRect(x: 40, y: 50, width: 100, height: 60))
        model.add([original]); guard await model.flush() else { throw DocumentFailure.conflict }
        let oldArchive = model.archive!
        try makePDF(source, pages: 1)
        let newHash = try DocumentDisk.hash(source)
        guard await model.load() else { throw DocumentFailure.invalidFormat }
        try require(model.archive?.annotations.isEmpty == true && model.historicalHashes.contains(oldHash), "external page replacement opens a new empty annotation version and lists the preserved old source")
        guard await model.load(version: oldHash, annotationID: original.id) else { throw DocumentFailure.invalidFormat }
        await model.reassociateSelected(to: 1)
        guard await model.flush() else { throw DocumentFailure.conflict }
        try require(model.archive?.sourceHash == newHash && model.archive?.annotations.count == 1 && model.archive?.annotations.first?.page == 1 && model.archive?.annotations.first?.id != original.id, "editor reassociation explicitly copies selected historical annotation to the selected current page")
        try require(try model.store.load(version: oldHash).annotations == oldArchive, "successful reassociation never edits the old annotation version")

        guard await model.load(version: oldHash, annotationID: original.id) else { throw DocumentFailure.invalidFormat }
        let kept = model.archive!
        try FileManager.default.removeItem(at: source)
        await model.reassociateSelected(to: 1)
        try require(model.archive == kept && model.error != nil && model.state == "saveFailed", "missing current source rejects reassociation without appending a duplicate to the old archive")
        try require(try model.store.load(version: oldHash).annotations == kept, "failed reassociation keeps historical bytes and annotation revision unchanged")

        let fallback = try PreservedPDFReadingSource.resolve(documentID: model.store.documentID, originalURL: source, sidecarURL: model.store.sidecarURL, sourceHash: oldHash)
        let reader = PDFEditorModel(documentID: model.store.documentID, sourceURL: fallback.sourceURL, sidecarURL: fallback.sidecarURL, page: 2)
        guard await reader.load(version: fallback.sourceHash) else { throw DocumentFailure.invalidFormat }
        try require(reader.pdf?.pageCount == 2 && reader.archive?.sourceHash == oldHash && reader.currentHash.isEmpty, "the production reading fallback opens the fixed PDF page version after its current source is missing")
        let missingSlides = root.appendingPathComponent("Missing.pptx")
        let slideFallback = try PreservedPDFReadingSource.resolve(documentID: model.store.documentID, originalURL: missingSlides, sidecarURL: model.store.sidecarURL, sourceHash: oldHash)
        let slideReader = PDFEditorModel(documentID: model.store.documentID, sourceURL: slideFallback.sourceURL, sidecarURL: slideFallback.sidecarURL, page: 2)
        guard await slideReader.load(version: slideFallback.sourceHash) else { throw DocumentFailure.invalidFormat }
        try require(slideReader.pdf?.pageCount == 2 && slideReader.archive?.sourceHash == oldHash, "missing PPT/PPTX original can open its pinned converted PDF without rerunning conversion")
        do {
            _ = try PreservedPDFReadingSource.resolve(documentID: model.store.documentID, originalURL: source, sidecarURL: model.store.sidecarURL, sourceHash: String(repeating: "0", count: 64))
            throw DocumentFailure.message("FAILED: missing pinned source was substituted")
        } catch let error as DocumentFailure { throw error }
        catch { checks.append("missing pinned snapshot reports failure instead of substituting another version") }

        try Data("damaged PDF".utf8).write(to: source)
        await model.reassociateSelected(to: 1)
        try require(model.archive == kept && model.error != nil, "damaged current source also preserves the selected old annotation")

        try oldBytes.write(to: source)
        guard await reader.load() else { throw DocumentFailure.invalidFormat }
        try require(reader.currentHash == oldHash && reader.archive?.sourceHash == oldHash, "restoring the current PDF permits an explicit return from the preserved version")
        let stale = try model.store.load().annotations
        try makePDF(source, pages: 3)
        guard await reader.load(version: oldHash) else { throw DocumentFailure.invalidFormat }
        try makePDF(source, pages: 4)
        await reader.checkExternalChange()
        try require(reader.archive?.sourceHash == oldHash && reader.pdf?.pageCount == 2 && reader.currentHash != oldHash, "application reactivation preserves an explicitly pinned PDF version when the external source changes")
        var candidate = stale
        do { try model.store.reassociate(original, to: 1, in: &candidate); throw DocumentFailure.message("FAILED: stale reassociation unexpectedly succeeded") }
        catch DocumentFailure.conflict { checks.append("source replacement between loading and reassociation is rejected by the store") }
        try require(candidate == stale, "rejected stale reassociation makes no in-memory or disk change")
        let result: [String: Any] = ["suite": "PDFReassociationChecks", "passed": checks.count, "checks": checks, "scope": "Real PDF files and production editor model; no visible window, capture, playback, or cloud requests"]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("results.json")); print(String(decoding: data, as: UTF8.self))
    }
    static func makePDF(_ url: URL, pages: Int) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw DocumentFailure.invalidFormat }
        for index in 0..<pages {
            context.beginPDFPage(nil)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Source page \(index + 1) of \(pages)", attributes: [.font: NSFont.systemFont(ofSize: 18)]))
            context.textPosition = CGPoint(x: 40, y: 720); CTLineDraw(line, context); context.endPDFPage()
        }
        context.closePDF()
    }
}
