import Foundation
import PDFKit

/// Reads only explicitly selected sources. The host flushes editors before
/// performing document parsing and hashing outside MainActor.
final class AssistantSources: @unchecked Sendable {
    let library: LibraryStore
    let catalog: WorkspaceCatalog?
    let conversionResources: ConversionResources
    init(library: LibraryStore, catalog: WorkspaceCatalog?, conversionResources: ConversionResources = ConversionResources()) { self.library = library; self.catalog = catalog; self.conversionResources = conversionResources }
    func documentURL(_ item: WorkspaceItem) throws -> URL {
        if let catalog { return try catalog.documentURL(id: item.id) }
        guard let asset = item.assetID else { throw DocumentFailure.missingResource(item.title) }
        return try library.attachmentURL(assetID: asset)
    }
    func metadataURL(_ item: WorkspaceItem) throws -> URL {
        if let catalog { return try catalog.metadataDirectory(documentID: item.id) }
        let url = library.rootURL.appendingPathComponent("document-data/" + item.id, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true); return url
    }
    func noteURL(_ item: WorkspaceItem) throws -> URL {
        if let catalog, try catalog.locator(id: item.id)?.format == "ulnote" { return try catalog.documentURL(id: item.id) }
        let url = try metadataURL(item).appendingPathComponent("note.ulnote", isDirectory: true)
        if !FileManager.default.fileExists(atPath: url.appendingPathComponent("note.json").path) {
            // Migrate only when the authoritative package does not exist.
            // Existing block notes never read the legacy Markdown cache.
            let store = BlockNoteStore(packageURL: url, noteID: item.id)
            if let old = try library.noteRevision(noteID: item.id) { _ = try store.importMarkdown(Data(old.markdown.utf8), title: item.title) }
            else { _ = try store.create(title: item.title) }
        }
        return url
    }
    func options(itemID: String?, classroomID: String?) throws -> [AssistantSourceOption] {
        guard let id = itemID ?? classroomID, let context = try library.item(id: id) else { return [] }
        let all = try library.items()
        let classroom = classroomID ?? (context.kind == .classroom ? context.id : context.classroomID)
        let linked = try classroom.map { try catalog?.linkedDocumentIDs(sessionID: $0) ?? [] } ?? []
        let eligible = all.filter { value in
            value.id == context.id || value.id == classroom || (context.courseID != nil && value.courseID == context.courseID) || linked.contains(value.id)
        }
        var result: [AssistantSourceOption] = []
        for item in eligible {
            switch item.kind {
            case .classroom: result.append(AssistantSourceOption(documentID: item.id, title: item.title, kind: .transcript))
            case .note:
                let format = try catalog?.locator(id: item.id)?.format
                result.append(AssistantSourceOption(documentID: item.id, title: item.title, kind: ["txt", "md"].contains(format ?? "") ? .text : .note))
            case .pdf:
                let format = try catalog?.locator(id: item.id)?.format ?? "pdf"
                result.append(AssistantSourceOption(documentID: item.id, title: item.title, kind: ["txt", "md"].contains(format) ? .text : .pdf))
                if !["txt", "md"].contains(format) { result.append(AssistantSourceOption(documentID: item.id, title: item.title, kind: .annotation)) }
                if ["ppt", "pptx"].contains(format) { result.append(AssistantSourceOption(documentID: item.id, title: item.title, kind: .speakerNotes)) }
            default: break
            }
        }
        return result.sorted { $0.title == $1.title ? $0.id < $1.id : $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    func details(options: [AssistantSourceOption]) throws -> [String: AssistantSourceDetails] {
        var result: [String: AssistantSourceDetails] = [:]
        for option in options where [.note, .transcript].contains(option.kind) {
            try Task.checkCancellation()
            do {
                guard let item = try library.item(id: option.documentID) else { throw DocumentFailure.message("sourceUnavailable") }
                if option.kind == .transcript {
                    let rows = try library.transcripts(classroomID: item.id)
                    result[option.id] = AssistantSourceDetails(firstMS: rows.map(\.startMS).min(), lastMS: rows.map(\.endMS).max())
                } else {
                    let package: URL
                    if library.isReadOnly {
                        if let catalog, try catalog.locator(id: item.id)?.format == "ulnote" { package = try catalog.documentURL(id: item.id) }
                        else { package = library.rootURL.appendingPathComponent("document-data/" + item.id + "/note.ulnote") }
                    } else { package = try noteURL(item) }
                    let store = BlockNoteStore(packageURL: package, noteID: item.id)
                    let current = try store.loadSnapshot()
                    let files = try FileManager.default.contentsOfDirectory(at: store.packageURL.appendingPathComponent("revisions"), includingPropertiesForKeys: nil)
                    let numbers = Set(files.filter { $0.pathExtension == "json" }.compactMap { Int($0.lastPathComponent.split(separator: "-").first ?? "") }).sorted(by: >)
                    var versions: [AssistantNoteVersion] = []
                    for number in numbers {
                        try Task.checkCancellation()
                        let fixed = try store.revisionSnapshot(number)
                        guard fixed.document.id == current.document.id else { throw DocumentFailure.invalidFormat }
                        versions.append(AssistantNoteVersion(version: number, sourceHash: fixed.sourceHash, savedAt: fixed.document.savedAt))
                    }
                    result[option.id] = AssistantSourceDetails(versions: versions)
                }
            } catch {
                if error is CancellationError { throw error }
                result[option.id] = AssistantSourceDetails(error: error.localizedDescription)
            }
        }
        return result
    }
    func snapshot(options: [AssistantSourceOption], selection: DocumentSelection?, intent: AssistantIntent, resolvedPDFs: [String: URL] = [:], slideNotes: [String: [DocumentSlideNote]] = [:], presentationHashes: [String: String] = [:], additionalExclusions: [String] = [], scopes: [AssistantSourceScope] = [], pdfExtraction: [String: AssistantPDFExtraction] = [:]) throws -> AssistantSnapshot {
        var sources: [AssistantSource] = [], exclusions = additionalExclusions
        var cutoff: Int64?, ended = true, totalCharacters = 0
        func append(document: WorkspaceItem, kind: AssistantSourceKind, version: Int, hash: String, text: String, page: Int? = nil, block: String? = nil, annotation: String? = nil, start: Int64? = nil, end: Int64? = nil, navigationHash: String? = nil, transcriptSnapshot: TranscriptRecord? = nil, ocr: AssistantOCRProvenance? = nil) throws {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
            totalCharacters += text.count
            guard totalCharacters <= 1_000_000 else { throw DocumentFailure.message("selectFewerSources") }
            let characters = Array(text)
            for offset in stride(from: 0, to: characters.count, by: 6000) {
                sources.append(AssistantSource(id: "S\(sources.count + 1)", documentID: document.id, title: document.title, kind: kind, version: version, sourceHash: hash, text: String(characters[offset..<min(offset + 6000, characters.count)]), page: page, blockID: block, annotationID: annotation, startMS: start, endMS: end, startCharacter: offset, navigationHash: navigationHash, transcriptSnapshot: transcriptSnapshot, ocr: ocr))
            }
        }
        for option in options {
            try Task.checkCancellation()
            let scope = scopes.first { $0.id == option.id }
            guard let item = try library.item(id: option.documentID), item.deletedAt == nil else { exclusions.append(option.title + ": sourceUnavailable"); continue }
            do {
                switch option.kind {
                case .transcript:
                    guard let classroom = try library.classroom(id: item.id) else { throw DocumentFailure.missingResource(item.title) }
                    ended = ended && classroom.state == "ended"
                    var rows = try library.transcripts(classroomID: item.id)
                    if let scope {
                        let range = try scope.transcriptRange()
                        rows = rows.filter { (range.start == nil || $0.endMS > range.start!) && (range.end == nil || $0.startMS < range.end!) }
                    }
                    if intent == .latestQuestion { rows = Array(rows.suffix(10)) }
                    if rows.isEmpty { exclusions.append(item.title + ": noConfirmedTranscript") }
                    for row in rows {
                        try Task.checkCancellation()
                        cutoff = max(cutoff ?? 0, row.endMS)
                        try append(document: item, kind: .transcript, version: row.revision, hash: DocumentDisk.hash(try DocumentDisk.json(row)), text: row.text, block: row.id, start: row.startMS, end: row.endMS, transcriptSnapshot: row)
                    }
                case .note:
                    let store = BlockNoteStore(packageURL: try noteURL(item), noteID: item.id)
                    let fixed: (document: BlockNoteDocument, sourceHash: String)
                    if let version = scope?.version {
                        do {
                            fixed = try store.revisionSnapshot(version)
                            guard fixed.sourceHash == scope?.sourceHash else { throw DocumentFailure.message("sourceVersionUnavailable") }
                        } catch { throw DocumentFailure.message("sourceVersionUnavailable") }
                    } else { fixed = try store.loadSnapshot() }
                    let document = fixed.document, hash = fixed.sourceHash
                    for block in document.blocks {
                        try Task.checkCancellation()
                        if block.kind == .image { exclusions.append(item.title + ": imageNotAnalyzed \(block.id)"); continue }
                        try append(document: item, kind: .note, version: document.revision, hash: hash, text: block.plainText, block: block.id)
                    }
                case .text:
                    let url = try documentURL(item)
                    guard (try url.resourceValues(forKeys: [.fileSizeKey])).fileSize ?? 0 <= 20_000_000 else { throw DocumentFailure.message("selectFewerSources") }
                    let bytes = try Data(contentsOf: url)
                    guard let text = String(data: bytes, encoding: .utf8) else { throw DocumentFailure.invalidFormat }
                    try append(document: item, kind: .text, version: 1, hash: DocumentDisk.hash(bytes), text: text)
                case .speakerNotes:
                    guard let notes = slideNotes[item.id], let pdfURL = resolvedPDFs[item.id], let originalHash = presentationHashes[item.id] else { throw DocumentFailure.message("conversionRequired") }
                    guard try DocumentDisk.hash(documentURL(item)) == originalHash else { throw DocumentFailure.conflict }
                    let store = PDFAnnotationStore(documentID: item.id, sourceURL: pdfURL, sidecarURL: try metadataURL(item))
                    let loaded = try store.load()
                    if notes.isEmpty { exclusions.append(item.title + ": noSpeakerNotes") }
                    for note in notes {
                        try Task.checkCancellation()
                        guard (1...loaded.document.pageCount).contains(note.sourcePage) else { throw DocumentFailure.invalidFormat }
                        try append(document: item, kind: .speakerNotes, version: 1, hash: originalHash, text: note.text, page: note.sourcePage, navigationHash: loaded.annotations.sourceHash)
                    }
                case .pdf, .annotation:
                    if option.kind == .pdf, let fixed = pdfExtraction[item.id] {
                        for page in fixed.pages {
                            try Task.checkCancellation()
                            try append(document: item, kind: .pdf, version: 1, hash: fixed.sourceHash, text: page.nativeText, page: page.number)
                            for region in page.recognized {
                                try Task.checkCancellation()
                                try append(document: item, kind: .pdf, version: 1, hash: fixed.sourceHash, text: region.text, page: page.number, ocr: region.provenance)
                            }
                        }
                        for page in fixed.coverage {
                            if page.missing { exclusions.append(item.title + ": page \(page.page) noExtractableText") }
                            if page.rejectedRegions > 0 { exclusions.append(item.title + ": page \(page.page) ocrLowConfidenceExcluded") }
                        }
                        exclusions.append(item.title + ": imagesFormulasDiagramsNotAnalyzed")
                        continue
                    }
                    let url = try resolvedPDFs[item.id] ?? documentURL(item)
                    guard url.pathExtension.lowercased() == "pdf" else { throw DocumentFailure.message("conversionRequired") }
                    let store = PDFAnnotationStore(documentID: item.id, sourceURL: url, sidecarURL: try metadataURL(item))
                    let loaded = try store.load()
                    if option.kind == .pdf {
                        // Read immutable original pages, not annotation text
                        // injected into the editing representation.
                        guard let pdf = PDFDocument(url: try store.snapshotURL(loaded.annotations.sourceHash)) else { throw DocumentFailure.invalidFormat }
                        for index in 0..<pdf.pageCount {
                            try Task.checkCancellation()
                            let text = pdf.page(at: index)?.string ?? ""
                            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { exclusions.append(item.title + ": page \(index + 1) noExtractableText") }
                            else { try append(document: item, kind: .pdf, version: 1, hash: loaded.annotations.sourceHash, text: text, page: index + 1) }
                        }
                        exclusions.append(item.title + ": imagesFormulasDiagramsNotAnalyzed")
                    } else {
                        for annotation in loaded.annotations.annotations {
                            try Task.checkCancellation()
                            let text = [annotation.selectedText, annotation.text].filter { !$0.isEmpty }.joined(separator: "\n")
                            if text.isEmpty { exclusions.append(item.title + ": nonTextAnnotation \(annotation.id)") }
                            else { try append(document: item, kind: .annotation, version: loaded.annotations.revision, hash: loaded.annotations.sourceHash, text: text, page: annotation.page, annotation: annotation.id) }
                        }
                    }
                }
            } catch {
                if ["selectFewerSources", "invalidTranscriptRange", "sourceVersionUnavailable"].contains(error.localizedDescription) || error is CancellationError { throw error }
                exclusions.append(option.title + ": " + error.localizedDescription)
            }
        }
        if let selection {
            let matches = sources.filter { $0.documentID == selection.documentID && (selection.page == nil || $0.page == selection.page) && (selection.blockID == nil || $0.blockID == selection.blockID) }
            guard !selection.text.isEmpty, let first = matches.first,
                  selection.sourceHash == nil || selection.sourceHash == first.sourceHash,
                  selection.revision == nil || first.kind == .pdf || selection.revision == first.version,
                  matches.map(\.text).joined().contains(selection.text) else { throw DocumentFailure.message("selectionChanged") }
            sources.append(AssistantSource(id: "S\(sources.count + 1)", documentID: first.documentID, title: first.title, kind: first.kind, version: first.version, sourceHash: first.sourceHash, text: selection.text, page: first.page, blockID: first.blockID, annotationID: first.annotationID, startMS: first.startMS, endMS: first.endMS, navigationHash: first.navigationHash, transcriptSnapshot: first.transcriptSnapshot, ocr: first.ocr))
        }
        guard sources.reduce(0, { $0 + $1.text.count }) <= 1_000_000 else { throw DocumentFailure.message("selectFewerSources") }
        return AssistantSnapshot(id: UUID().uuidString, capturedAt: Date(), sources: sources, exclusions: exclusions, cutoffMS: cutoff, classroomEnded: ended, requestedScopes: scopes.filter { scope in options.contains { $0.id == scope.id } }, pdfCoverage: options.filter { $0.kind == .pdf }.flatMap { pdfExtraction[$0.documentID]?.coverage ?? [] })
    }
    static func chunks(_ sources: [AssistantSource], limit: Int = 16000) -> [AssistantChunk] {
        var chunks: [AssistantChunk] = [], ids: [String] = []; var size = 0
        for source in sources {
            if !ids.isEmpty && size + source.text.count > limit { chunks.append(AssistantChunk(id: "C\(chunks.count + 1)", sourceIDs: ids)); ids = []; size = 0 }
            ids.append(source.id); size += source.text.count
        }
        if !ids.isEmpty { chunks.append(AssistantChunk(id: "C\(chunks.count + 1)", sourceIDs: ids)) }
        return chunks
    }
    static func prompt(_ sources: [AssistantSource]) -> String {
        sources.map { source in
            let extraction = source.ocr.map { " | Local OCR \($0.engine) \($0.language) confidence \($0.confidence); review recognition, image meaning not analyzed" } ?? ""
            return "[\(source.id)] \(source.title) | \(source.kind.rawValue) | version \(source.version) | page \(source.page.map(String.init) ?? "—") | time \(source.startMS.map(String.init) ?? "—")–\(source.endMS.map(String.init) ?? "—") ms" + extraction + "\n" + source.text
        }.joined(separator: "\n\n")
    }
}
