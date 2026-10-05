import Foundation

/// A page link always points to a preserved PDF version, including converted slide decks.
struct NotePageReference {
    let documentID: String
    let title: String
    let sourceHash: String
    let pageCount: Int
    static func prepare(documentID: String, title: String, pdfURL: URL, sidecarURL: URL) throws -> NotePageReference {
        let loaded = try PDFAnnotationStore(documentID: documentID, sourceURL: pdfURL, sidecarURL: sidecarURL).load()
        return NotePageReference(documentID: documentID, title: title, sourceHash: loaded.currentHash, pageCount: loaded.document.pageCount)
    }
    func link(page: Int) -> DocumentPageLink? {
        guard (1...pageCount).contains(page) else { return nil }
        return DocumentPageLink(documentID: documentID, page: page, label: title, sourceHash: sourceHash)
    }
}
