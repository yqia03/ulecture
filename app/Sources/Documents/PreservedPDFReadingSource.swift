import Foundation
import PDFKit

/// Resolves only an explicitly pinned, already-preserved reading version. It never imports,
/// converts, recreates, or silently substitutes a missing source document.
struct PreservedPDFReadingSource {
    let sourceURL: URL
    let sidecarURL: URL
    let sourceHash: String
    static func resolve(documentID: String, originalURL: URL?, sidecarURL: URL, sourceHash: String) throws -> Self {
        let original = originalURL ?? sidecarURL.appendingPathComponent(".unavailable-current-source.pdf")
        let store = PDFAnnotationStore(documentID: documentID, sourceURL: original, sidecarURL: sidecarURL)
        let snapshot = try store.snapshotURL(sourceHash)
        guard try DocumentDisk.hash(snapshot) == sourceHash,
              let pdf = PDFDocument(url: snapshot), !pdf.isLocked, pdf.pageCount > 0 else { throw DocumentFailure.invalidFormat }
        return Self(sourceURL: original, sidecarURL: sidecarURL, sourceHash: sourceHash)
    }
}
