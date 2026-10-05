import Foundation
import PDFKit

struct AssistantOCRProvenance: Codable, Equatable {
    let engine: String
    let language: String
    let confidence: Double
    let bounds: CGRect
    let pageWidth: Double
    let pageHeight: Double
}

struct AssistantPDFPageCoverage: Codable, Identifiable {
    var id: String { documentID + ":" + sourceHash + ":" + String(page) }
    let documentID: String
    let title: String
    let sourceHash: String
    let page: Int
    let nativeCharacters: Int
    let ocrCharacters: Int
    let rejectedRegions: Int
    let minimumConfidence: Double?
    let engine: String
    let language: String
    let missing: Bool
    let warnings: [String]
    var failureCode: String? = nil
}

struct AssistantPDFExtraction {
    struct Page {
        let number: Int
        let nativeText: String
        var recognized: [(text: String, provenance: AssistantOCRProvenance)] = []
    }
    let sourceHash: String
    var pages: [Page]
    var coverage: [AssistantPDFPageCoverage]
    static func acceptedRegions(_ regions: [DocumentRegion]) -> [DocumentRegion] {
        regions.filter { region in
            guard ["ocr", "unprocessedImageText"].contains(region.kind), let confidence = region.confidence else { return false }
            return confidence.isFinite && confidence >= 0.85 && confidence <= 1 && !region.source.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }
}

extension AssistantSources {
    /// Called by the host's detached task. PDF text, OCR and coverage all refer
    /// to the same immutable source file. Only text crosses the provider seam.
    func snapshotWithLocalOCR(options: [AssistantSourceOption], selection: DocumentSelection?, intent: AssistantIntent,
                              resolvedPDFs: [String: URL] = [:], slideNotes: [String: [DocumentSlideNote]] = [:],
                              presentationHashes: [String: String] = [:], additionalExclusions: [String] = [],
                              scopes: [AssistantSourceScope] = [], ocrLanguage: String = "en") async throws -> AssistantSnapshot {
        var extracted: [String: AssistantPDFExtraction] = [:], exclusions = additionalExclusions
        let language = ocrLanguage == "ja" ? "ja" : "en"
        for option in options where option.kind == .pdf {
            try Task.checkCancellation()
            guard let item = try library.item(id: option.documentID), item.deletedAt == nil else { continue }
            do {
                let url = try resolvedPDFs[item.id] ?? documentURL(item)
                guard url.pathExtension.lowercased() == "pdf" else { throw DocumentFailure.message("conversionRequired") }
                let store = PDFAnnotationStore(documentID: item.id, sourceURL: url, sidecarURL: try metadataURL(item))
                let loaded = try store.load()
                let hash = loaded.annotations.sourceHash, fixedURL = try store.snapshotURL(hash)
                guard let pdf = PDFDocument(url: fixedURL) else { throw DocumentFailure.invalidFormat }
                var pages: [AssistantPDFExtraction.Page] = []
                for index in 0..<pdf.pageCount {
                    try Task.checkCancellation()
                    pages.append(.init(number: index + 1, nativeText: pdf.page(at: index)?.string ?? ""))
                }
                let directory = FileManager.default.temporaryDirectory.appendingPathComponent("ulecture-ai-ocr-" + UUID().uuidString)
                defer { try? FileManager.default.removeItem(at: directory) }
                var prepared: PreparedDocument?, failure: String?
                do {
                    prepared = try await DocumentPreparation.prepare(source: fixedURL, directory: directory, sourceLanguage: language, resources: conversionResources)
                    guard prepared?.sourceHash == hash, prepared?.pages.count == pdf.pageCount else { throw DocumentFailure.conflict }
                } catch {
                    if error is CancellationError || Task.isCancelled { throw CancellationError() }
                    prepared = nil; failure = error.localizedDescription
                }
                try Task.checkCancellation()
                let engine = DocumentProcessingVersion.current.ocr, recognitionLanguage = language == "ja" ? "ja-JP" : "en-US"
                var coverage: [AssistantPDFPageCoverage] = []
                for index in pages.indices {
                    try Task.checkCancellation()
                    let number = pages[index].number
                    let regions = prepared?.regions.filter { $0.page == number && $0.confidence != nil } ?? []
                    let layout = prepared?.pages.first { $0.number == number }
                    // Background removal is needed for translated rendering,
                    // not for plain-text evidence. High-confidence text on a
                    // complex image is usable; its visual meaning is excluded.
                    let accepted = AssistantPDFExtraction.acceptedRegions(regions)
                    if let layout {
                        pages[index].recognized = accepted.map { region in
                            (region.source, AssistantOCRProvenance(engine: engine, language: recognitionLanguage, confidence: region.confidence!, bounds: region.bounds, pageWidth: layout.width, pageHeight: layout.height))
                        }
                    }
                    let nativeCount = pages[index].nativeText.trimmingCharacters(in: .whitespacesAndNewlines).count
                    let ocrCount = pages[index].recognized.reduce(0) { $0 + $1.text.count }
                    var warnings = (layout?.warnings ?? []).filter { $0 != "complexImageTextUntranslated" }
                    if regions.contains(where: { $0.kind == "unprocessedImageText" && ($0.confidence ?? 0) >= 0.85 }) { warnings.append("ocrImageContextNotAnalyzed") }
                    if failure != nil { warnings.append("localOCRFailed"); exclusions.append(item.title + ": page \(number) localOCRFailed") }
                    if nativeCount + ocrCount == 0 { warnings.append("noExtractableText") }
                    coverage.append(AssistantPDFPageCoverage(documentID: item.id, title: item.title, sourceHash: hash, page: number,
                        nativeCharacters: nativeCount, ocrCharacters: ocrCount, rejectedRegions: regions.count - accepted.count,
                        minimumConfidence: accepted.compactMap(\.confidence).min(), engine: engine, language: recognitionLanguage,
                        missing: nativeCount + ocrCount == 0, warnings: Array(Set(warnings)).sorted(), failureCode: failure))
                }
                extracted[item.id] = AssistantPDFExtraction(sourceHash: hash, pages: pages, coverage: coverage)
            } catch {
                if error is CancellationError || Task.isCancelled { throw CancellationError() }
                exclusions.append(option.title + ": " + error.localizedDescription)
            }
        }
        try Task.checkCancellation()
        return try snapshot(options: options, selection: selection, intent: intent, resolvedPDFs: resolvedPDFs, slideNotes: slideNotes,
                            presentationHashes: presentationHashes, additionalExclusions: exclusions, scopes: scopes, pdfExtraction: extracted)
    }
}
