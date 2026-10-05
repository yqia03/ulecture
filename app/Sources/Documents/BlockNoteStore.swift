import Foundation
import AppKit

enum NoteBlockKind: String, Codable, CaseIterable { case heading, paragraph, list, todo, image, table, quote, code, rawMarkdown }

struct NoteBlock: Codable, Identifiable, Equatable {
    var id: String = UUID().uuidString
    var kind: NoteBlockKind
    var text: String = ""
    var richText: Data? = nil
    var level: Int = 2
    var checked: Bool = false
    var ordered: Bool = false
    var indent: Int? = nil
    var cells: [[String]] = []
    var resource: String? = nil
    var imageWidth: Double = 480
    var codeLanguage: String = ""
    var links: [DocumentPageLink] = []
    var plainText: String { kind == .table ? cells.map { $0.joined(separator: "\t") }.joined(separator: "\n") : text }
    var attributedText: NSAttributedString {
        if let richText, let value = NoteRichText.decode(richText, plainText: text) { return value }
        return NSAttributedString(string: text)
    }
}

struct BlockNoteDocument: Codable, Equatable, Identifiable {
    var format: String = "ulecture-block-note"
    var formatVersion: Int = 1
    var id: String
    var title: String
    var revision: Int = 0
    var savedAt: Date = Date()
    var blocks: [NoteBlock] = []
    var legacyMarkdownHash: String? = nil
    mutating func moveBlock(_ id: String, before target: String?) {
        guard id != target, let position = blocks.firstIndex(where: { $0.id == id }) else { return }
        let block = blocks.remove(at: position)
        let destination = target.flatMap { target in blocks.firstIndex { $0.id == target } } ?? blocks.count
        blocks.insert(block, at: destination)
    }
    var markdown: String {
        blocks.map { block in
            let content: String
            let inline = NoteRichText.markdown(block)
            switch block.kind {
            case .heading: content = String(repeating: "#", count: min(6, max(1, block.level))) + " " + inline
            case .paragraph: content = inline
            case .rawMarkdown: content = block.text
            case .list: content = String(repeating: "  ", count: block.indent ?? 0) + (block.ordered ? "1. " : "- ") + inline.replacingOccurrences(of: "\n", with: "\n  ")
            case .todo: content = String(repeating: "  ", count: block.indent ?? 0) + (block.checked ? "- [x] " : "- [ ] ") + inline
            case .quote: content = inline.components(separatedBy: "\n").map { "> " + $0 }.joined(separator: "\n")
            case .code:
                let fence = block.text.contains("```") ? "````" : "```"
                content = fence + block.codeLanguage + "\n" + block.text + "\n" + fence
            case .image: content = "![" + block.text.replacingOccurrences(of: "]", with: "\\]") + "](" + (block.resource ?? "missing-image") + ")"
            case .table:
                let rows = block.cells.map { "| " + $0.map { $0.replacingOccurrences(of: "|", with: "\\|").replacingOccurrences(of: "\n", with: "<br>") }.joined(separator: " | ") + " |" }
                content = rows.isEmpty ? "" : ([rows[0], "| " + Array(repeating: "---", count: block.cells[0].count).joined(separator: " | ") + " |"] + rows.dropFirst()).joined(separator: "\n")
            }
            return content + block.links.map { "\n[\($0.label)](\($0.url?.absoluteString ?? ""))" }.joined()
        }.joined(separator: "\n\n")
    }
}

/// One .ulnote package is authoritative. Immutable revisions are published before note.json.
/// The hash compare prevents a stale editor from replacing external changes.
final class BlockNoteStore {
    let packageURL: URL
    let noteID: String
    private let lock: NSRecursiveLock
    private var observedHash: String?
    private var packageIdentity: String?
    private var publishedDraftCutoff = Date.distantPast
    init(packageURL: URL, noteID: String) { self.packageURL = packageURL.standardizedFileURL; self.noteID = noteID; lock = DocumentDisk.serialLock(for: packageURL) }
    private func locked<T>(_ work: () throws -> T) rethrows -> T { lock.lock(); defer { lock.unlock() }; return try work() }
    private var currentURL: URL { packageURL.appendingPathComponent("note.json") }
    private func prepare() throws {
        try DocumentDisk.writableDirectory(packageURL, create: true)
        for directory in ["revisions", "assets"] { try DocumentDisk.writableDirectory(try DocumentDisk.child(directory, in: packageURL), create: true) }
    }
    private func validate(_ document: BlockNoteDocument) throws {
        guard document.format == "ulecture-block-note", document.formatVersion == 1, !document.id.isEmpty,
              packageIdentity == nil || document.id == packageIdentity,
              document.revision >= 0, document.blocks.count <= 100_000, Set(document.blocks.map(\.id)).count == document.blocks.count else { throw DocumentFailure.invalidFormat }
        for block in document.blocks {
            guard UUID(uuidString: block.id) != nil, block.level >= 1 && block.level <= 6,
                  (0...20).contains(block.indent ?? 0),
                  block.imageWidth.isFinite && block.imageWidth > 0,
                  block.links.allSatisfy({ !$0.documentID.isEmpty && $0.page > 0 }),
                  block.cells.count <= 10_000, block.cells.allSatisfy({ $0.count <= 1_000 }) else { throw DocumentFailure.invalidFormat }
            if let resource = block.resource { _ = try resourceURL(resource) }
            if let rich = block.richText {
                guard NoteRichText.decode(rich, plainText: block.text) != nil else { throw DocumentFailure.invalidFormat }
            }
        }
    }
    func load() throws -> BlockNoteDocument {
        try locked {
            let data = try Data(contentsOf: currentURL)
            let document = try JSONDecoder().decode(BlockNoteDocument.self, from: data)
            try validate(document); packageIdentity = document.id; observedHash = DocumentDisk.hash(data)
            return document
        }
    }
    /// Source references hash the immutable file bytes, never a re-encoded floating-point date.
    func loadSnapshot() throws -> (document: BlockNoteDocument, sourceHash: String) {
        try locked {
            let current = try load(), snapshot = try revisionSnapshot(current.revision)
            guard current.id == snapshot.document.id, current.revision == snapshot.document.revision,
                  current.title == snapshot.document.title, current.blocks == snapshot.document.blocks,
                  current.legacyMarkdownHash == snapshot.document.legacyMarkdownHash else { throw DocumentFailure.conflict }
            return snapshot
        }
    }
    func revisionSnapshot(_ number: Int) throws -> (document: BlockNoteDocument, sourceHash: String) {
        try locked {
            guard number > 0 else { throw DocumentFailure.invalidFormat }
            let directory = try DocumentDisk.child("revisions", in: packageURL)
            let matches = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("\(number)-") && $0.pathExtension == "json" }
            guard matches.count == 1, let url = matches.first else { throw DocumentFailure.missingResource("Note revision \(number)") }
            let safe = try DocumentDisk.child("revisions/" + url.lastPathComponent, in: packageURL)
            let bytes = try Data(contentsOf: safe), hash = DocumentDisk.hash(bytes)
            guard url.deletingPathExtension().lastPathComponent == "\(number)-" + hash else { throw DocumentFailure.invalidFormat }
            let document = try JSONDecoder().decode(BlockNoteDocument.self, from: bytes)
            try validate(document); guard document.revision == number else { throw DocumentFailure.invalidFormat }
            return (document, hash)
        }
    }
    @discardableResult func create(title: String) throws -> BlockNoteDocument {
        try locked {
            guard !FileManager.default.fileExists(atPath: currentURL.path) else { return try load() }
            return try save(BlockNoteDocument(id: noteID, title: title, blocks: [NoteBlock(kind: .paragraph)]))
        }
    }
    @discardableResult func save(_ value: BlockNoteDocument) throws -> BlockNoteDocument {
        try locked {
            try validate(value); try prepare()
            let currentData = try FileManager.default.fileExists(atPath: currentURL.path) ? Data(contentsOf: currentURL) : nil
            guard currentData.map(DocumentDisk.hash) == observedHash else { throw DocumentFailure.conflict }
            let previous = try currentData.map { try JSONDecoder().decode(BlockNoteDocument.self, from: $0) }
            guard previous == nil || previous?.revision == value.revision else { throw DocumentFailure.conflict }
            if let previous, previous.blocks == value.blocks && previous.title == value.title && previous.legacyMarkdownHash == value.legacyMarkdownHash { publishedDraftCutoff = max(publishedDraftCutoff, value.savedAt); return previous }
            var next = value; next.revision = (previous?.revision ?? 0) + 1; next.savedAt = Date()
            let bytes = try DocumentDisk.json(next)
            let revisionURL = try DocumentDisk.child("revisions/\(next.revision)-\(DocumentDisk.hash(bytes)).json", in: packageURL)
            if !FileManager.default.fileExists(atPath: revisionURL.path) { try DocumentDisk.write(bytes, to: revisionURL, replace: false) }
            try DocumentDisk.write(bytes, to: currentURL, replace: currentData != nil)
            packageIdentity = next.id; observedHash = DocumentDisk.hash(bytes); publishedDraftCutoff = max(publishedDraftCutoff, value.savedAt)
            // A newer unsaved draft must never be removed by completion of an earlier save.
            if let draft = try recoverableDraft(), draft.blocks == next.blocks && draft.title == next.title {
                try? FileManager.default.removeItem(at: packageURL.appendingPathComponent("draft.json"))
            }
            return next
        }
    }
    func revision(_ number: Int) throws -> BlockNoteDocument {
        try revisionSnapshot(number).document
    }
    func saveDraft(_ document: BlockNoteDocument) throws {
        try locked {
            guard document.savedAt > publishedDraftCutoff else { return }
            try validate(document); try prepare()
            if let previous = try recoverableDraft(), previous.savedAt > document.savedAt { return }
            try DocumentDisk.write(DocumentDisk.json(document), to: packageURL.appendingPathComponent("draft.json"))
        }
    }
    func recoverableDraft() throws -> BlockNoteDocument? {
        try locked {
            let path = packageURL.appendingPathComponent("draft.json")
            guard FileManager.default.fileExists(atPath: path.path) else { return nil }
            let document = try DocumentDisk.read(BlockNoteDocument.self, from: path); try validate(document); return document
        }
    }
    func preserveRecovery(_ document: BlockNoteDocument) throws {
        try locked {
            try validate(document); try prepare()
            let directory = try DocumentDisk.child("recovery", in: packageURL); try DocumentDisk.writableDirectory(directory, create: true)
            try DocumentDisk.write(DocumentDisk.json(document), to: directory.appendingPathComponent(UUID().uuidString + ".json"), replace: false)
            // Reload abandons this editor's draft, but retains its complete visible content above.
            // Older detached saves must not reactivate it after the committed version is shown.
            publishedDraftCutoff = max(publishedDraftCutoff, document.savedAt)
            if let pending = try recoverableDraft(), pending.savedAt <= document.savedAt {
                try FileManager.default.removeItem(at: packageURL.appendingPathComponent("draft.json"))
                try DocumentDisk.syncDirectory(packageURL)
            }
        }
    }
    func resourceURL(_ path: String) throws -> URL {
        guard path.hasPrefix("assets/") else { throw DocumentFailure.invalidFormat }
        return try DocumentDisk.child(path, in: packageURL)
    }
    func missingResources(in document: BlockNoteDocument) -> [String] {
        document.blocks.compactMap(\.resource).filter { path in (try? resourceURL(path)).map { !FileManager.default.fileExists(atPath: $0.path) } ?? true }
    }
    func importImage(from source: URL) throws -> String {
        try locked {
            let bytes = try Data(contentsOf: source)
            guard bytes.count <= 100 * 1024 * 1024, let image = NSImage(data: bytes), image.size.width > 0, image.size.height > 0 else { throw DocumentFailure.invalidFormat }
            try prepare()
            let ext = ["png", "jpg", "jpeg", "gif", "tif", "tiff", "heic", "webp"].contains(source.pathExtension.lowercased()) ? source.pathExtension.lowercased() : "image"
            let relative = "assets/\(DocumentDisk.hash(bytes)).\(ext)"
            let target = try resourceURL(relative)
            if !FileManager.default.fileExists(atPath: target.path) { try DocumentDisk.write(bytes, to: target, replace: false) }
            guard try DocumentDisk.hash(target) == DocumentDisk.hash(bytes) else { throw DocumentFailure.invalidFormat }
            return relative
        }
    }
    @discardableResult func importMarkdown(_ bytes: Data, title: String) throws -> BlockNoteDocument {
        try locked {
            guard let text = String(data: bytes, encoding: .utf8) else { throw DocumentFailure.message("Markdown must be UTF-8; the original bytes have not been changed.") }
            if FileManager.default.fileExists(atPath: currentURL.path) {
                let existing = try load()
                guard existing.legacyMarkdownHash == DocumentDisk.hash(bytes) else { throw DocumentFailure.conflict }
                return existing
            }
            try prepare()
            let original = packageURL.appendingPathComponent("original.md")
            if FileManager.default.fileExists(atPath: original.path) {
                guard try Data(contentsOf: original) == bytes else { throw DocumentFailure.conflict }
            } else { try DocumentDisk.write(bytes, to: original, replace: false) }
            let note = BlockNoteDocument(id: noteID, title: title, blocks: MarkdownBlockImporter.blocks(text), legacyMarkdownHash: DocumentDisk.hash(bytes))
            return try save(note)
        }
    }
}

enum MarkdownBlockImporter {
    /// The immutable original is also kept. Unknown syntax remains visible as raw Markdown.
    static func blocks(_ text: String) -> [NoteBlock] {
        let lines = text.components(separatedBy: "\n")
        var result: [NoteBlock] = [], index = 0
        func cellRow(_ text: String) -> [String] {
            var value = text.trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("|") { value.removeFirst() }; if value.hasSuffix("|") { value.removeLast() }
            return value.components(separatedBy: "|").map { $0.trimmingCharacters(in: .whitespaces) }
        }
        while index < lines.count {
            let originalLine = lines[index]
            let line = originalLine.trimmingCharacters(in: .whitespaces)
            let indent = min(20, originalLine.prefix { $0 == " " || $0 == "\t" }.count / 2)
            if line.isEmpty { index += 1; continue }
            if line.hasPrefix("```") || line.hasPrefix("~~~") {
                let fence = String(line.prefix(3)); var contents: [String] = []; index += 1
                while index < lines.count && !lines[index].hasPrefix(fence) { contents.append(lines[index]); index += 1 }
                var block = NoteBlock(kind: .code, text: contents.joined(separator: "\n")); block.codeLanguage = String(line.dropFirst(3)); result.append(block)
                if index < lines.count { index += 1 }; continue
            }
            if line.contains("|"), index + 1 < lines.count, lines[index + 1].contains("---"), lines[index + 1].contains("|") {
                var block = NoteBlock(kind: .table); block.cells = [cellRow(line)]; index += 2
                while index < lines.count && lines[index].contains("|") && !lines[index].isEmpty { block.cells.append(cellRow(lines[index])); index += 1 }
                let columns = block.cells.map(\.count).max() ?? 1
                block.cells = block.cells.map { $0 + Array(repeating: "", count: columns - $0.count) }; result.append(block); continue
            }
            let heading = line.prefix { $0 == "#" }.count
            if (1...6).contains(heading), line.dropFirst(heading).hasPrefix(" ") {
                var block = NoteBlock(kind: .heading, text: String(line.dropFirst(heading + 1))); block.level = heading; result.append(block)
            } else if line.hasPrefix("- [ ] ") || line.lowercased().hasPrefix("- [x] ") {
                var block = NoteBlock(kind: .todo, text: String(line.dropFirst(6))); block.checked = line.lowercased().hasPrefix("- [x]"); block.indent = indent; result.append(block)
            } else if line.hasPrefix("- ") || line.hasPrefix("* ") {
                result.append(NoteBlock(kind: .list, text: String(line.dropFirst(2)), indent: indent))
            } else if line.hasPrefix("> ") {
                result.append(NoteBlock(kind: .quote, text: String(line.dropFirst(2))))
            } else if let range = line.range(of: #"^\d+\. "#, options: .regularExpression) {
                var block = NoteBlock(kind: .list, text: String(line[range.upperBound...])); block.ordered = true; block.indent = indent; result.append(block)
            } else {
                var paragraph = [originalLine]; index += 1
                while index < lines.count && !startsBlock(lines[index]) { paragraph.append(lines[index]); index += 1 }
                result.append(NoteBlock(kind: line.hasPrefix("<") || line.hasPrefix("![") ? .rawMarkdown : .paragraph, text: paragraph.joined(separator: "\n"))); continue
            }
            index += 1
        }
        return result.isEmpty ? [NoteBlock(kind: .paragraph)] : result.map { block in
            guard [.heading, .paragraph, .list, .todo, .quote].contains(block.kind) else { return block }
            return NoteRichText.importInline(block)
        }
    }
    private static func startsBlock(_ line: String) -> Bool {
        let text = line.trimmingCharacters(in: .whitespaces)
        return text.isEmpty || ["#", "```", "~~~", "- ", "* ", "> ", "![", "<"].contains(where: text.hasPrefix) || text.range(of: #"^\d+\. "#, options: .regularExpression) != nil
    }
}

enum NoteRichText {
    /// AppKit's RTF writer can turn Japanese U+30FB into U+00B7 under a Chinese fallback font.
    /// Secure native archives retain the exact Unicode and attributes; legacy RTF remains readable.
    static func encode(_ value: NSAttributedString) throws -> Data {
        let portable = NSMutableAttributedString(attributedString: value)
        value.enumerateAttribute(.font, in: NSRange(location: 0, length: value.length)) { entry, range, _ in
            guard let font = entry as? NSFont, font.fontName.hasPrefix("."), !font.fontName.hasPrefix(".AppleSystemUIFont") else { return }
            // Native CJK fallback aliases are not reconstructible by NSFont(name:). Store the
            // supported system-font intent; CoreText chooses the right CJK fallback on display.
            let traits = font.fontDescriptor.symbolicTraits
            var replacement = traits.contains(.monoSpace) ? NSFont.monospacedSystemFont(ofSize: font.pointSize, weight: traits.contains(.bold) ? .bold : .regular) : NSFont.systemFont(ofSize: font.pointSize, weight: traits.contains(.bold) ? .bold : .regular)
            if traits.contains(.italic) { replacement = NSFontManager.shared.convert(replacement, toHaveTrait: .italicFontMask) }
            portable.addAttribute(.font, value: replacement, range: range)
        }
        return try NSKeyedArchiver.archivedData(withRootObject: portable, requiringSecureCoding: true)
    }
    static func decode(_ data: Data, plainText: String) -> NSAttributedString? {
        let value: NSAttributedString?
        if data.starts(with: Data("bplist".utf8)) { value = try? NSKeyedUnarchiver.unarchivedObject(ofClass: NSAttributedString.self, from: data) }
        else { value = try? NSAttributedString(data: data, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil) }
        guard let value else { return nil }
        if value.string == plainText { return value }
        // The saved plain text is canonical, including for old RTF whose legacy code page was lossy.
        // Retain the original rich payload and apply its attributes over the exact saved text.
        let repaired = NSMutableAttributedString(string: plainText)
        value.enumerateAttributes(in: NSRange(location: 0, length: value.length)) { attributes, range, _ in
            let safe = NSIntersectionRange(range, NSRange(location: 0, length: repaired.length))
            if safe.length > 0 { repaired.addAttributes(attributes, range: safe) }
        }
        return repaired
    }
    static func importInline(_ block: NoteBlock) -> NoteBlock {
        guard let value = try? AttributedString(markdown: block.text, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)) else { return block }
        let rich = NSMutableAttributedString(attributedString: NSAttributedString(value))
        let range = NSRange(location: 0, length: rich.length)
        rich.addAttribute(.font, value: NSFont.systemFont(ofSize: block.kind == .heading ? CGFloat(28 - block.level * 3) : 15), range: range)
        rich.enumerateAttribute(NSAttributedString.Key("NSInlinePresentationIntent"), in: range) { value, part, _ in
            let flags = (value as? NSNumber)?.intValue ?? 0
            var font = block.kind == .heading ? NSFont.boldSystemFont(ofSize: CGFloat(28 - block.level * 3)) : .systemFont(ofSize: 15)
            if flags & 4 != 0 { font = .monospacedSystemFont(ofSize: 14, weight: .regular) }
            if flags & 2 != 0 { font = NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask) }
            if flags & 1 != 0 { font = NSFontManager.shared.convert(font, toHaveTrait: .italicFontMask) }
            rich.addAttribute(.font, value: font, range: part)
            if flags & 32 != 0 { rich.addAttribute(.strikethroughStyle, value: NSUnderlineStyle.single.rawValue, range: part) }
        }
        var result = block; result.text = rich.string
        result.richText = try? encode(rich)
        return result
    }
    static func markdown(_ block: NoteBlock) -> String {
        guard block.richText != nil else { return block.text }
        let rich = block.attributedText; var output = ""
        rich.enumerateAttributes(in: NSRange(location: 0, length: rich.length)) { attributes, range, _ in
            var text = (rich.string as NSString).substring(with: range)
            for character in ["\\", "*", "_", "[", "]", "`"] { text = text.replacingOccurrences(of: character, with: "\\" + character) }
            if let font = attributes[.font] as? NSFont {
                let traits = NSFontManager.shared.traits(of: font)
                if traits.contains(.italicFontMask) { text = "*" + text + "*" }
                if traits.contains(.boldFontMask), block.kind != .heading { text = "**" + text + "**" }
            }
            if (attributes[.underlineStyle] as? Int ?? 0) != 0 { text = "<u>" + text + "</u>" }
            if (attributes[.strikethroughStyle] as? Int ?? 0) != 0 { text = "~~" + text + "~~" }
            if let link = attributes[.link] { text = "[" + text + "](" + String(describing: link).replacingOccurrences(of: ")", with: "%29") + ")" }
            output += text
        }
        return output
    }
}
