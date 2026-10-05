import Foundation
import AppKit
import PDFKit
import CoreText

@main enum DocumentEditingChecks {
    static var checks: [String] = []
    static func require(_ condition: @autoclosure () throws -> Bool, _ label: String) throws {
        guard try condition() else { throw DocumentFailure.message("FAILED: " + label) }
        checks.append(label)
    }
    static func rejects(_ label: String, _ operation: () throws -> Void) throws {
        do { try operation() } catch { checks.append(label); return }
        throw DocumentFailure.message("FAILED: accepted " + label)
    }
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/private/tmp/ulecture-documents-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let noteURL = root.appendingPathComponent("Study.ulnote")
        let noteID = UUID().uuidString
        let store = BlockNoteStore(packageURL: noteURL, noteID: noteID)
        let original = "# 中文の見出し\n\n**bold** and [page](uway-pdf://ABC?page=2)\n\n- [x] done\n\n| A | B |\n| --- | --- |\n| 1 | 2 |\n\n```swift\nlet x = 1\n```\n\n<custom preserve=\"yes\">raw</custom>\n"
        var note = try store.importMarkdown(Data(original.utf8), title: "Study")
        try require(try Data(contentsOf: noteURL.appendingPathComponent("original.md")) == Data(original.utf8), "Markdown migration preserves exact original bytes")
        try require(note.blocks.contains { $0.kind == .heading } && note.blocks.contains { $0.kind == .todo } && note.blocks.contains { $0.kind == .table } && note.blocks.contains { $0.kind == .code }, "Markdown creates actual typed blocks")
        try require(note.blocks.contains { $0.text.contains("<custom") }, "unknown Markdown is retained")
        note.blocks = NoteBlockKind.allCases.map { NoteBlock(kind: $0, text: "Text \($0.rawValue)") }
        note.blocks[note.blocks.firstIndex { $0.kind == .table }!].cells = [["A", "B"], ["1", "2"]]
        let imageURL = root.appendingPathComponent("diagram.png")
        let image = NSImage(size: NSSize(width: 32, height: 32)); image.lockFocus(); NSColor.systemBlue.setFill(); NSRect(x: 0, y: 0, width: 32, height: 32).fill(); image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        try bitmap.representation(using: .png, properties: [:])!.write(to: imageURL)
        let resource = try store.importImage(from: imageURL)
        note.blocks[note.blocks.firstIndex { $0.kind == .image }!].resource = resource
        note.blocks[0].links = [DocumentPageLink(documentID: "stable-document", page: 3, label: "Source")]
        let rich = NSAttributedString(string: "Bold 日本語", attributes: [.font: NSFont.boldSystemFont(ofSize: 17)])
        note.blocks[0].text = rich.string
        note.blocks[0].richText = try rich.data(from: NSRange(location: 0, length: rich.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        note = try store.save(note)
        let reopened = try BlockNoteStore(packageURL: noteURL, noteID: noteID).load()
        try require(reopened.blocks == note.blocks && reopened.revision == note.revision, "all block kinds, rich text, table, image and links survive reopen")
        let sourceSnapshot = try store.loadSnapshot()
        try require(sourceSnapshot.document == note && sourceSnapshot.sourceHash == DocumentDisk.hash(Data(contentsOf: noteURL.appendingPathComponent("note.json"))), "note source snapshot hashes the exact immutable bytes matching the loaded content")
        let exactCJK = NSAttributedString(string: "中文输入・日本語🙂", attributes: [.font: NSFont.systemFont(ofSize: 15)])
        let exactRich = try NoteRichText.encode(exactCJK)
        try require(NoteRichText.decode(exactRich, plainText: exactCJK.string)?.string == exactCJK.string, "native rich archive retains exact CJK punctuation and emoji Unicode")
        let lossyLegacy = NSAttributedString(string: "中文输入·日本語", attributes: [.font: NSFont.boldSystemFont(ofSize: 15)])
        let legacyRTF = try lossyLegacy.data(from: NSRange(location: 0, length: lossyLegacy.length), documentAttributes: [.documentType: NSAttributedString.DocumentType.rtf])
        try require(NoteRichText.decode(legacyRTF, plainText: "中文输入・日本語")?.string == "中文输入・日本語", "legacy lossy RTF renders canonical saved text while retaining rich formatting")
        let previousIDs = note.blocks.map(\.id)
        note.moveBlock(previousIDs.last!, before: previousIDs.first!)
        note = try store.save(note)
        try require(try store.load().blocks.first?.id == previousIDs.last, "block reorder persists stable identity")
        try require(try store.revision(note.revision - 1).blocks.map(\.id) == previousIDs, "previous immutable note revision remains readable")
        var draft = note; draft.blocks[0].text = "unsaved recovery text"; draft.blocks[0].richText = nil
        try store.saveDraft(draft)
        try require(try store.recoverableDraft()?.blocks[0].text == "unsaved recovery text", "draft survives store reopen")
        let external = BlockNoteStore(packageURL: noteURL, noteID: noteID)
        var outside = try external.load(); outside.title = "External edit"; _ = try external.save(outside)
        try rejects("external edit cannot be overwritten by stale editor") { _ = try store.save(draft) }
        try require(try external.load().title == "External edit", "conflict preserves external content")
        try store.preserveRecovery(draft)
        try store.saveDraft(draft)
        let reloadedNote = BlockNoteStore(packageURL: noteURL, noteID: noteID)
        try require(try reloadedNote.recoverableDraft() == nil && reloadedNote.load().title == "External edit", "explicit note reload retires the abandoned draft across reopen and delayed draft completion")
        let recoveryFiles = try FileManager.default.contentsOfDirectory(at: noteURL.appendingPathComponent("recovery"), includingPropertiesForKeys: nil)
        try require(try recoveryFiles.contains { try DocumentDisk.read(BlockNoteDocument.self, from: $0).blocks == draft.blocks }, "explicit note reload preserves every visible unsaved block in immutable recovery")
        try rejects("unsafe resource traversal is rejected") { _ = try store.resourceURL("../escape.png") }
        let markdown = try external.load().markdown
        try require(markdown.contains("stable-document") && markdown.contains("```"), "readable export retains links and code blocks")
        let importedIdentity = try BlockNoteStore(packageURL: noteURL, noteID: UUID().uuidString).load()
        try require(importedIdentity.id == note.id, "external note package keeps its internal identity under a new catalog document ID")
        let inline = MarkdownBlockImporter.blocks("paragraph\n- **bold**\n  1. child\n> quote")
        try require(inline.map(\.kind) == [.paragraph, .list, .list, .quote] && inline[2].indent == 1 && inline[1].text == "bold", "adjacent and nested Markdown blocks parse with real inline formatting")
        let mdExport = root.appendingPathComponent("Export.md")
        try BlockNoteExporter.markdown(note, store: store, to: mdExport)
        let exportedMD = try String(contentsOf: mdExport)
        try require(exportedMD.contains("-assets-") && (try FileManager.default.contentsOfDirectory(atPath: root.path)).contains { $0.hasPrefix("Export-assets-") }, "Markdown export copies package image resources with portable references")
        let notePDF = root.appendingPathComponent("Note.pdf")
        try BlockNoteExporter.pdf(note, store: store, to: notePDF)
        try require(PDFDocument(url: notePDF)?.string?.contains("Bold 日本語") == true, "note PDF export contains readable rich text and real pages")
        let textURL = root.appendingPathComponent("Encoded.txt")
        try "UTF16 中文".data(using: .utf16)!.write(to: textURL)
        let textStore = TextDocumentStore(documentID: "text-id", sourceURL: textURL, draftURL: root.appendingPathComponent("text-draft.json"))
        let textLoaded = try textStore.load()
        _ = try textStore.save(textLoaded.0 + " 日本語")
        try require(try String(contentsOf: textURL, encoding: .utf16) == "UTF16 中文 日本語", "text editing preserves original UTF16 encoding and all characters")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: textURL.path)
        _ = try textStore.save("Private 中文")
        try require((try FileManager.default.attributesOfItem(atPath: textURL.path)[.posixPermissions] as? NSNumber)?.intValue == 0o600, "atomic text save preserves private file permissions")
        try Data("External".utf8).write(to: textURL)
        try rejects("external text replacement cannot be silently overwritten") { _ = try textStore.save("stale") }
        let earlierDraft = TextDocumentDraft(documentID: "text-id", baseHash: textLoaded.1, text: "Earlier pending text", updatedAt: Date(timeIntervalSinceNow: -1))
        let abandoned = TextDocumentDraft(documentID: "text-id", baseHash: textLoaded.1, text: "Visible unsaved 中文", updatedAt: Date())
        try textStore.saveDraft(earlierDraft)
        _ = try textStore.preserveRecoveryAndReload(abandoned)
        try textStore.saveDraft(abandoned)
        try textStore.saveDraft(earlierDraft)
        try require(try textStore.load().0 == "External" && textStore.load().2 == nil, "text reload retires abandoned drafts and blocks late asynchronous resurrection")
        let textRecoveries = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("draft-preserved-") }
        try require(try textRecoveries.contains { try DocumentDisk.read(TextDocumentDraft.self, from: $0).text == abandoned.text }, "text reload preserves visible unsaved text even without a successful prior draft save")
        let stableBytes = try Data(contentsOf: noteURL.appendingPathComponent("note.json"))
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: noteURL.path)
        var denied = try external.load(); denied.title = "Cannot save"
        try rejects("read-only note package reports save failure") { _ = try external.save(denied) }
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: noteURL.path)
        try require(try Data(contentsOf: noteURL.appendingPathComponent("note.json")) == stableBytes, "failed note save leaves committed data intact")
        let raceURL = root.appendingPathComponent("Concurrent.ulnote")
        _ = try BlockNoteStore(packageURL: raceURL, noteID: "race").create(title: "Start")
        let raceStores = [BlockNoteStore(packageURL: raceURL, noteID: "race"), BlockNoteStore(packageURL: raceURL, noteID: "race")]
        let versions = try raceStores.map { try $0.load() }, group = DispatchGroup(), resultLock = NSLock()
        var successes = 0
        for index in 0..<2 {
            group.enter(); DispatchQueue.global().async {
                var value = versions[index]; value.title = "Writer \(index)"
                if (try? raceStores[index].save(value)) != nil { resultLock.lock(); successes += 1; resultLock.unlock() }; group.leave()
            }
        }; group.wait()
        try require(successes == 1, "two simultaneous editors cannot both replace the same observed note revision")
        let oldLink = URL(string: "uway-pdf://LEGACY?page=4")!, newLink = DocumentPageLink(documentID: "current", page: 2, label: "Page", sourceHash: String(repeating: "a", count: 64))
        try require(DocumentPageLink.parse(oldLink)?.page == 4 && newLink.url.flatMap(DocumentPageLink.parse)?.sourceHash == newLink.sourceHash, "legacy and version-pinned page links round-trip")
        let pdfURL = root.appendingPathComponent("Source.pdf")
        try makePDF(pdfURL, pages: 2)
        let originalHash = try DocumentDisk.hash(pdfURL)
        let reference = try NotePageReference.prepare(documentID: "standalone-reference", title: "Lecture", pdfURL: pdfURL, sidecarURL: root.appendingPathComponent("reference-sidecar"))
        try require(reference.link(page: 2)?.sourceHash == originalHash && reference.link(page: 0) == nil && reference.link(page: 3) == nil, "standalone note page selection binds the exact preserved PDF version and validates page bounds")
        let pdfStore = PDFAnnotationStore(documentID: "stable-document", sourceURL: pdfURL, sidecarURL: root.appendingPathComponent("annotations"))
        var loaded = try pdfStore.load()
        var archive = loaded.annotations
        for (index, kind) in AnnotationKind.allCases.enumerated() {
            let rect = CGRect(x: 30 + index * 4, y: 50 + index * 55, width: 180, height: 30)
            var annotation = StoredPDFAnnotation(kind: kind, page: 1, bounds: rect, text: "中文 annotation \(index)")
            if kind == .ink { annotation.ink = [CGPoint(x: rect.minX, y: rect.minY), CGPoint(x: rect.midX, y: rect.maxY), CGPoint(x: rect.maxX, y: rect.minY)] }
            archive.annotations.append(annotation)
        }
        archive = try pdfStore.save(archive)
        loaded = try PDFAnnotationStore(documentID: "stable-document", sourceURL: pdfURL, sidecarURL: root.appendingPathComponent("annotations")).load()
        try require(loaded.annotations.annotations == archive.annotations, "all PDF annotation types reopen with page coordinates")
        let exportURL = root.appendingPathComponent("Annotated.pdf")
        try pdfStore.export(archive, to: exportURL)
        let exported = PDFDocument(url: exportURL)!
        let visibleAnnotations = exported.page(at: 0)!.annotations.filter { $0.type != "Popup" }
        try require(Set(visibleAnnotations.compactMap(\.type)) == Set(["Highlight", "Underline", "StrikeOut", "Ink", "FreeText", "Text", "Square", "Circle", "Line"]), "standard PDF export contains every annotation subtype")
        try require(visibleAnnotations.allSatisfy { $0.shouldDisplay && $0.shouldPrint }, "exported annotations are visible and printable")
        let flattened = root.appendingPathComponent("Flattened.pdf")
        try pdfStore.export(archive, to: flattened, flattened: true)
        try require(PDFDocument(url: flattened)?.pageCount == 2, "flattened PDF output reopens")
        try require(try DocumentDisk.hash(pdfURL) == originalHash, "annotation edits and exports preserve original PDF bytes")
        var moved = archive.annotations[0]; let old = moved.bounds; moved.translate(dx: 30, dy: -15)
        try require(moved.bounds == old.offsetBy(dx: 30, dy: -15), "moving annotation uses page coordinates")
        archive.viewRotations["1"] = 90; archive = try pdfStore.save(archive)
        try require(try pdfStore.load().document.page(at: 0)?.rotation == 90, "view rotation persists independently of original PDF")
        var pdfDraft = archive; pdfDraft.annotations[0].text = "Unsaved local annotation"; pdfDraft.savedAt = Date()
        try pdfStore.saveDraft(pdfDraft)
        let outsidePDF = PDFAnnotationStore(documentID: "stable-document", sourceURL: pdfURL, sidecarURL: root.appendingPathComponent("annotations"))
        _ = try outsidePDF.load()
        var externalPDF = archive; externalPDF.annotations[0].text = "Committed external annotation"; externalPDF = try outsidePDF.save(externalPDF)
        let conflict = try pdfStore.load()
        try require(conflict.draftConflict && conflict.annotations.annotations[0].text == "Unsaved local annotation", "conflicting PDF draft remains visible instead of silently disappearing")
        try rejects("recovered old PDF draft cannot replace a newer annotation revision") { _ = try pdfStore.save(conflict.annotations) }
        try pdfStore.export(conflict.annotations, to: root.appendingPathComponent("Recovered-copy.pdf"))
        try pdfStore.preserveRecovery(conflict.annotations)
        archive = try pdfStore.load().annotations
        try require(archive.annotations[0].text == externalPDF.annotations[0].text && PDFDocument(url: root.appendingPathComponent("Recovered-copy.pdf")) != nil,
                    "explicit PDF reload preserves draft recovery and export while reopening committed annotations")
        let fixedAnnotations = try pdfStore.load(version: originalHash, annotationRevision: 1)
        try require(fixedAnnotations.historicalRevision && fixedAnnotations.annotations.revision == 1 && fixedAnnotations.annotations.annotations[0].text == "中文 annotation 0", "annotation reference opens its immutable revision instead of the current annotation text")
        try makePDF(pdfURL, pages: 1)
        let changed = try pdfStore.load()
        try require(changed.annotations.annotations.isEmpty && changed.historicalHashes.contains(originalHash), "external PDF replacement does not project old annotations onto new pages")
        try require(try pdfStore.load(version: originalHash).annotations.annotations.count == AnnotationKind.allCases.count, "old PDF and editable annotations remain available after external replacement")
        var target = changed.annotations
        try pdfStore.reassociate(archive.annotations[0], to: 1, in: &target)
        try require(target.annotations[0].id != archive.annotations[0].id && target.annotations[0].page == 1, "explicit page reassociation preserves original annotation")
        try rejects("annotation export never replaces an existing file") { try pdfStore.export(archive, to: exportURL) }
        let missingSource = root.appendingPathComponent("Source-moved.pdf")
        try FileManager.default.moveItem(at: pdfURL, to: missingSource)
        try require(try pdfStore.load(version: originalHash).document.pageCount == 2, "pinned PDF version remains readable after external source deletion")
        let report: [String: Any] = ["suite": "DocumentEditingChecks", "passed": checks.count, "checks": checks, "directory": root.path, "scope": "Real note, source text, annotation and exported files; external-reader and interactive UI checks are separate; no network, microphone or sound"]
        let data = try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("document-editing-checks.json"))
        print(String(decoding: data, as: UTF8.self))
    }
    static func makePDF(_ url: URL, pages: Int) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw DocumentFailure.invalidFormat }
        for page in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(NSColor.white.cgColor); context.fill(box)
            let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Original PDF source page \(page + 1)", attributes: [.font: NSFont.systemFont(ofSize: 20)]))
            context.textPosition = CGPoint(x: 32, y: 730); CTLineDraw(line, context); context.endPDFPage()
        }
        context.closePDF()
    }
}
