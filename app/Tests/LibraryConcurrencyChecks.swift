import Foundation
import CoreGraphics
import CoreText

private final class ImportResult {
    let lock = NSLock()
    var result: Result<WorkspaceItem, Error>?
    func finish(_ value: Result<WorkspaceItem, Error>) { lock.lock(); result = value; lock.unlock() }
    func read() -> Result<WorkspaceItem, Error>? { lock.lock(); defer { lock.unlock() }; return result }
}

@main enum LibraryConcurrencyChecks {
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/tmp/uway-library-concurrency-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let library = try LibraryStore(rootURL: directory.appendingPathComponent("library"))
        let course = try library.createItem(kind: .course, title: "Original course")
        let destination = try library.createItem(kind: .course, title: "Destination course")
        let folder = try library.createItem(kind: .folder, title: "Moved during import", parentID: course.id)
        let note = try library.createItem(kind: .note, title: "Concurrent notes", parentID: course.id)
        let pdf = directory.appendingPathComponent("600-pages.pdf")
        try makePDF(pdf)
        let result = ImportResult()
        let began = Date()
        DispatchQueue.global(qos: .utility).async { result.finish(Result { try library.importPDF(from: pdf, parentID: folder.id) }) }
        // The managed copy appears before page extraction. Observe actual public filesystem progress.
        let attachments = library.rootURL.appendingPathComponent("attachments")
        while (try FileManager.default.contentsOfDirectory(atPath: attachments.path)).isEmpty && result.read() == nil && Date().timeIntervalSince(began) < 15 { Thread.sleep(forTimeInterval: 0.002) }
        let saveBegan = Date()
        _ = try library.saveNote(noteID: note.id, markdown: "Durable while 600 PDF pages are being extracted.")
        let saveTime = Date().timeIntervalSince(saveBegan)
        let savedDuringImport = result.read() == nil
        try library.move(id: folder.id, parentID: destination.id)
        while result.read() == nil && Date().timeIntervalSince(began) < 60 { Thread.sleep(forTimeInterval: 0.01) }
        guard let completed = result.read() else { throw LibraryError.message("Import did not finish in 60 seconds") }
        let imported = try completed.get()
        guard savedDuringImport else { throw LibraryError.message("Concurrent note save was blocked until PDF import completed") }
        guard imported.courseID == destination.id else { throw LibraryError.message("PDF import committed stale ownership after destination moved") }
        guard try library.noteRevision(noteID: note.id)?.markdown.hasPrefix("Durable") == true else { throw LibraryError.message("Concurrent note was not durably saved") }
        guard try library.pdfPages(assetID: imported.assetID!).count == 600 else { throw LibraryError.message("Page extraction incomplete") }
        let report: [String:Any] = ["suite":"LibraryConcurrencyChecks", "passed":4, "pdfPages":600, "concurrentNoteSaveSeconds":saveTime, "importSeconds":Date().timeIntervalSince(began), "noteCommittedBeforePDFImport":savedDuringImport, "parentMoveRevalidatedAtCommit":true, "scope":"Real generated PDF, filesystem and SQLite; no audio or network", "directory":directory.path]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted,.sortedKeys])
        try data.write(to: directory.appendingPathComponent("library-concurrency-checks.json"))
        print(String(decoding:data, as:UTF8.self))
    }
    static func makePDF(_ url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: &box, nil) else { throw LibraryError.message("PDF fixture could not be created") }
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Concurrent persistence: preserve every confirmed classroom fact.", attributes: [NSAttributedString.Key(kCTFontAttributeName as String): CTFontCreateWithName("Helvetica" as CFString, 10, nil)]))
        for _ in 0..<600 {
            context.beginPDFPage(nil)
            for row in 0..<65 { context.textPosition = CGPoint(x: 32, y: 760 - row * 11); CTLineDraw(line, context) }
            context.endPDFPage()
        }
        context.closePDF()
    }
}
