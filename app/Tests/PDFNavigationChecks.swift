import AppKit
import SwiftUI
import PDFKit

@main @MainActor enum PDFNavigationChecks {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { do { try await run(); exit(0) } catch { print("FAIL: \(error.localizedDescription)"); exit(1) } }
        NSApplication.shared.run()
    }
    static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let source = root.appendingPathComponent("Source.pdf"), id = UUID().uuidString
        let document = PDFDocument()
        for _ in 0..<3 {
            let page = PDFPage(); page.setBounds(CGRect(x: 0, y: 0, width: 612, height: 792), for: .mediaBox); document.insert(page, at: document.pageCount)
        }
        guard document.write(to: source) else { throw DocumentFailure.invalidFormat }
        let store = PDFAnnotationStore(documentID: id, sourceURL: source, sidecarURL: root.appendingPathComponent("sidecar"))
        var archive = try store.load().annotations
        archive.annotations = [StoredPDFAnnotation(kind: .rectangle, page: 2, bounds: CGRect(x: 30, y: 400, width: 120, height: 70))]
        archive = try store.save(archive)
        try FileManager.default.removeItem(at: source)
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 980, height: 840), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: AnnotatedPDFEditor(documentID: id, sourceURL: source, sidecarURL: store.sidecarURL, initialPage: 2,
            navigationRequest: PDFNavigationRequest(documentID: id, sourceHash: archive.sourceHash, page: 2)))
        window.contentView = host; host.frame = CGRect(x: 0, y: 0, width: 980, height: 840)
        func readers(_ view: NSView) -> [AnnotationPDFView] { (view as? AnnotationPDFView).map { [$0] } ?? view.subviews.flatMap(readers) }
        func settle() async { try? await Task.sleep(nanoseconds: 250_000_000); host.layoutSubtreeIfNeeded() }
        await settle()
        guard let reader = readers(host).first, let editor = reader.editor, let pdf = reader.document else { throw DocumentFailure.invalidFormat }
        var checks: [String] = []
        func require(_ condition: @autoclosure () -> Bool, _ label: String) throws { guard condition() else { throw DocumentFailure.message(label + " (editor \(editor.page), view \(reader.currentPage.map { pdf.index(for: $0) + 1 } ?? 0))") }; checks.append(label) }
        try require(editor.page == 2 && reader.currentPage === pdf.page(at: 1), "Pinned preserved reference opens page 2 in both the editor and the actual PDFView")
        try require(pdf.page(at: 1)?.annotations.contains { $0.type == "Square" } == true, "The preserved page retains its actual Square annotation")
        window.setContentSize(CGSize(width: 620, height: 840)); await settle()
        try require(editor.page == 2 && reader.currentPage === pdf.page(at: 1), "Fit-width resize preserves the selected referenced page")
        reader.go(to: pdf.page(at: 0)!); await settle()
        try require(editor.page == 1 && reader.currentPage === pdf.page(at: 0), "Native PDF navigation still updates the model outside a programmatic editor update")
        reader.go(to: pdf.page(at: 2)!); await settle()
        try require(editor.page == 3 && reader.currentPage === pdf.page(at: 2), "Subsequent native navigation to another page is not suppressed")
        editor.page = 2; await settle()
        try require(editor.page == 2 && reader.currentPage === pdf.page(at: 1), "An explicit editor page change reaches the PDFView without page-one notification feedback")
        reader.go(to: pdf.page(at: 0)!)
        reader.updateFromEditor { editor.page = 2; reader.go(to: pdf.page(at: 1)!) }
        await settle()
        try require(editor.page == 2 && reader.currentPage === pdf.page(at: 1), "A queued stale native event cannot overwrite a newer programmatic destination")
        window.close()
        try JSONSerialization.data(withJSONObject: ["checks": checks, "scope": "Hidden actual SwiftUI PDF editor + PDFKit notifications; no desktop automation, capture, playback or cloud"], options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("results.json"))
        print("PASS: \(checks.count) actual PDF view/model navigation checks")
    }
}
