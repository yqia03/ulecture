import Foundation
import AppKit
import CoreText

struct DocumentSlideNote: Codable, Equatable, Identifiable {
    var sourcePage: Int
    var text: String
    var id: Int { sourcePage }
}
struct DocumentFontReport: Codable, Equatable, Identifiable {
    var requestedFont: String
    var sourcePages: [Int]
    var renderedFonts: [String] = []
    var id: String { requestedFont }
}
struct SlideMetadata: Codable {
    var notes: [DocumentSlideNote] = []
    var missingFonts: [DocumentFontReport] = []
    var hasAnimations = false
    var hasEmbeddedMedia = false
    var warnings: [String] = []
    static func loadPPTX(_ source: URL, directory: URL) async throws -> SlideMetadata {
        let unzip = URL(fileURLWithPath: "/usr/bin/unzip")
        let listing = try await ConversionProcess.run(unzip, arguments: ["-Z1", source.path], directory: directory, resources: [], maximumOutputBytes: 2_000_000)
        let entries = String(decoding: listing, as: UTF8.self).split(separator: "\n").map(String.init)
        guard entries.count < 20000 else { throw DocumentConversionError.tooLarge }
        let slidePattern = try NSRegularExpression(pattern: #"^ppt/slides/slide([0-9]+)\.xml$"#)
        let notesPattern = try NSRegularExpression(pattern: #"^ppt/notesSlides/notesSlide([0-9]+)\.xml$"#)
        func page(_ entry: String, pattern: NSRegularExpression) -> Int? { guard let result = pattern.firstMatch(in: entry, range: NSRange(entry.startIndex..., in: entry)), let range = Range(result.range(at: 1), in: entry) else { return nil }; return Int(entry[range]) }
        func parse(_ entry: String) async throws -> SlideXML {
            let bytes = try await ConversionProcess.run(unzip, arguments: ["-p", source.path, entry], directory: directory, resources: [], maximumOutputBytes: 8_000_000)
            let delegate = SlideXML(), parser = XMLParser(data: bytes); parser.shouldResolveExternalEntities = false; parser.delegate = delegate
            guard parser.parse() else { throw DocumentConversionError.invalidDocument }
            return delegate
        }
        let presentation = try await parse("ppt/presentation.xml"), relationships = try await parse("ppt/_rels/presentation.xml.rels")
        guard presentation.slideIDs.count <= 400 else { throw DocumentConversionError.tooLarge }
        var slideOrder: [String: Int] = [:]
        for (index, id) in presentation.slideIDs.enumerated() {
            if let target = relationships.relationships[id] { slideOrder[URL(fileURLWithPath: target).lastPathComponent] = index + 1 }
        }
        var result = SlideMetadata(), fonts: [String: Set<Int>] = [:], notes: [String: String] = [:], noteLinks: [String: Int] = [:]
        result.hasEmbeddedMedia = entries.contains { $0.hasPrefix("ppt/media/") && !["png", "jpg", "jpeg", "gif", "svg", "emf", "wmf", "tif", "tiff", "bmp"].contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }
        for entry in entries {
            let slide = page(entry, pattern: slidePattern), note = page(entry, pattern: notesPattern)
            let relationship = entry.hasPrefix("ppt/slides/_rels/slide") && entry.hasSuffix(".xml.rels")
            guard slide != nil || note != nil || relationship else { continue }
            let delegate = try await parse(entry)
            if slide != nil {
                guard let page = slideOrder[URL(fileURLWithPath: entry).lastPathComponent] else { throw DocumentConversionError.invalidDocument }
                result.hasAnimations = result.hasAnimations || delegate.animation
                for font in delegate.fonts where !font.hasPrefix("+") && !availableInConverter(font) { fonts[font, default: []].insert(page) }
            } else if note != nil, !delegate.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                notes[URL(fileURLWithPath: entry).lastPathComponent] = delegate.text
            } else if relationship {
                let slideName = URL(fileURLWithPath: entry).lastPathComponent.replacingOccurrences(of: ".rels", with: "")
                if let page = slideOrder[slideName] { for target in delegate.notesTargets { noteLinks[URL(fileURLWithPath: target).lastPathComponent] = page } }
            }
        }
        for (name, text) in notes {
            if let page = noteLinks[name] { result.notes.append(DocumentSlideNote(sourcePage: page, text: text)) }
            else { result.warnings.append("notesMappingUnavailable") }
        }
        result.notes.sort { $0.sourcePage < $1.sourcePage }
        result.missingFonts = fonts.keys.sorted().map { DocumentFontReport(requestedFont: $0, sourcePages: fonts[$0]!.sorted()) }
        return result
    }
    private static func availableInConverter(_ name: String) -> Bool {
        guard NSFont(name: name, size: 12) != nil else { return false }
        let font = CTFontCreateWithName(name as CFString, 12, nil)
        guard let url = CTFontCopyAttribute(font, kCTFontURLAttribute) as? URL else { return false }
        let path = url.resolvingSymlinksInPath().path
        return path.hasPrefix("/System/") || path.hasPrefix("/Library/Fonts/")
    }
}
private final class SlideXML: NSObject, XMLParserDelegate {
    var fonts = Set<String>(), notesTargets: [String] = [], text = "", animation = false
    var slideIDs: [String] = [], relationships: [String: String] = [:]
    private var collecting = false, skipShape = false, skipField = false, placeholder = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String]) {
        if elementName == "p:sldId", let id = attributeDict["r:id"] { slideIDs.append(id) }
        if elementName == "Relationship", let id = attributeDict["Id"], let target = attributeDict["Target"], attributeDict["TargetMode"] != "External" { relationships[id] = target }
        if let face = attributeDict["typeface"], !face.isEmpty { fonts.insert(face) }
        if elementName == "p:timing" || elementName == "p:transition" { animation = true }
        if elementName == "Relationship", attributeDict["Type"]?.hasSuffix("/notesSlide") == true, attributeDict["TargetMode"] != "External", let target = attributeDict["Target"] { notesTargets.append(target) }
        if elementName == "p:sp" { skipShape = false; placeholder = "" }
        if elementName == "p:ph" { placeholder = attributeDict["type"] ?? ""; skipShape = ["sldNum", "hdr", "ftr", "dt", "sldImg"].contains(placeholder) }
        if elementName == "a:fld" { skipField = ["slidenum", "datetime", "datetime1", "datetime2"].contains(attributeDict["type"] ?? "") }
        if elementName == "a:t" { collecting = !skipShape && !skipField }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if collecting { text += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName == "a:t" { collecting = false }
        if elementName == "a:fld" { skipField = false }
        if elementName == "a:p", !skipShape { text += "\n" }
    }
}
