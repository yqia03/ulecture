import Foundation
import AppKit
import CoreText
import CoreGraphics
import ImageIO

struct DocumentFlowBlock: Codable {
    var id: String
    var kind: String
    var text: String = ""
    var level: Int = 2
    var prefix: String = ""
    var cells: [[String]] = []
    var resource: String? = nil
}
struct DocumentFlowSource: Codable {
    var format: String
    var title: String
    var blocks: [DocumentFlowBlock]
    var warnings: [String] = []
    var originalNote: Data? = nil
    static func load(_ url: URL) throws -> DocumentFlowSource {
        let ext = url.pathExtension.lowercased()
        if ext == "ulnote" {
            let data = try Data(contentsOf: url.appendingPathComponent("note.json"))
            guard data.count <= 5_000_000 else { throw DocumentConversionError.tooLarge }
            guard let note = try JSONSerialization.jsonObject(with: data) as? [String: Any], note["format"] as? String == "ulecture-block-note", let rows = note["blocks"] as? [[String: Any]], rows.count <= 5000 else { throw DocumentConversionError.invalidDocument }
            let blocks = rows.enumerated().map { index, row in DocumentFlowBlock(id: row["id"] as? String ?? "b\(index)", kind: row["kind"] as? String ?? "paragraph", text: row["text"] as? String ?? "", level: row["level"] as? Int ?? 2, prefix: row["kind"] as? String == "todo" ? ((row["checked"] as? Bool == true) ? "☑ " : "☐ ") : "", cells: row["cells"] as? [[String]] ?? [], resource: (row["resource"] as? String).map { url.lastPathComponent + "/" + $0 }) }
            return DocumentFlowSource(format: ext, title: note["title"] as? String ?? url.deletingPathExtension().lastPathComponent, blocks: blocks, warnings: blocks.contains(where: { $0.kind == "image" }) ? ["imagesNotAnalyzed"] : [], originalNote: data)
        }
        let bytes = try Data(contentsOf: url)
        guard bytes.count <= 5_000_000 else { throw DocumentConversionError.tooLarge }
        let text = String(data: bytes, encoding: .utf8) ?? String(data: bytes, encoding: .utf16) ?? String(data: bytes, encoding: .japaneseEUC) ?? String(data: bytes, encoding: .shiftJIS)
        guard let text else { throw DocumentConversionError.invalidDocument }
        if ext == "txt" { return DocumentFlowSource(format: ext, title: url.lastPathComponent, blocks: text.components(separatedBy: "\n\n").enumerated().map { DocumentFlowBlock(id: "b\($0.offset)", kind: "paragraph", text: $0.element) }) }
        var blocks: [DocumentFlowBlock] = [], paragraph: [String] = [], code: [String]?, fence = ""
        func flush() { if !paragraph.isEmpty { blocks.append(DocumentFlowBlock(id: "b\(blocks.count)", kind: "paragraph", text: paragraph.joined(separator: "\n"))); paragraph = [] } }
        for line in text.components(separatedBy: .newlines) {
            if var body = code {
                if line.hasPrefix(fence) { blocks.append(DocumentFlowBlock(id: "b\(blocks.count)", kind: "code", text: body.joined(separator: "\n"), prefix: fence)); code = nil }
                else { body.append(line); code = body }; continue
            }
            if line.hasPrefix("```") || line.hasPrefix("~~~") { flush(); fence = String(line.prefix(3)); code = []; continue }
            if line.trimmingCharacters(in: .whitespaces).isEmpty { flush(); continue }
            if line.hasPrefix("#") {
                flush(); let level = min(6, line.prefix(while: { $0 == "#" }).count)
                blocks.append(DocumentFlowBlock(id: "b\(blocks.count)", kind: "heading", text: String(line.dropFirst(level)).trimmingCharacters(in: .whitespaces), level: level)); continue
            }
            if line.hasPrefix("!["), let split = line.range(of: "]("), line.hasSuffix(")") {
                flush(); let alt = String(line[line.index(line.startIndex, offsetBy: 2)..<split.lowerBound]); let resource = String(line[split.upperBound..<line.index(before: line.endIndex)])
                blocks.append(DocumentFlowBlock(id: "b\(blocks.count)", kind: "image", text: alt, resource: resource)); continue
            }
            if line.hasPrefix("|") && line.hasSuffix("|") {
                flush(); let cells = line.dropFirst().dropLast().components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                if cells.allSatisfy({ !$0.isEmpty && $0.allSatisfy { "-: ".contains($0) } }) { continue }
                if blocks.last?.kind == "table" { blocks[blocks.count-1].cells.append(cells) }
                else { blocks.append(DocumentFlowBlock(id: "b\(blocks.count)", kind: "table", cells: [cells])) }; continue
            }
            if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("> ") { flush(); blocks.append(DocumentFlowBlock(id: "b\(blocks.count)", kind: line.hasPrefix(">") ? "quote" : "list", text: String(line.dropFirst(2)), prefix: String(line.prefix(2)))); continue }
            paragraph.append(line)
        }
        flush(); if let code { blocks.append(DocumentFlowBlock(id: "b\(blocks.count)", kind: "code", text: code.joined(separator: "\n"), prefix: fence)) }
        return DocumentFlowSource(format: ext, title: url.lastPathComponent, blocks: blocks, warnings: blocks.contains(where: { $0.kind == "image" }) ? ["imagesNotAnalyzed"] : [])
    }
    static func pieces(_ text: String) -> [String] {
        var result: [String] = [], remaining = text[...]
        while !remaining.isEmpty { let end = remaining.index(remaining.startIndex, offsetBy: min(1000, remaining.count)); result.append(String(remaining[..<end])); remaining = remaining[end...] }
        return result.isEmpty ? [""] : result
    }
    mutating func freezeImages(relativeTo sourceRoot: URL, in directory: URL) throws {
        var total = 0
        for index in blocks.indices where blocks[index].kind == "image" {
            guard let resource = blocks[index].resource?.removingPercentEncoding, !resource.contains("://"), !resource.hasPrefix("/"), !resource.components(separatedBy: "/").contains("..") else { warnings.append("remoteImageNotFetched"); continue }
            let source = sourceRoot.appendingPathComponent(resource).resolvingSymlinksInPath()
            guard source.path.hasPrefix(sourceRoot.resolvingSymlinksInPath().path + "/"), let values = try? source.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]), values.isRegularFile == true else { warnings.append("missingImage"); continue }
            guard (values.fileSize ?? 0) <= 20_000_000 else { throw DocumentConversionError.tooLarge }
            let data = try Data(contentsOf: source); total += data.count
            guard total <= 100_000_000 else { throw DocumentConversionError.tooLarge }
            let name = "flow-assets/" + documentHash(data) + "." + source.pathExtension.lowercased()
            let destination = directory.appendingPathComponent(name)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: destination, options: .atomic); blocks[index].resource = name
        }
        warnings = Array(Set(warnings)).sorted()
    }
    func translated(_ text: String, id: String, translations: [String: String]) -> String { Self.pieces(text).enumerated().map { translations[id + ":\($0.offset)"] ?? $0.element }.joined() }
    func markdown(translations: [String: String], mode: DocumentOutputMode) -> String {
        blocks.map { block in
            let target = translated(block.text, id: block.id, translations: translations)
            let text = mode == .bilingual && target != block.text ? block.text + "\n\n" + target : target
            switch block.kind {
            case "heading": return String(repeating: "#", count: max(1, min(6, block.level))) + " " + text
            case "code": return "```\n" + block.text + "\n```"
            case "table":
                let rows = block.cells.enumerated().map { row, values in "| " + values.enumerated().map { column, cell in
                    let translated = self.translated(cell, id: block.id + ".r\(row)c\(column)", translations: translations)
                    return (mode == .bilingual && translated != cell ? cell + "<br>" + translated : translated).replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>")
                }.joined(separator: " | ") + " |" }
                guard let first = rows.first else { return "" }
                return ([first, "| " + Array(repeating: "---", count: block.cells.first?.count ?? 1).joined(separator: " | ") + " |"] + rows.dropFirst()).joined(separator: "\n")
            case "image": return "![" + text + "](" + (block.resource ?? "") + ")"
            default: return block.prefix + text
            }
        }.joined(separator: "\n\n")
    }
}

enum DocumentFlowRenderer {
    @discardableResult static func render(_ source: DocumentFlowSource, translations: [String: String], mode: DocumentOutputMode, to output: URL, resourceDirectory: URL) throws -> PreparedDocument {
        guard let consumer = CGDataConsumer(url: output as CFURL), let context = CGContext(consumer: consumer, mediaBox: nil, nil) else { throw DocumentConversionError.persistence }
        var number = 0, top: CGFloat = 0, pages: [DocumentPageLayout] = [], regions: [DocumentRegion] = [], warnings = source.warnings
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        func newPage() throws {
            guard number < 400 else { throw DocumentConversionError.tooLarge }
            if number > 0 { context.endPDFPage() }
            number += 1; context.beginPDFPage([kCGPDFContextMediaBox: Data(bytes: &box, count: MemoryLayout<CGRect>.size)] as CFDictionary)
            context.setFillColor(CGColor(gray: 1, alpha: 1)); context.fill(box); top = 748
            pages.append(DocumentPageLayout(number: number, width: 612, height: 792, regionIDs: []))
        }
        func draw(_ text: String, sourceText: String, id: String, fontSize: CGFloat, code: Bool = false, prefix: String = "") throws {
            let attributed = DocumentPDFDrawing.attributed(prefix + text, fontSize: fontSize, color: [0.09,0.12,0.17,1], code: code, markdown: !code)
            let setter = CTFramesetterCreateWithAttributedString(attributed)
            let needed = CTFramesetterSuggestFrameSizeWithConstraints(setter, CFRange(location: 0, length: 0), nil, CGSize(width: 524, height: 2000), nil).height + 6
            if needed > 690 {
                var offset = 0, firstPage: Int?, firstFrame: CGRect?
                while offset < attributed.length {
                    if top < 110 { try newPage() }
                    let frame = CGRect(x: 44, y: 44, width: 524, height: top-44)
                    let layout = CTFramesetterCreateFrame(setter, CFRange(location: offset, length: 0), CGPath(rect: frame, transform: nil), nil)
                    let visible = CTFrameGetVisibleStringRange(layout)
                    guard visible.length > 0 else { throw DocumentConversionError.invalidOutput }
                    CTFrameDraw(layout, context); offset += visible.length
                    if firstPage == nil { firstPage = number; firstFrame = frame }
                    if !sourceText.isEmpty { pages[pages.count-1].regionIDs.append(id) }
                    if offset < attributed.length { try newPage() } else { top -= CTFramesetterSuggestFrameSizeWithConstraints(setter, visible, nil, frame.size, nil).height + 16 }
                }
                if !sourceText.isEmpty { regions.append(DocumentRegion(id: id, page: firstPage!, objectIDs: [], source: sourceText, bounds: firstFrame!, fontSize: fontSize, color: [0.09,0.12,0.17,1], kind: code ? "code" : "text")) }
                return
            }
            if top - needed < 44 { try newPage() }
            let frame = CGRect(x: 44, y: top-needed, width: 524, height: needed)
            CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: frame, transform: nil), nil), context)
            if !sourceText.isEmpty {
                let region = DocumentRegion(id: id, page: number, objectIDs: [], source: sourceText, bounds: frame, fontSize: fontSize, color: [0.09,0.12,0.17,1], kind: code ? "code" : "text")
                regions.append(region); pages[pages.count-1].regionIDs.append(id)
            }
            top -= needed + 10
        }
        try newPage()
        for block in source.blocks {
            try Task.checkCancellation()
            if block.kind == "image" {
                if let resource = block.resource, !resource.contains("://"), !resource.hasPrefix("/"), !resource.components(separatedBy: "/").contains("..") {
                    let url = resourceDirectory.appendingPathComponent(resource).resolvingSymlinksInPath()
                    if url.path.hasPrefix(resourceDirectory.resolvingSymlinksInPath().path + "/"), let imageSource = CGImageSourceCreateWithURL(url as CFURL, nil), let image = CGImageSourceCreateImageAtIndex(imageSource, 0, nil) {
                        let height = min(310, 524 * CGFloat(image.height)/CGFloat(image.width))
                        if top-height < 44 { try newPage() }
                        let width = height * CGFloat(image.width)/CGFloat(image.height)
                        context.draw(image, in: CGRect(x: 44, y: top-height, width: width, height: height)); top -= height + 10
                    } else { warnings.append("missingImage") }
                } else { warnings.append("remoteImageNotFetched") }
            }
            if block.kind == "table" {
                let columns = block.cells.map(\.count).max() ?? 0
                guard columns > 0, columns <= 12 else { continue }
                let width = 524 / CGFloat(columns)
                for (row, cells) in block.cells.enumerated() {
                    var rendered: [String] = []
                    for (column, cell) in cells.enumerated() {
                        let translated = source.translated(cell, id: block.id + ".r\(row)c\(column)", translations: translations)
                        rendered.append(mode == .bilingual && translated != cell ? cell + "\n" + translated : translated)
                    }
                    let height = max(32, rendered.map { value in CTFramesetterSuggestFrameSizeWithConstraints(CTFramesetterCreateWithAttributedString(DocumentPDFDrawing.attributed(value, fontSize: 12, color: [0.09,0.12,0.17,1])), CFRange(location: 0, length: 0), nil, CGSize(width: width-16, height: 2000), nil).height+16 }.max() ?? 32)
                    if height > 690 {
                        warnings.append("tableRowContinued")
                        for (column, cell) in cells.enumerated() {
                            for (piece, text) in DocumentFlowSource.pieces(cell).enumerated() {
                                let id = block.id + ".r\(row)c\(column):\(piece)", translated = translations[id] ?? text
                                if mode == .bilingual && translated != text { try draw(text, sourceText: "", id: id + ".source", fontSize: 14, prefix: "〔\(row+1) · \(column+1)〕 ") }
                                try draw(translated, sourceText: text, id: id, fontSize: 14, prefix: "〔\(row+1) · \(column+1)〕 ")
                            }
                        }
                        continue
                    }
                    if top-height < 44 { try newPage() }
                    for (column, value) in rendered.enumerated() {
                        let rect = CGRect(x: 44+CGFloat(column)*width, y: top-height, width: width, height: height)
                        context.setStrokeColor(CGColor(gray: 0.75, alpha: 1)); context.setLineWidth(0.6); context.stroke(rect)
                        if row == 0 { context.setFillColor(CGColor(gray: 0.95, alpha: 1)); context.fill(rect.insetBy(dx: 0.5, dy: 0.5)) }
                        DocumentPDFDrawing.draw(value, in: rect.insetBy(dx: 8, dy: 8), fontSize: 12, color: [0.09,0.12,0.17,1], context: context)
                        for (piece, text) in DocumentFlowSource.pieces(cells[column]).enumerated() where !text.isEmpty {
                            let id = block.id + ".r\(row)c\(column):\(piece)"
                            regions.append(DocumentRegion(id: id, page: number, objectIDs: [], source: text, bounds: rect, fontSize: 12, color: [0.09,0.12,0.17,1])); pages[pages.count-1].regionIDs.append(id)
                        }
                    }
                    top -= height
                }
                top -= 14; continue
            }
            let size: CGFloat = block.kind == "heading" ? CGFloat(max(15, 28-block.level*3)) : (block.kind == "code" ? 11 : 14)
            for (index, piece) in DocumentFlowSource.pieces(block.text).enumerated() {
                let id = block.id + ":\(index)", translated = block.kind == "code" ? piece : (translations[id] ?? piece)
                if mode == .bilingual && translated != piece { try draw(piece, sourceText: "", id: id + ".source", fontSize: size, code: block.kind == "code", prefix: index == 0 ? block.prefix : "") }
                try draw(translated, sourceText: piece, id: id, fontSize: size, code: block.kind == "code", prefix: index == 0 && block.kind != "code" ? block.prefix : "")
            }
        }
        context.endPDFPage(); context.closePDF()
        return PreparedDocument(sourceHash: "", pages: pages, regions: regions, warnings: Array(Set(warnings)).sorted())
    }
}

enum DocumentPDFDrawing {
    static func attributed(_ text: String, fontSize: CGFloat, color: [Double], code: Bool = false, markdown: Bool = false) -> NSAttributedString {
        let font = code ? NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular) : NSFont.systemFont(ofSize: fontSize)
        let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 2
        let result = NSMutableAttributedString(string: text, attributes: [.font: font, .foregroundColor: NSColor(calibratedRed: color[0], green: color[1], blue: color[2], alpha: color.count > 3 ? color[3] : 1), .paragraphStyle: paragraph])
        if markdown && !code {
            let rules: [(String, [NSAttributedString.Key: Any])] = [
                (#"\*\*(.+?)\*\*"#, [.font: NSFont.boldSystemFont(ofSize: fontSize)]),
                (#"__(.+?)__"#, [.font: NSFont.boldSystemFont(ofSize: fontSize)]),
                (#"`([^`]+)`"#, [.font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)]),
                (#"(?<!\*)\*([^*]+)\*(?!\*)"#, [.font: NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask)]),
                (#"\[([^\]]+)\]\([^\)]+\)"#, [.underlineStyle: NSUnderlineStyle.single.rawValue])
            ]
            for (pattern, attributes) in rules {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                for match in regex.matches(in: result.string, range: NSRange(location: 0, length: result.length)).reversed() {
                    let replacement = result.attributedSubstring(from: match.range(at: 1))
                    result.replaceCharacters(in: match.range, with: replacement)
                    result.addAttributes(attributes, range: NSRange(location: match.range.location, length: replacement.length))
                }
            }
        }
        return result
    }
    static func draw(_ text: String, in rect: CGRect, fontSize: CGFloat, color: [Double], context: CGContext) {
        let setter = CTFramesetterCreateWithAttributedString(attributed(text, fontSize: fontSize, color: color))
        CTFrameDraw(CTFramesetterCreateFrame(setter, CFRange(location: 0, length: 0), CGPath(rect: rect, transform: nil), nil), context)
    }
}
