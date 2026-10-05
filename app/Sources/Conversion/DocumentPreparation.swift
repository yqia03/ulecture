import Foundation
import CoreGraphics
import CoreText
import ImageIO
import Vision
import PDFKit

struct PreparedDocument {
    var sourceHash: String
    var pages: [DocumentPageLayout]
    var regions: [DocumentRegion]
    var warnings: [String]
    var slideNotes: [DocumentSlideNote] = []
    var fontReports: [DocumentFontReport] = []
}
struct ConvertedReadingDocument {
    var pdfURL: URL
    var sourceHash: String
    var sourcePageNumbers: [Int]
    var warnings: [String]
    var slideNotes: [DocumentSlideNote] = []
    var fontReports: [DocumentFontReport] = []
}

enum DocumentPreparation {
    static func prepare(source: URL, directory: URL, sourceLanguage: String, resources: ConversionResources, extract: Bool = true) async throws -> PreparedDocument {
        let resources = resources.frozen()
        let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
        let ext = source.pathExtension.lowercased()
        guard ["pdf", "ppt", "pptx", "md", "txt", "ulnote"].contains(ext) else { throw DocumentConversionError.unsupported }
        guard resources.pdfReady else { throw DocumentConversionError.resourcesMissing }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let copy = directory.appendingPathComponent("source." + ext)
        if !FileManager.default.fileExists(atPath: copy.path) {
            let values = try source.resourceValues(forKeys: [.fileSizeKey, .isSymbolicLinkKey, .isDirectoryKey])
            guard values.isSymbolicLink != true, (values.fileSize ?? 0) <= 200_000_000 else { throw DocumentConversionError.tooLarge }
            if ext == "ulnote" { try copyPackage(source, to: copy) }
            else { try FileManager.default.copyItem(at: source, to: copy) }
        }
        var warnings: [String] = [], slideMetadata = SlideMetadata()
        let hashData = try Data(contentsOf: ext == "ulnote" ? copy.appendingPathComponent("note.json") : copy, options: .mappedIfSafe)
        guard hashData.count <= 200_000_000 else { throw DocumentConversionError.tooLarge }
        if ["ppt", "pptx"].contains(ext), hashData.starts(with: [0xD0,0xCF,0x11,0xE0,0xA1,0xB1,0x1A,0xE1]), ["EncryptedPackage", "EncryptedSummary"].contains(where: { hashData.range(of: $0.data(using: .utf16LittleEndian)!) != nil }) { throw DocumentConversionError.encrypted }
        var pdf = copy
        if ext == "ppt" || ext == "pptx" {
            guard resources.slidesReady else { throw DocumentConversionError.resourcesMissing }
            if ext == "pptx" { slideMetadata = try await SlideMetadata.loadPPTX(copy, directory: directory) }
            let converted = directory.appendingPathComponent("slides", isDirectory: true)
            let profile = directory.appendingPathComponent("office-profile", isDirectory: true)
            try FileManager.default.createDirectory(at: converted, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: profile.appendingPathComponent("user"), withIntermediateDirectories: true)
            let settings = """
            <?xml version="1.0" encoding="UTF-8"?><oor:items xmlns:oor="http://openoffice.org/2001/registry"><item oor:path="/org.openoffice.Office.Common/Security/Scripting"><prop oor:name="MacroSecurityLevel" oor:op="fuse"><value>3</value></prop><prop oor:name="DisableMacrosExecution" oor:op="fuse"><value>true</value></prop></item><item oor:path="/org.openoffice.Office.Common/Load"><prop oor:name="UpdateMode" oor:op="fuse"><value>0</value></prop></item><item oor:path="/org.openoffice.Office.Common/Misc"><prop oor:name="FirstRun" oor:op="fuse"><value>false</value></prop></item></oor:items>
            """
            try Data(settings.utf8).write(to: profile.appendingPathComponent("user/registrymodifications.xcu"), options: .atomic)
            try await ConversionProcess.run(resources.libreOffice, arguments: ["-env:UserInstallation=" + profile.absoluteString, "--headless", "--nologo", "--nodefault", "--nolockcheck", "--nofirststartwizard", "--convert-to", "pdf:impress_pdf_Export:{\"ExportNotesPages\":{\"type\":\"boolean\",\"value\":\"false\"},\"ExportHiddenSlides\":{\"type\":\"boolean\",\"value\":\"true\"}}", "--outdir", converted.path, copy.path], directory: directory, resources: [resources.libreOffice.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()], timeout: 120)
            pdf = converted.appendingPathComponent("source.pdf")
            guard FileManager.default.fileExists(atPath: pdf.path) else { throw DocumentConversionError.conversionFailed }
            if ext == "ppt" {
                // The same isolated converter exposes binary PPT notes/font
                // declarations through OOXML without requiring PowerPoint.
                try await ConversionProcess.run(resources.libreOffice, arguments: ["-env:UserInstallation=" + profile.absoluteString, "--headless", "--nologo", "--nodefault", "--nolockcheck", "--nofirststartwizard", "--convert-to", "pptx:Impress MS PowerPoint 2007 XML", "--outdir", converted.path, copy.path], directory: directory, resources: [resources.libreOffice.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()], timeout: 120)
                slideMetadata = try await SlideMetadata.loadPPTX(converted.appendingPathComponent("source.pptx"), directory: directory)
                slideMetadata.warnings.append("legacyMetadataConverted")
            }
            warnings += ["staticSlides", "speakerNotesExcluded", "fontSubstitutionNeedsReview"]
            if slideMetadata.hasAnimations { warnings.append("animationsDetected") }
            if slideMetadata.hasEmbeddedMedia { warnings.append("embeddedMediaDetected") }
        } else if ["md", "txt", "ulnote"].contains(ext) {
            // Text/note structure is retained separately for editable companion
            // output. The source PDF uses the same paginated drawing path.
            let flowURL = directory.appendingPathComponent("flow-source.json")
            var flow: DocumentFlowSource
            if FileManager.default.fileExists(atPath: flowURL.path) { flow = try JSONDecoder().decode(DocumentFlowSource.self, from: Data(contentsOf: flowURL)) }
            else {
                flow = try DocumentFlowSource.load(copy)
                if ext == "md" { try flow.freezeImages(relativeTo: source.deletingLastPathComponent(), in: directory) }
                try JSONEncoder().encode(flow).write(to: flowURL, options: .atomic)
            }
            pdf = directory.appendingPathComponent("flow-source.pdf")
            var prepared = try DocumentFlowRenderer.render(flow, translations: [:], mode: .translated, to: pdf, resourceDirectory: copy.deletingLastPathComponent())
            var snapshot = hashData
            for resource in Set(flow.blocks.compactMap(\.resource)).sorted() where !resource.contains("://") && !resource.hasPrefix("/") && !resource.components(separatedBy: "/").contains("..") {
                let resourceURL = directory.appendingPathComponent(resource)
                if let data = try? Data(contentsOf: resourceURL) { snapshot.append(Data(resource.utf8)); snapshot.append(Data(documentHash(data).utf8)) }
            }
            prepared.sourceHash = documentHash(snapshot)
            try Data(contentsOf: pdf).write(to: directory.appendingPathComponent("normalized.pdf"), options: .atomic)
            return prepared
        }
        let normalized = directory.appendingPathComponent("normalized.pdf")
        try await normalize(pdf, to: normalized, directory: directory, resources: resources)
        if !extract {
            guard let result = CGPDFDocument(normalized as CFURL) else { throw DocumentConversionError.invalidOutput }
            let pages = (1...result.numberOfPages).map { number -> DocumentPageLayout in
                let box = result.page(at: number)!.getBoxRect(.mediaBox)
                return DocumentPageLayout(number: number, width: box.width, height: box.height, regionIDs: [])
            }
            return PreparedDocument(sourceHash: documentHash(hashData), pages: pages, regions: [], warnings: warnings + slideMetadata.warnings, slideNotes: slideMetadata.notes, fontReports: slideMetadata.missingFonts)
        }
        let layoutURL = directory.appendingPathComponent("layout.json")
        try await ConversionProcess.run(resources.helper, arguments: ["extract", normalized.path, layoutURL.path], directory: directory, resources: [resources.helper.deletingLastPathComponent()])
        let layout = try JSONDecoder().decode(PDFiumLayout.self, from: Data(contentsOf: layoutURL))
        guard layout.schema == 1 else { throw DocumentConversionError.invalidDocument }
        var pages: [DocumentPageLayout] = [], regions: [DocumentRegion] = []
        guard let document = CGPDFDocument(normalized as CFURL) else { throw DocumentConversionError.invalidDocument }
        for page in layout.pages {
            try Task.checkCancellation()
            var items = page.objects.filter { $0.bounds.count == 4 && $0.rgba.count == 4 }.map { object -> DocumentRegion in
                let bounds = CGRect(x: object.bounds[0], y: object.bounds[1], width: object.bounds[2] - object.bounds[0], height: object.bounds[3] - object.bounds[1])
                let formula = isFormula(object.text)
                return DocumentRegion(id: object.id, page: page.number, objectIDs: [object.id], source: object.text, bounds: bounds, fontSize: max(10, object.fontSize), color: object.rgba.map { $0 / 255 }, angle: object.angle, kind: formula ? "formula" : "text")
            }
            items = combineLines(items)
            for index in items.indices where items[index].source.filter(\.isLetter).isEmpty { items[index].kind = "formula" }
            var pageWarnings: [String] = []
            if let cgPage = document.page(at: page.number), let bitmap = renderPage(cgPage, scale: 2) {
                let ocr = try recognize(bitmap, pageNumber: page.number, pageSize: CGSize(width: page.width, height: page.height), sourceLanguage: sourceLanguage, existing: items)
                items += ocr.regions; pageWarnings += ocr.warnings
            }
            if items.isEmpty { pageWarnings.append("noExtractableText") }
            if items.contains(where: { $0.kind == "formula" }) { pageWarnings.append("formulasPreserved") }
            regions += items
            pages.append(DocumentPageLayout(number: page.number, width: page.width, height: page.height, regionIDs: items.map(\.id), warnings: Array(Set(pageWarnings)).sorted()))
        }
        for index in slideMetadata.missingFonts.indices {
            let report = slideMetadata.missingFonts[index]
            slideMetadata.missingFonts[index].renderedFonts = Array(Set(layout.pages.filter { report.sourcePages.contains($0.number) }.flatMap { $0.objects.compactMap(\.fontName) })).sorted()
        }
        return PreparedDocument(sourceHash: documentHash(hashData), pages: pages, regions: regions, warnings: warnings + slideMetadata.warnings, slideNotes: slideMetadata.notes, fontReports: slideMetadata.missingFonts)
    }

    static func prepareForReading(source: URL, cacheDirectory: URL, resources: ConversionResources = ConversionResources()) async throws -> ConvertedReadingDocument {
        let access = source.startAccessingSecurityScopedResource(); defer { if access { source.stopAccessingSecurityScopedResource() } }
        let size = try source.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size <= 200_000_000 else { throw DocumentConversionError.tooLarge }
        let hash = documentHash(try Data(contentsOf: source, options: .mappedIfSafe))
        let ext = source.pathExtension.lowercased()
        guard ["ppt", "pptx", "pdf"].contains(ext) else { throw DocumentConversionError.unsupported }
        let final = cacheDirectory.appendingPathComponent(hash + "-" + ConversionResources.readingCacheVersion + ".pdf")
        let metadata = cacheDirectory.appendingPathComponent(hash + "-slides.json")
        let warnings = ext == "pdf" ? [] : ["staticSlides", "speakerNotesExcluded", "fontSubstitutionNeedsReview"]
        if let pdf = CGPDFDocument(final as CFURL), pdf.numberOfPages > 0, ext == "pdf" || FileManager.default.fileExists(atPath: metadata.path) {
            let details = (try? JSONDecoder().decode(SlideMetadata.self, from: Data(contentsOf: metadata))) ?? SlideMetadata()
            return ConvertedReadingDocument(pdfURL: final, sourceHash: hash, sourcePageNumbers: Array(1...pdf.numberOfPages), warnings: warnings + details.warnings, slideNotes: details.notes, fontReports: details.missingFonts)
        }
        let staging = cacheDirectory.appendingPathComponent("reading-" + UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: staging) }
        let result = try await prepare(source: source, directory: staging, sourceLanguage: "en", resources: resources, extract: false)
        guard result.sourceHash == hash else { throw DocumentConversionError.invalidDocument }
        try Task.checkCancellation()
        if !FileManager.default.fileExists(atPath: final.path) { try FileManager.default.moveItem(at: staging.appendingPathComponent("normalized.pdf"), to: final) }
        try JSONEncoder().encode(SlideMetadata(notes: result.slideNotes, missingFonts: result.fontReports, warnings: result.warnings)).write(to: metadata, options: .atomic)
        return ConvertedReadingDocument(pdfURL: final, sourceHash: hash, sourcePageNumbers: result.pages.map(\.number), warnings: result.warnings, slideNotes: result.slideNotes, fontReports: result.fontReports)
    }

    static func normalize(_ source: URL, to destination: URL, directory: URL, resources: ConversionResources) async throws {
        guard let pdf = CGPDFDocument(source as CFURL) else { throw DocumentConversionError.invalidDocument }
        guard !pdf.isEncrypted else { throw DocumentConversionError.encrypted }
        guard pdf.numberOfPages > 0, pdf.numberOfPages <= 400 else { throw DocumentConversionError.tooLarge }
        for number in 1...pdf.numberOfPages {
            try Task.checkCancellation()
            guard let page = pdf.page(at: number) else { throw DocumentConversionError.invalidDocument }
            let crop = page.getBoxRect(.cropBox), rotate = abs(page.rotationAngle) % 180 == 90
            let width = rotate ? crop.height : crop.width, height = rotate ? crop.width : crop.height
            guard width > 0, height > 0, width <= 4000, height <= 4000 else { throw DocumentConversionError.tooLarge }
        }
        try await ConversionProcess.run(resources.helper, arguments: ["normalize", source.path, destination.path], directory: directory, resources: [resources.helper.deletingLastPathComponent()])
    }
    static func renderPage(_ page: CGPDFPage, scale: Double) -> CGImage? {
        let bounds = page.getBoxRect(.mediaBox), width = Int(ceil(bounds.width * scale)), height = Int(ceil(bounds.height * scale))
        guard width > 0, height > 0, width * height <= 60_000_000,
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: width, height: height)); context.scaleBy(x: scale, y: scale); context.drawPDFPage(page)
        return context.makeImage()
    }
    private static func isFormula(_ text: String) -> Bool {
        let symbols = CharacterSet(charactersIn: "∑∫√≈≠≤≥∞∂∇⊗±")
        return text.unicodeScalars.contains(where: symbols.contains) || (text.contains("=") && text.filter(\.isLetter).count < 16)
    }
    private static func combineLines(_ input: [DocumentRegion]) -> [DocumentRegion] {
        func projected(_ rect: CGRect, angle: Double) -> (start: Double, end: Double, baseline: Double) {
            let c = cos(angle), s = sin(angle)
            let values = [rect.minX*c+rect.minY*s, rect.minX*c+rect.maxY*s, rect.maxX*c+rect.minY*s, rect.maxX*c+rect.maxY*s]
            return (values.min()!, values.max()!, -rect.midX*s+rect.midY*c)
        }
        var lines: [[DocumentRegion]] = []
        for item in input.sorted(by: { $0.bounds.midY > $1.bounds.midY }) {
            let point = projected(item.bounds, angle: item.angle)
            if let index = lines.firstIndex(where: { line in
                let first = line[0]
                return abs(first.angle-item.angle) < 0.05 && abs(projected(first.bounds, angle: first.angle).baseline-point.baseline) < max(3, min(first.fontSize,item.fontSize)*0.25)
            }) { lines[index].append(item) } else { lines.append([item]) }
        }
        var result: [DocumentRegion] = []
        for line in lines {
            let ordered = line.sorted { projected($0.bounds, angle: $0.angle).start < projected($1.bounds, angle: $1.angle).start }
            var combined: [DocumentRegion] = []
            for item in ordered {
                if var last = combined.last {
                    let gap = projected(item.bounds, angle: item.angle).start-projected(last.bounds, angle: last.angle).end
                    if last.kind == "text", item.kind == "text", abs(last.fontSize-item.fontSize) < 2, gap >= -1, gap < max(10,last.fontSize), last.color == item.color {
                        let separator = gap < last.fontSize*0.2 || last.source.last?.isWhitespace == true || item.source.first?.isWhitespace == true ? "" : " "
                        last.source += separator + item.source; last.bounds = last.bounds.union(item.bounds); last.objectIDs += item.objectIDs
                        combined[combined.count-1] = last; continue
                    }
                }
                combined.append(item)
            }
            result += combined
        }
        return result
    }
    private static func recognize(_ image: CGImage, pageNumber: Int, pageSize: CGSize, sourceLanguage: String, existing: [DocumentRegion]) throws -> (regions: [DocumentRegion], warnings: [String]) {
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = true
        request.revision = VNRecognizeTextRequestRevision3
        let desired = sourceLanguage == "ja" ? "ja-JP" : "en-US"
        let supported = try request.supportedRecognitionLanguages()
        guard supported.contains(desired) else { return ([], ["ocrLanguageUnavailable"]) }
        request.recognitionLanguages = [desired]
        try VNImageRequestHandler(cgImage: image).perform([request])
        var regions: [DocumentRegion] = []; var warnings: [String] = []
        for (index, observation) in (request.results ?? []).prefix(2000).enumerated() {
            guard let candidate = observation.topCandidates(1).first else { continue }
            // Isolated Latin letters, bullets and numeric chart labels are
            // preserved graphically. OCR often mistakes clipped shapes for
            // these; they do not constitute a translatable phrase.
            let letters = candidate.string.filter(\.isLetter)
            guard letters.count >= 2 || (sourceLanguage == "ja" && !letters.isEmpty && candidate.confidence >= 0.95) else { continue }
            let b = observation.boundingBox
            let bounds = CGRect(x: b.minX * pageSize.width, y: b.minY * pageSize.height, width: b.width * pageSize.width, height: b.height * pageSize.height)
            let nativeArea = existing.reduce(0.0) { value, region in
                let intersection = region.bounds.intersection(bounds)
                return value + (intersection.isNull ? 0 : intersection.width * intersection.height)
            }
            if nativeArea > bounds.width * bounds.height * 0.35 { continue }
            guard candidate.confidence >= 0.85 else {
                warnings.append("ocrLowConfidence")
                regions.append(DocumentRegion(id: "p\(pageNumber).ocr\(index)", page: pageNumber, objectIDs: [], source: candidate.string, bounds: bounds, fontSize: max(11, bounds.height*0.8), color: [0.08,0.1,0.13,1], kind: "unprocessedImageText", confidence: Double(candidate.confidence)))
                continue
            }
            let background = uniformBackground(image, box: b)
            let kind = background == nil ? "unprocessedImageText" : "ocr"
            if background == nil { warnings.append("complexImageTextUntranslated") }
            regions.append(DocumentRegion(id: "p\(pageNumber).ocr\(index)", page: pageNumber, objectIDs: [], source: candidate.string, bounds: bounds, fontSize: max(11, bounds.height * 0.8), color: [0.08, 0.1, 0.13, 1], kind: kind, confidence: Double(candidate.confidence), background: background))
        }
        if !regions.isEmpty { warnings.append("localOCR") }
        return (regions, warnings)
    }
    private static func uniformBackground(_ image: CGImage, box: CGRect) -> [Double]? {
        let w = image.width, h = image.height
        guard let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let bytes = context.data?.assumingMemoryBound(to: UInt8.self) else { return nil }
        // Pixel buffers have a top-origin row order; Vision boxes are bottom-origin.
        let left = max(0, Int(box.minX * Double(w)) - 4), right = min(w - 1, Int(box.maxX * Double(w)) + 4)
        let top = max(0, Int((1 - box.maxY) * Double(h)) - 4), bottom = min(h - 1, Int((1 - box.minY) * Double(h)) + 4)
        var samples: [[Double]] = []
        for x in stride(from: left, through: right, by: max(1, (right-left)/30)) { for y in [top, bottom] { let offset = (y*w+x)*4; samples.append((0..<3).map { Double(bytes[offset+$0]) }) } }
        for y in stride(from: top, through: bottom, by: max(1, (bottom-top)/12)) { for x in [left, right] { let offset = (y*w+x)*4; samples.append((0..<3).map { Double(bytes[offset+$0]) }) } }
        guard !samples.isEmpty else { return nil }
        let mean = (0..<3).map { component in samples.map { $0[component] }.reduce(0,+) / Double(samples.count) }
        guard samples.allSatisfy({ zip($0, mean).allSatisfy { abs($0-$1) < 14 } }) else { return nil }
        return mean.map { $0/255 } + [1]
    }
    private static func copyPackage(_ source: URL, to output: URL) throws {
        guard let enumerator = FileManager.default.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey, .fileSizeKey], options: [.skipsHiddenFiles]) else { throw DocumentConversionError.invalidDocument }
        var size = 0, count = 0
        for case let item as URL in enumerator {
            let values = try item.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey]); count += 1; size += values.fileSize ?? 0
            guard values.isSymbolicLink != true, size <= 200_000_000, count <= 5000 else { throw DocumentConversionError.tooLarge }
        }
        try FileManager.default.copyItem(at: source, to: output)
    }
}
