import Foundation
import AppKit
import CoreText
import PDFKit

enum BlockNoteExporter {
    /// Publish the resource directory before the Markdown; a failed copy never leaves a successful document.
    static func markdown(_ note: BlockNoteDocument, store: BlockNoteStore, to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        var export = note
        let resources = Set(note.blocks.compactMap(\.resource))
        let folder = destination.deletingLastPathComponent().appendingPathComponent(destination.deletingPathExtension().lastPathComponent + "-assets-" + UUID().uuidString.prefix(8))
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".note-export-" + UUID().uuidString)
        var published = false
        defer { try? FileManager.default.removeItem(at: stage); if !published && !resources.isEmpty { try? FileManager.default.removeItem(at: folder) } }
        if !resources.isEmpty {
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false)
            for resource in resources {
                let source = try store.resourceURL(resource), copy = stage.appendingPathComponent(source.lastPathComponent)
                let hash = try DocumentDisk.hash(source)
                try FileManager.default.copyItem(at: source, to: copy)
                guard try DocumentDisk.hash(copy) == hash else { throw DocumentFailure.conflict }
            }
            try FileManager.default.moveItem(at: stage, to: folder)
            for index in export.blocks.indices {
                if let resource = export.blocks[index].resource {
                    let relative = folder.lastPathComponent + "/" + URL(fileURLWithPath: resource).lastPathComponent
                    export.blocks[index].resource = relative.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? relative
                }
            }
        }
        try DocumentDisk.write(Data(export.markdown.utf8), to: destination, replace: false); published = true
    }

    static func pdf(_ note: BlockNoteDocument, store: BlockNoteStore?, to destination: URL) throws {
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw CocoaError(.fileWriteFileExists) }
        let bytes = NSMutableData()
        var pageBox = CGRect(x: 0, y: 0, width: 595, height: 842)
        guard let consumer = CGDataConsumer(data: bytes as CFMutableData), let context = CGContext(consumer: consumer, mediaBox: &pageBox, [kCGPDFContextTitle: note.title] as CFDictionary) else { throw DocumentFailure.invalidFormat }
        let margin: CGFloat = 44, width: CGFloat = 507
        var top: CGFloat = 798, page = 0
        func begin() {
            if page > 0 { context.endPDFPage() }
            context.beginPDFPage(nil); page += 1; top = 798
            let footer = NSAttributedString(string: "\(page)", attributes: [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.gray])
            context.textPosition = CGPoint(x: 286, y: 22); CTLineDraw(CTLineCreateWithAttributedString(footer), context)
        }
        func text(_ value: NSAttributedString, x: CGFloat = 44, availableWidth: CGFloat = 507, gap: CGFloat = 10) throws {
            guard value.length > 0 else { top -= gap; return }
            let mutable = NSMutableAttributedString(attributedString: value)
            mutable.addAttribute(.foregroundColor, value: NSColor.black, range: NSRange(location: 0, length: mutable.length))
            let paragraph = NSMutableParagraphStyle(); paragraph.lineSpacing = 3; paragraph.paragraphSpacing = 5
            mutable.addAttribute(.paragraphStyle, value: paragraph, range: NSRange(location: 0, length: mutable.length))
            let framesetter = CTFramesetterCreateWithAttributedString(mutable)
            var offset = 0
            while offset < mutable.length {
                if top < margin + 24 { begin() }
                let path = CGPath(rect: CGRect(x: x, y: margin, width: availableWidth, height: top - margin), transform: nil)
                let frame = CTFramesetterCreateFrame(framesetter, CFRange(location: offset, length: 0), path, nil)
                let range = CTFrameGetVisibleStringRange(frame)
                guard range.length > 0 else { throw DocumentFailure.message("Text could not fit on an output page.") }
                CTFrameDraw(frame, context)
                let lines = CTFrameGetLines(frame) as! [CTLine]
                var origins = [CGPoint](repeating: .zero, count: lines.count)
                CTFrameGetLineOrigins(frame, CFRange(location: 0, length: 0), &origins)
                if let last = lines.last, let origin = origins.last { var descent: CGFloat = 0; CTLineGetTypographicBounds(last, nil, &descent, nil); top = margin + origin.y - descent - gap }
                offset += range.length
                if offset < mutable.length { begin() }
            }
        }
        begin()
        if !note.title.isEmpty { try text(NSAttributedString(string: note.title, attributes: [.font: NSFont.boldSystemFont(ofSize: 23)]), gap: 18) }
        for block in note.blocks {
            switch block.kind {
            case .image:
                guard let resource = block.resource, let store, let image = NSImage(contentsOf: try store.resourceURL(resource)), let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else { throw DocumentFailure.missingResource(block.resource ?? "image") }
                let imageWidth = min(width, min(CGFloat(block.imageWidth), CGFloat(cg.width)))
                let imageHeight = imageWidth * CGFloat(cg.height) / CGFloat(cg.width)
                let scale = min(1, 720 / imageHeight), drawnWidth = imageWidth * scale, drawnHeight = imageHeight * scale
                if top - drawnHeight < margin { begin() }
                context.draw(cg, in: CGRect(x: margin, y: top - drawnHeight, width: drawnWidth, height: drawnHeight)); top -= drawnHeight + 9
                if !block.text.isEmpty { try text(NSAttributedString(string: block.text, attributes: [.font: NSFont.systemFont(ofSize: 11)])) }
            case .table:
                // Cell boundaries remain explicit and wrap across pages rather than clipping long cells.
                for (row, cells) in block.cells.enumerated() {
                    let line = cells.enumerated().map { "\($0.offset + 1): \($0.element)" }.joined(separator: "     │     ")
                    try text(NSAttributedString(string: line, attributes: [.font: row == 0 ? NSFont.boldSystemFont(ofSize: 12) : NSFont.systemFont(ofSize: 12)]), gap: 7)
                    context.setStrokeColor(NSColor.lightGray.cgColor); context.setLineWidth(0.5); context.move(to: CGPoint(x: margin, y: top + 3)); context.addLine(to: CGPoint(x: margin + width, y: top + 3)); context.strokePath()
                }; top -= 7
            default:
                let value = NSMutableAttributedString(attributedString: block.attributedText)
                if block.richText == nil {
                    let font: NSFont = block.kind == .heading ? .boldSystemFont(ofSize: CGFloat(26 - block.level * 2)) : block.kind == .code || block.kind == .rawMarkdown ? .monospacedSystemFont(ofSize: 10.5, weight: .regular) : .systemFont(ofSize: 12)
                    value.addAttribute(.font, value: font, range: NSRange(location: 0, length: value.length))
                }
                let prefix = block.kind == .list ? (block.ordered ? "1. " : "• ") : block.kind == .todo ? (block.checked ? "☑ " : "☐ ") : block.kind == .quote ? "❝ " : ""
                if !prefix.isEmpty { value.insert(NSAttributedString(string: prefix, attributes: [.font: NSFont.systemFont(ofSize: 12)]), at: 0) }
                let indent = CGFloat(block.indent ?? 0) * 12
                try text(value, x: margin + indent, availableWidth: width - indent)
            }
            for link in block.links { try text(NSAttributedString(string: "↗ " + link.label + " · \(link.page)", attributes: [.font: NSFont.systemFont(ofSize: 10)]), gap: 7) }
        }
        context.endPDFPage(); context.closePDF()
        guard let reopened = PDFDocument(data: bytes as Data), reopened.pageCount == page else { throw DocumentFailure.invalidFormat }
        try DocumentDisk.write(bytes as Data, to: destination, replace: false)
    }
}
