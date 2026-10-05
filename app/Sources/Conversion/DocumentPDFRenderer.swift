import Foundation
import CoreGraphics
import CoreText
import ImageIO
import PDFKit
import Darwin

struct DocumentRenderedOutput { var mapping: [DocumentTranslationMapping]; var rasterPages: [Int]; var companion: String?; var warnings: [String]; var rasterReasons: [String: String] = [:] }
enum DocumentPDFRenderer {
    static func render(_ job: DocumentTranslationJob, directory: URL, resources: ConversionResources) async throws -> DocumentRenderedOutput {
        let output = directory.appendingPathComponent("translation.pdf")
        let staging = directory.appendingPathComponent("render-" + UUID().uuidString + ".pdf")
        let flowURL = directory.appendingPathComponent("flow-source.json")
        if FileManager.default.fileExists(atPath: flowURL.path) {
            let source = try JSONDecoder().decode(DocumentFlowSource.self, from: Data(contentsOf: flowURL))
            let translations = Dictionary(uniqueKeysWithValues: job.regions.compactMap { item in item.translation.map { (item.id, $0) } })
            let rendered = try DocumentFlowRenderer.render(source, translations: translations, mode: job.mode, to: staging, resourceDirectory: directory)
            let mapping = job.pages.map { page in DocumentTranslationMapping(sourcePage: page.number, outputPages: rendered.pages.filter { !Set($0.regionIDs).isDisjoint(with: page.regionIDs) }.map(\.number), regionIDs: page.regionIDs) }
            let companion = try exportFlow(source, translations: translations, job: job, directory: directory)
            try validateAndPublish(staging, output: output)
            return DocumentRenderedOutput(mapping: mapping, rasterPages: [], companion: companion, warnings: rendered.warnings)
        }
        let removals = job.regions.filter { $0.translation != nil }.flatMap(\.objectIDs)
        let removalURL = directory.appendingPathComponent("translated-object-ids.json")
        try JSONEncoder().encode(removals).write(to: removalURL, options: .atomic)
        let sourceURL = directory.appendingPathComponent("normalized.pdf"), backgroundURL = directory.appendingPathComponent("background.pdf")
        try await ConversionProcess.run(resources.helper, arguments: ["strip", sourceURL.path, backgroundURL.path, removalURL.path], directory: directory, resources: [resources.helper.deletingLastPathComponent()])
        struct BackgroundCoverage: Decodable { var rasterPages: [Int]; var dpi: Int; var reasons: [String: String]? }
        let coverage = try JSONDecoder().decode(BackgroundCoverage.self, from: Data(contentsOf: URL(fileURLWithPath: backgroundURL.path + ".coverage.json")))
        guard let original = CGPDFDocument(sourceURL as CFURL), let background = CGPDFDocument(backgroundURL as CFURL),
              let consumer = CGDataConsumer(url: staging as CFURL), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw DocumentConversionError.invalidOutput }
        var outputNumber = 0, mapping: [DocumentTranslationMapping] = [], originalPageIndices: [String: Int] = [:]
        func begin(_ size: CGSize) { var box = CGRect(origin: .zero, size: size); context.beginPDFPage([kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary); outputNumber += 1 }
        for page in job.pages {
            try Task.checkCancellation()
            let size = CGSize(width: page.width, height: page.height), box = CGRect(origin: .zero, size: size)
            var outputPages: [Int] = []
            if job.mode == .bilingual, original.page(at: page.number) != nil {
                // Import the original PDF page after drawing translated pages.
                // Redrawing it through Quartz can corrupt original ToUnicode.
                begin(size); originalPageIndices[String(outputNumber-1)] = page.number-1; context.endPDFPage(); outputPages.append(outputNumber)
            }
            begin(size); outputPages.append(outputNumber)
            if coverage.rasterPages.contains(page.number) {
                let url = URL(fileURLWithPath: backgroundURL.path + ".page\(page.number).png")
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { throw DocumentConversionError.invalidOutput }
                context.draw(image, in: box)
            } else if let backgroundPage = background.page(at: page.number) { context.drawPDFPage(backgroundPage) }
            else { throw DocumentConversionError.invalidOutput }
            var overflow: [(DocumentRegion, String, Int)] = []
            let regions = job.regions.filter { $0.page == page.number }
            for region in regions {
                guard let translation = region.translation else { continue }
                if region.kind == "ocr" {
                    guard let color = region.background, color.count == 4 else { throw DocumentConversionError.invalidOutput }
                    context.setFillColor(CGColor(colorSpace: CGColorSpaceCreateDeviceRGB(), components: color.map { CGFloat($0) })!)
                    context.fill(region.bounds.insetBy(dx: -2.5, dy: -2.5))
                }
                let angle = region.angle
                let vertical = abs(sin(angle)) > 0.7
                let drawSize = CGSize(width: (vertical ? region.bounds.height : region.bounds.width) + 5, height: (vertical ? region.bounds.width : region.bounds.height) + 8)
                let rect = CGRect(x: -drawSize.width/2, y: -drawSize.height/2, width: drawSize.width, height: drawSize.height)
                var font = min(36, max(11, region.fontSize)), fits = false
                while font >= 10.5 {
                    let setter = CTFramesetterCreateWithAttributedString(DocumentPDFDrawing.attributed(translation, fontSize: font, color: region.color))
                    let frame = CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil)
                    if CTFrameGetVisibleStringRange(frame).length >= (translation as NSString).length { fits = true; break }; font -= 0.5
                }
                context.saveGState(); context.translateBy(x: region.bounds.midX, y: region.bounds.midY); context.rotate(by: angle)
                if fits { DocumentPDFDrawing.draw(translation, in: rect, fontSize: font, color: region.color, context: context) }
                else {
                    let marker = overflow.count + 1; overflow.append((region, translation, marker))
                    DocumentPDFDrawing.draw("〔\(marker)〕", in: CGRect(x: rect.minX, y: rect.minY, width: max(60, rect.width), height: max(24, rect.height)), fontSize: 11, color: region.color, context: context)
                }
                context.restoreGState()
            }
            context.endPDFPage()
            if !overflow.isEmpty {
                begin(size); outputPages.append(outputNumber)
                var top = size.height - 42
                for (_, text, marker) in overflow {
                    let heading = "\(page.number) · 〔\(marker)〕"
                    let attributed = DocumentPDFDrawing.attributed(heading + "\n" + text, fontSize: 14, color: [0.08,0.1,0.15,1])
                    let setter = CTFramesetterCreateWithAttributedString(attributed); var offset = 0
                    while offset < attributed.length {
                        let rect = CGRect(x: 36, y: 36, width: max(100, size.width-72), height: max(24, top-36))
                        let frame = CTFramesetterCreateFrame(setter, CFRange(location: offset, length: 0), CGPath(rect: rect, transform: nil), nil)
                        let visible = CTFrameGetVisibleStringRange(frame)
                        if visible.length == 0 || top < 90 { context.endPDFPage(); begin(size); outputPages.append(outputNumber); top = size.height-42; continue }
                        CTFrameDraw(frame, context); offset += visible.length
                        let used = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: visible.location, length: visible.length), nil, CGSize(width: rect.width, height: rect.height), nil).height
                        top -= used+22
                        if offset < attributed.length { context.endPDFPage(); begin(size); outputPages.append(outputNumber); top = size.height-42 }
                    }
                }
                context.endPDFPage()
            }
            mapping.append(DocumentTranslationMapping(sourcePage: page.number, outputPages: outputPages, regionIDs: page.regionIDs))
        }
        context.closePDF(); try Task.checkCancellation()
        if job.mode == .bilingual {
            let pageMap = directory.appendingPathComponent("original-page-map.json"), composed = directory.appendingPathComponent("composed-" + UUID().uuidString + ".pdf")
            try JSONEncoder().encode(originalPageIndices).write(to: pageMap, options: .atomic)
            try await ConversionProcess.run(resources.helper, arguments: ["compose", sourceURL.path, composed.path, staging.path, pageMap.path], directory: directory, resources: [resources.helper.deletingLastPathComponent()])
            try validateAndPublish(composed, output: output); try? FileManager.default.removeItem(at: staging)
        } else { try validateAndPublish(staging, output: output) }
        return DocumentRenderedOutput(mapping: mapping, rasterPages: coverage.rasterPages, companion: nil, warnings: coverage.rasterPages.isEmpty ? [] : ["graphicsRasterized300DPI"], rasterReasons: coverage.reasons ?? [:])
    }
    private static func validateAndPublish(_ staging: URL, output: URL) throws {
        guard let pdf = PDFDocument(url: staging), pdf.pageCount > 0 else { throw DocumentConversionError.invalidOutput }
        for number in 0..<pdf.pageCount { guard pdf.page(at: number) != nil else { throw DocumentConversionError.invalidOutput } }
        let data = try Data(contentsOf: staging); try data.write(to: output, options: .atomic)
        try? FileManager.default.removeItem(at: staging)
    }
    private static func exportFlow(_ source: DocumentFlowSource, translations: [String: String], job: DocumentTranslationJob, directory: URL) throws -> String {
        if source.format == "ulnote", let data = source.originalNote, var note = try JSONSerialization.jsonObject(with: data) as? [String: Any], var blocks = note["blocks"] as? [[String: Any]] {
            let output = directory.appendingPathComponent("translation.ulnote", isDirectory: true)
            let existing = (try? Data(contentsOf: output.appendingPathComponent("note.json"))).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
            let existingID = existing?["id"] as? String, previousRevision = existing?["revision"] as? Int ?? 0
            let canContinue = existing?["format"] as? String == "ulecture-block-note" && existingID?.isEmpty == false && existingID != note["id"] as? String && previousRevision > 0 && previousRevision < 1_000_000
            if FileManager.default.fileExists(atPath: output.path) && !canContinue { throw DocumentConversionError.invalidOutput }
            let revision = canContinue ? previousRevision + 1 : 1
            note["id"] = canContinue ? existingID! : UUID().uuidString; note["revision"] = revision; note["savedAt"] = Date().timeIntervalSinceReferenceDate
            note["title"] = source.title + (job.targetLanguage == "zh-Hant" ? " · 譯文" : " · 译文")
            for index in blocks.indices {
                guard let id = blocks[index]["id"] as? String, let block = source.blocks.first(where: { $0.id == id }) else { continue }
                if block.kind == "code" { continue }
                let translated = source.translated(block.text, id: id, translations: translations)
                blocks[index]["text"] = job.mode == .bilingual && translated != block.text ? block.text + "\n\n" + translated : translated
                blocks[index].removeValue(forKey: "richText")
                blocks[index]["cells"] = block.cells.enumerated().map { row, values in values.enumerated().map { column, text in
                    let translated = source.translated(text, id: id + ".r\(row)c\(column)", translations: translations)
                    return job.mode == .bilingual && translated != text ? text + "\n" + translated : translated
                } }
            }
            note["blocks"] = blocks
            let staging = directory.appendingPathComponent("note-" + UUID().uuidString + ".ulnote", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: staging) }
            if canContinue { try FileManager.default.copyItem(at: output, to: staging) }
            try FileManager.default.createDirectory(at: staging.appendingPathComponent("revisions"), withIntermediateDirectories: true)
            let assets = directory.appendingPathComponent("source.ulnote/assets")
            if FileManager.default.fileExists(atPath: assets.path), !FileManager.default.fileExists(atPath: staging.appendingPathComponent("assets").path) { try FileManager.default.copyItem(at: assets, to: staging.appendingPathComponent("assets")) }
            else { try FileManager.default.createDirectory(at: staging.appendingPathComponent("assets"), withIntermediateDirectories: true) }
            let bytes = try JSONSerialization.data(withJSONObject: note, options: [.sortedKeys])
            try bytes.write(to: staging.appendingPathComponent("note.json"), options: .atomic)
            try bytes.write(to: staging.appendingPathComponent("revisions/\(revision)-" + documentHash(bytes) + ".json"), options: .atomic)
            try Task.checkCancellation()
            let replacing = FileManager.default.fileExists(atPath: output.path)
            if replacing {
                guard renamex_np(staging.path, output.path, UInt32(RENAME_SWAP)) == 0 else { throw DocumentConversionError.persistence }
            } else { try FileManager.default.moveItem(at: staging, to: output) }
            return "translation.ulnote"
        }
        let text = source.format == "txt" ? source.blocks.map { block in
            let translated = source.translated(block.text, id: block.id, translations: translations)
            return job.mode == .bilingual && translated != block.text ? block.text + "\n\n" + translated : translated
        }.joined(separator: "\n\n") : source.markdown(translations: translations, mode: job.mode)
        let name = "translation." + (source.format == "txt" ? "txt" : "md")
        try Data(text.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
        return name
    }
}
