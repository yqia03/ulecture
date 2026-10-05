import Foundation
import PDFKit
import AppKit
import CoreText

/// PDFKit's default FreeText painter reflows upright when the page rotates. Draw in page coordinates
/// so the text and its saved rectangle rotate together; PDFKit exports this as a standard /FreeText appearance.
private final class PageSpaceTextAnnotation: PDFAnnotation {
    override func draw(with box: PDFDisplayBox, in context: CGContext) {
        guard let contents else { return }
        context.saveGState(); defer { context.restoreGState() }
        let offset = page?.bounds(for: box).origin ?? .zero
        let rect = bounds.offsetBy(dx: -offset.x, dy: -offset.y).insetBy(dx: 2, dy: 2)
        context.clip(to: rect)
        let value = NSAttributedString(string: contents, attributes: [.font: font ?? NSFont.systemFont(ofSize: 15), .foregroundColor: fontColor ?? NSColor.black])
        let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(value), CFRange(location: 0, length: value.length), CGPath(rect: rect, transform: nil), nil)
        CTFrameDraw(frame, context)
    }
}

enum AnnotationKind: String, Codable, CaseIterable {
    case highlight, underline, strikeOut, ink, freeText, stickyNote, rectangle, ellipse, arrow
    var pdfType: PDFAnnotationSubtype {
        switch self {
        case .highlight: return .highlight
        case .underline: return .underline
        case .strikeOut: return .strikeOut
        case .ink: return .ink
        case .freeText: return .freeText
        case .stickyNote: return .text
        case .rectangle: return .square
        case .ellipse: return .circle
        case .arrow: return .line
        }
    }
}

struct AnnotationColor: Codable, Equatable {
    var red: Double = 0.98
    var green: Double = 0.73
    var blue: Double = 0.12
    var alpha: Double = 1
    init(red: Double = 0.98, green: Double = 0.73, blue: Double = 0.12, alpha: Double = 1) { self.red = red; self.green = green; self.blue = blue; self.alpha = alpha }
    init(_ color: NSColor) {
        let value = color.usingColorSpace(.sRGB) ?? .systemYellow
        red = value.redComponent; green = value.greenComponent; blue = value.blueComponent; alpha = value.alphaComponent
    }
    var nsColor: NSColor { NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha) }
}

struct StoredPDFAnnotation: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var kind: AnnotationKind
    var page: Int
    var bounds: CGRect
    var color: AnnotationColor = AnnotationColor()
    var lineWidth: Double = 2
    var text: String = ""
    var fontSize: Double = 15
    var ink: [CGPoint] = [] // Absolute page-space coordinates.
    var quadrilaterals: [CGPoint] = [] // Absolute page-space coordinates, PDFKit Z order.
    var startPoint: CGPoint? = nil
    var endPoint: CGPoint? = nil
    var selectedText: String = ""
    func native() -> PDFAnnotation {
        let value: PDFAnnotation = kind == .freeText ? PageSpaceTextAnnotation(bounds: bounds, forType: kind.pdfType, withProperties: nil) : PDFAnnotation(bounds: bounds, forType: kind.pdfType, withProperties: nil)
        value.userName = "ULecture"
        value.setValue(id, forAnnotationKey: .name)
        value.contents = text.isEmpty ? selectedText : text; value.color = color.nsColor
        value.shouldDisplay = true; value.shouldPrint = true
        let border = PDFBorder(); border.lineWidth = lineWidth; value.border = border
        switch kind {
        case .highlight, .underline, .strikeOut:
            let points = quadrilaterals.isEmpty ? [CGPoint(x: bounds.minX, y: bounds.maxY), CGPoint(x: bounds.maxX, y: bounds.maxY), CGPoint(x: bounds.minX, y: bounds.minY), CGPoint(x: bounds.maxX, y: bounds.minY)] : quadrilaterals
            value.quadrilateralPoints = points.map { NSValue(point: CGPoint(x: $0.x - bounds.minX, y: $0.y - bounds.minY)) }
        case .ink:
            let path = NSBezierPath()
            if let first = ink.first { path.move(to: CGPoint(x: first.x - bounds.minX, y: first.y - bounds.minY)); for point in ink.dropFirst() { path.line(to: CGPoint(x: point.x - bounds.minX, y: point.y - bounds.minY)) } }
            value.add(path)
        case .freeText:
            value.font = .systemFont(ofSize: fontSize); value.fontColor = color.nsColor; value.color = .clear; value.border?.lineWidth = 0
        case .stickyNote: value.iconType = .note
        case .rectangle, .ellipse: value.interiorColor = .clear
        case .arrow:
            let start = startPoint ?? CGPoint(x: bounds.minX, y: bounds.minY), end = endPoint ?? CGPoint(x: bounds.maxX, y: bounds.maxY)
            value.startPoint = CGPoint(x: start.x - bounds.minX, y: start.y - bounds.minY)
            value.endPoint = CGPoint(x: end.x - bounds.minX, y: end.y - bounds.minY); value.endLineStyle = .openArrow
        }
        return value
    }
    mutating func translate(dx: CGFloat, dy: CGFloat) {
        bounds = bounds.offsetBy(dx: dx, dy: dy)
        ink = ink.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        quadrilaterals = quadrilaterals.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
        startPoint = startPoint.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }; endPoint = endPoint.map { CGPoint(x: $0.x + dx, y: $0.y + dy) }
    }
}

struct PDFPageGeometry: Codable, Equatable {
    var mediaBox: CGRect
    var cropBox: CGRect
    var rotation: Int
}
struct PDFAnnotationDocument: Codable, Equatable {
    var format = "ulecture-pdf-annotations"
    var formatVersion = 1
    var documentID: String
    var sourceHash: String
    var revision = 0
    var savedAt = Date()
    var pages: [PDFPageGeometry]
    var annotations: [StoredPDFAnnotation] = []
    var viewRotations: [String: Int] = [:]
}
struct PDFAnnotationLoad {
    var document: PDFDocument
    var annotations: PDFAnnotationDocument
    var historicalHashes: [String]
    var currentHash: String
    var recoveredDraft: Bool
    var draftConflict: Bool
    var historicalRevision: Bool
}

final class PDFAnnotationStore {
    let documentID: String
    let sourceURL: URL
    let sidecarURL: URL
    private let lock: NSRecursiveLock
    private var observed: [String: String] = [:]
    private var publishedDraftCutoffs: [String: Date] = [:]
    init(documentID: String, sourceURL: URL, sidecarURL: URL) { self.documentID = documentID; self.sourceURL = sourceURL; self.sidecarURL = sidecarURL; lock = DocumentDisk.serialLock(for: sidecarURL) }
    private func locked<T>(_ body: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try body() }
    private func versionDirectory(_ hash: String) throws -> URL {
        guard hash.count == 64, hash.allSatisfy(\.isHexDigit) else { throw DocumentFailure.invalidFormat }
        return try DocumentDisk.child("versions/" + hash, in: sidecarURL)
    }
    func snapshotURL(_ hash: String) throws -> URL { try versionDirectory(hash).appendingPathComponent("source.pdf") }
    private func archiveURL(_ hash: String) throws -> URL { try versionDirectory(hash).appendingPathComponent("annotations.json") }
    func load(version: String? = nil, annotationRevision: Int? = nil) throws -> PDFAnnotationLoad {
        try locked {
            let current = try? DocumentDisk.hash(sourceURL)
            guard let hash = version ?? current else { throw DocumentFailure.missingResource(sourceURL.lastPathComponent) }
            let directory = try versionDirectory(hash)
            let snapshot = try snapshotURL(hash)
            if !FileManager.default.fileExists(atPath: snapshot.path) {
                guard hash == current else { throw DocumentFailure.missingResource("PDF source version " + hash) }
                try DocumentDisk.writableDirectory(directory, create: true)
                let staged = directory.appendingPathComponent(".source-\(UUID().uuidString).pdf")
                defer { try? FileManager.default.removeItem(at: staged) }
                try FileManager.default.copyItem(at: sourceURL, to: staged)
                guard try DocumentDisk.hash(staged) == hash, try DocumentDisk.hash(sourceURL) == hash else { throw DocumentFailure.conflict }
                let handle = try FileHandle(forWritingTo: staged); try handle.synchronize(); try handle.close()
                try FileManager.default.moveItem(at: staged, to: snapshot); try DocumentDisk.syncDirectory(directory)
            }
            guard try DocumentDisk.hash(snapshot) == hash, let pdf = PDFDocument(url: snapshot), !pdf.isLocked, pdf.pageCount > 0 else { throw DocumentFailure.invalidFormat }
            let archive = try archiveURL(hash)
            var document: PDFAnnotationDocument
            if FileManager.default.fileExists(atPath: archive.path) {
                document = try DocumentDisk.read(PDFAnnotationDocument.self, from: archive)
                observed[hash] = try DocumentDisk.hash(archive)
            } else {
                document = PDFAnnotationDocument(documentID: documentID, sourceHash: hash, pages: (0..<pdf.pageCount).compactMap { pdf.page(at: $0) }.map { PDFPageGeometry(mediaBox: $0.bounds(for: .mediaBox), cropBox: $0.bounds(for: .cropBox), rotation: $0.rotation) })
                observed.removeValue(forKey: hash)
            }
            if let annotationRevision, annotationRevision != document.revision {
                guard annotationRevision > 0 else { throw DocumentFailure.invalidFormat }
                let revisions = try FileManager.default.contentsOfDirectory(at: directory.appendingPathComponent("revisions"), includingPropertiesForKeys: nil)
                let matches = revisions.filter { $0.lastPathComponent.hasPrefix("\(annotationRevision)-") && $0.pathExtension == "json" }
                guard matches.count == 1, let revisionURL = matches.first else { throw DocumentFailure.missingResource("Annotation revision \(annotationRevision)") }
                let bytes = try Data(contentsOf: revisionURL)
                guard revisionURL.deletingPathExtension().lastPathComponent == "\(annotationRevision)-" + DocumentDisk.hash(bytes) else { throw DocumentFailure.invalidFormat }
                document = try JSONDecoder().decode(PDFAnnotationDocument.self, from: bytes)
                guard document.revision == annotationRevision else { throw DocumentFailure.invalidFormat }
            }
            try validate(document)
            let actualPages = (0..<pdf.pageCount).compactMap { pdf.page(at: $0) }.map { PDFPageGeometry(mediaBox: $0.bounds(for: .mediaBox), cropBox: $0.bounds(for: .cropBox), rotation: $0.rotation) }
            guard document.sourceHash == hash, document.pages == actualPages else { throw DocumentFailure.invalidFormat }
            var recovered = false, conflict = false
            let draftURL = directory.appendingPathComponent("draft.json")
            if annotationRevision == nil, FileManager.default.fileExists(atPath: draftURL.path) {
                let draft = try DocumentDisk.read(PDFAnnotationDocument.self, from: draftURL); try validate(draft)
                guard draft.sourceHash == hash, draft.pages == document.pages else { throw DocumentFailure.invalidFormat }
                if draft.annotations != document.annotations || draft.viewRotations != document.viewRotations { conflict = draft.revision != document.revision; document = draft; recovered = true }
            }
            apply(document, to: pdf)
            let roots = (try? FileManager.default.contentsOfDirectory(at: sidecarURL.appendingPathComponent("versions"), includingPropertiesForKeys: nil)) ?? []
            let histories = roots.map(\.lastPathComponent).filter { $0 != current && $0.count == 64 }.sorted()
            return PDFAnnotationLoad(document: pdf, annotations: document, historicalHashes: histories, currentHash: current ?? "", recoveredDraft: recovered, draftConflict: conflict, historicalRevision: annotationRevision != nil)
        }
    }
    private func validate(_ value: PDFAnnotationDocument) throws {
        guard value.format == "ulecture-pdf-annotations", value.formatVersion == 1, value.documentID == documentID,
              value.sourceHash.count == 64, value.sourceHash.allSatisfy(\.isHexDigit),
              !value.pages.isEmpty, value.revision >= 0, Set(value.annotations.map(\.id)).count == value.annotations.count else { throw DocumentFailure.invalidFormat }
        for page in value.pages {
            guard [page.mediaBox, page.cropBox].allSatisfy({ rect in rect.width.isFinite && rect.height.isFinite && rect.minX.isFinite && rect.minY.isFinite && rect.width > 0 && rect.height > 0 }), page.rotation % 90 == 0 else { throw DocumentFailure.invalidFormat }
        }
        guard value.viewRotations.allSatisfy({ key, rotation in Int(key).map { (1...value.pages.count).contains($0) } == true && rotation % 90 == 0 }) else { throw DocumentFailure.invalidFormat }
        for annotation in value.annotations {
            guard UUID(uuidString: annotation.id) != nil, (1...value.pages.count).contains(annotation.page),
                  annotation.bounds.width.isFinite, annotation.bounds.height.isFinite, annotation.bounds.origin.x.isFinite, annotation.bounds.origin.y.isFinite,
                  annotation.bounds.width > 0, annotation.bounds.height > 0, annotation.lineWidth.isFinite && annotation.lineWidth > 0,
                  annotation.fontSize.isFinite && annotation.fontSize > 0,
                  (annotation.ink + annotation.quadrilaterals + [annotation.startPoint, annotation.endPoint].compactMap { $0 }).allSatisfy({ $0.x.isFinite && $0.y.isFinite }), annotation.quadrilaterals.count % 4 == 0,
                  [annotation.color.red, annotation.color.green, annotation.color.blue, annotation.color.alpha].allSatisfy({ $0.isFinite && (0...1).contains($0) }) else { throw DocumentFailure.invalidFormat }
        }
    }
    func saveDraft(_ document: PDFAnnotationDocument) throws {
        try locked {
            guard document.savedAt > (publishedDraftCutoffs[document.sourceHash] ?? .distantPast) else { return }
            try validate(document)
            let url = try versionDirectory(document.sourceHash).appendingPathComponent("draft.json")
            if let previous = try? DocumentDisk.read(PDFAnnotationDocument.self, from: url), previous.savedAt > document.savedAt { return }
            try DocumentDisk.write(DocumentDisk.json(document), to: url)
        }
    }
    @discardableResult func save(_ document: PDFAnnotationDocument) throws -> PDFAnnotationDocument {
        try locked {
            try validate(document)
            let url = try archiveURL(document.sourceHash)
            let exists = FileManager.default.fileExists(atPath: url.path)
            let actual = try exists ? DocumentDisk.hash(url) : nil
            guard actual == observed[document.sourceHash] else { throw DocumentFailure.conflict }
            let previous = try exists ? DocumentDisk.read(PDFAnnotationDocument.self, from: url) : nil
            guard previous == nil || previous?.revision == document.revision else { throw DocumentFailure.conflict }
            if let previous, previous.annotations == document.annotations && previous.viewRotations == document.viewRotations { publishedDraftCutoffs[document.sourceHash] = max(publishedDraftCutoffs[document.sourceHash] ?? .distantPast, document.savedAt); return previous }
            var next = document; next.revision = (previous?.revision ?? 0) + 1; next.savedAt = Date()
            let data = try DocumentDisk.json(next)
            let directory = try versionDirectory(next.sourceHash).appendingPathComponent("revisions")
            try DocumentDisk.writableDirectory(directory, create: true)
            let revision = directory.appendingPathComponent("\(next.revision)-\(DocumentDisk.hash(data)).json")
            if !FileManager.default.fileExists(atPath: revision.path) { try DocumentDisk.write(data, to: revision, replace: false) }
            try DocumentDisk.write(data, to: url, replace: exists); observed[next.sourceHash] = DocumentDisk.hash(data)
            publishedDraftCutoffs[document.sourceHash] = max(publishedDraftCutoffs[document.sourceHash] ?? .distantPast, document.savedAt)
            let draft = try versionDirectory(next.sourceHash).appendingPathComponent("draft.json")
            if let pending = try? DocumentDisk.read(PDFAnnotationDocument.self, from: draft), pending.annotations == next.annotations && pending.viewRotations == next.viewRotations { try? FileManager.default.removeItem(at: draft) }
            return next
        }
    }
    /// An explicit reload keeps every visible unsaved change in an immutable recovery record first.
    func preserveRecovery(_ document: PDFAnnotationDocument) throws {
        try locked {
            try validate(document)
            let directory = try versionDirectory(document.sourceHash)
            let recovery = directory.appendingPathComponent("recovery")
            try DocumentDisk.writableDirectory(recovery, create: true)
            let bytes = try DocumentDisk.json(document), destination = recovery.appendingPathComponent(UUID().uuidString + ".json")
            try DocumentDisk.write(bytes, to: destination, replace: false)
            publishedDraftCutoffs[document.sourceHash] = max(publishedDraftCutoffs[document.sourceHash] ?? .distantPast, document.savedAt)
            let draftURL = directory.appendingPathComponent("draft.json")
            if let pending = try? DocumentDisk.read(PDFAnnotationDocument.self, from: draftURL), pending.annotations == document.annotations && pending.viewRotations == document.viewRotations { try FileManager.default.removeItem(at: draftURL); try DocumentDisk.syncDirectory(directory) }
        }
    }
    func apply(_ archive: PDFAnnotationDocument, to pdf: PDFDocument) {
        let ids = Set(archive.annotations.map(\.id))
        for number in 0..<pdf.pageCount {
            guard let page = pdf.page(at: number) else { continue }
            for annotation in page.annotations where (annotation.value(forAnnotationKey: .name) as? String).map({ ids.contains($0) || $0.hasPrefix("ul-preview-") }) == true { page.removeAnnotation(annotation) }
            guard archive.pages.indices.contains(number) else { continue }
            let base = archive.pages[number].rotation
            page.rotation = (base + (archive.viewRotations[String(number + 1)] ?? 0)) % 360
        }
        for annotation in archive.annotations { pdf.page(at: annotation.page - 1)?.addAnnotation(annotation.native()) }
    }
    func export(_ archive: PDFAnnotationDocument, to destination: URL, flattened: Bool = false) throws {
        try locked {
            try validate(archive)
            guard destination.standardizedFileURL != sourceURL.standardizedFileURL, !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
            let snapshot = try snapshotURL(archive.sourceHash)
            guard try DocumentDisk.hash(snapshot) == archive.sourceHash, let document = PDFDocument(url: snapshot), document.pageCount == archive.pages.count else { throw DocumentFailure.invalidFormat }
            apply(archive, to: document)
            let options: [PDFDocumentWriteOption: Any] = [.burnInAnnotationsOption: flattened]
            guard let bytes = document.dataRepresentation(options: options), let reopened = PDFDocument(data: bytes), reopened.pageCount == archive.pages.count else { throw DocumentFailure.invalidFormat }
            try DocumentDisk.write(bytes, to: destination, replace: false)
        }
    }
    func reassociate(_ annotation: StoredPDFAnnotation, to page: Int, in current: inout PDFAnnotationDocument) throws {
        // The user chose the current source. A stale/missing source must never turn this into
        // another edit of the preserved historical archive.
        guard try DocumentDisk.hash(sourceURL) == current.sourceHash else { throw DocumentFailure.conflict }
        guard (1...current.pages.count).contains(page) else { throw DocumentFailure.invalidFormat }
        var copy = annotation; copy.id = UUID().uuidString; copy.page = page
        let available = current.pages[page - 1].cropBox
        guard copy.bounds.width <= available.width, copy.bounds.height <= available.height else { throw DocumentFailure.message("The annotation is larger than the target page. Resize it before copying.") }
        let x = min(max(copy.bounds.minX, available.minX), available.maxX - copy.bounds.width)
        let y = min(max(copy.bounds.minY, available.minY), available.maxY - copy.bounds.height)
        copy.translate(dx: x - copy.bounds.minX, dy: y - copy.bounds.minY); current.annotations.append(copy)
    }
}
