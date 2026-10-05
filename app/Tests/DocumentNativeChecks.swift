import AppKit
import SwiftUI
import PDFKit
import CoreText

/// Real AppKit views and editing events in an isolated fixture window. No capture or cloud services exist in this executable.
@main @MainActor enum DocumentNativeChecks {
    static var checks: [String] = []
    static var window: NSWindow!
    static let root = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "/private/tmp/ulecture-native-\(UUID().uuidString)")
    static func require(_ value: @autoclosure () throws -> Bool, _ label: String) throws { guard try value() else { throw DocumentFailure.message("FAILED: " + label) }; checks.append(label) }
    static func settle() async { try? await Task.sleep(nanoseconds: 180_000_000) }
    static func main() {
        let app = NSApplication.shared; app.setActivationPolicy(.regular)
        let menu = NSMenu(), editItem = NSMenuItem(title: "Edit", action: nil, keyEquivalent: ""), edit = NSMenu(title: "Edit")
        for (title, action, key) in [("Undo", "undo:", "z"), ("Redo", "redo:", "Z"), ("Cut", "cut:", "x"), ("Copy", "copy:", "c"), ("Paste", "paste:", "v"), ("Select All", "selectAll:", "a")] {
            let item = NSMenuItem(title: title, action: NSSelectorFromString(action), keyEquivalent: key); item.target = nil; edit.addItem(item)
        }
        menu.addItem(NSMenuItem(title: "ULectureEditorChecks", action: nil, keyEquivalent: "")); menu.addItem(editItem); editItem.submenu = edit; app.mainMenu = menu
        window = NSWindow(contentRect: CGRect(x: 100, y: 70, width: 1000, height: 820), styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        window.title = "ULecture Editor Verification"; window.makeKeyAndOrderFront(nil); app.activate(ignoringOtherApps: true)
        Task {
            var failure: String?
            do { try await run() } catch { failure = error.localizedDescription }
            report(error: failure)
            if !CommandLine.arguments.contains("--interactive") { exit(failure == nil ? 0 : 1) }
        }
        app.run()
    }
    static func textViews(_ view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews) }
    static func run() async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let package = root.appendingPathComponent("Native.ulnote"), noteID = UUID().uuidString
        let store = BlockNoteStore(packageURL: package, noteID: noteID)
        var note = try store.create(title: "原生编辑 · Native note")
        note.blocks = [NoteBlock(kind: .paragraph, text: "Original paragraph"), NoteBlock(kind: .heading, text: "Title"), NoteBlock(kind: .list, text: "List item"), NoteBlock(kind: .todo, text: "Task"), NoteBlock(kind: .quote, text: "Quote"), NoteBlock(kind: .code, text: "let value = 42"), NoteBlock(kind: .table, cells: [["A", "B"], ["1", "2"]])]
        note = try store.save(note)
        let host = NSHostingView(rootView: BlockNoteEditor(packageURL: package, noteID: noteID, title: note.title, language: "zh-Hans"))
        window.contentView = host; await settle(); await settle(); host.layoutSubtreeIfNeeded()
        guard let text = textViews(host).first(where: { $0.identifier?.rawValue == "block-" + note.blocks[0].id }) else { throw DocumentFailure.message("Native block text view was not installed") }
        try require(text.bounds.width > 100 && text.bounds.height >= 20, "native block text layout has usable size")
        window.makeFirstResponder(text)
        text.setSelectedRange(NSRange(location: 0, length: (text.string as NSString).length))
        text.setMarkedText("zhongwen", selectedRange: NSRange(location: 8, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        _ = await DocumentEditingSessions.flushAll()
        try require(try BlockNoteStore(packageURL: package, noteID: noteID).load().blocks[0].text == "Original paragraph", "unfinished IME marked text is not committed to note content")
        text.insertText("中文输入・日本語", replacementRange: text.markedRange())
        await settle()
        guard await DocumentEditingSessions.flushAll() else {
            if let value = DocumentEditingSessions.noteEditor(at: package)?.document {
                try JSONEncoder().encode(value).write(to: root.appendingPathComponent("failed-visible-note.json"))
                for block in value.blocks where block.richText != nil { print("RTF comparison", block.text.debugDescription, block.attributedText.string.debugDescription) }
            }
            throw DocumentFailure.message("Native IME committed text could not be saved: " + (DocumentEditingSessions.noteEditor(at: package)?.error ?? "unknown save failure"))
        }
        var saved = try BlockNoteStore(packageURL: package, noteID: noteID).load()
        try require(saved.blocks[0].text == "中文输入・日本語", "native IME composition commits intact and persists")
        text.setSelectedRange(NSRange(location: 0, length: 4))
        NotificationCenter.default.post(name: .ulBlockFormat, object: note.blocks[0].id, userInfo: ["action": "bold"])
        await settle(); _ = await DocumentEditingSessions.flushAll()
        saved = try BlockNoteStore(packageURL: package, noteID: noteID).load()
        let font = saved.blocks[0].attributedText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        try require(font.map { NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true, "native formatting writes real rich text")
        text.undoManager?.undo(); await settle(); _ = await DocumentEditingSessions.flushAll()
        saved = try BlockNoteStore(packageURL: package, noteID: noteID).load()
        let undone = saved.blocks[0].attributedText.attribute(.font, at: 0, effectiveRange: nil) as? NSFont
        try require(undone.map { !NSFontManager.shared.traits(of: $0).contains(.boldFontMask) } == true, "native rich text undo persists reverted attributes")
        text.undoManager?.redo(); await settle()
        text.setSelectedRange(NSRange(location: (text.string as NSString).length, length: 0))
        for number in 0..<80 { text.insertText(" \(number)", replacementRange: NSRange(location: NSNotFound, length: 0)) }
        let expected = text.string
        window.contentView = NSView(); await settle(); _ = await DocumentEditingSessions.flushAll()
        try require(try BlockNoteStore(packageURL: package, noteID: noteID).load().blocks[0].text == expected, "rapid native typing survives immediate workspace departure")
        await settle(); await settle()
        let lateDraft = try BlockNoteStore(packageURL: package, noteID: noteID).recoverableDraft()
        try require(lateDraft == nil || lateDraft?.blocks[0].text == expected, "late asynchronous draft cannot resurrect text preceding the committed save")

        let failurePackage = root.appendingPathComponent("Failure.ulnote")
        let failureEditor = BlockNoteEditorModel(packageURL: failurePackage, noteID: UUID().uuidString)
        await failureEditor.load(title: "Fictional recovery", language: "en")
        let failureBlock = failureEditor.document!.blocks[0].id
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: failurePackage.path)
        for revision in 0..<100 { failureEditor.edit(failureBlock, { $0.text = "Latest visible revision \(revision)" }, recordUndo: false) }
        let failedFlush = await failureEditor.flush()
        try require(!failedFlush && failureEditor.state == "saveFailed" && failureEditor.error != nil, "coalesced draft write failure is visible and blocks a successful flush")
        try require(failureEditor.document?.blocks[0].text == "Latest visible revision 99", "write failure retains the newest burst revision in memory")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: failurePackage.path)
        let repaired = await failureEditor.flush()
        let recoveredNote = try failureEditor.store.load()
        try require(repaired && recoveredNote.blocks[0].text == "Latest visible revision 99", "repair flush persists the newest coalesced revision before returning success")

        let source = root.appendingPathComponent("Original.pdf"); try makePDF(source)
        let originalHash = try DocumentDisk.hash(source)
        let model = PDFEditorModel(documentID: "native-pdf", sourceURL: source, sidecarURL: root.appendingPathComponent("annotations"), page: 1)
        await model.load()
        guard let pdf = model.pdf, let page = pdf.page(at: 0) else { throw DocumentFailure.invalidFormat }
        let view = AnnotationPDFView(frame: CGRect(x: 0, y: 0, width: 1000, height: 820)); view.editor = model; view.observe(); view.displayMode = .singlePage; view.document = pdf; view.fitWidth = false; view.scaleFactor = 0.85
        window.contentView = view; await settle(); view.layoutDocumentView()
        for (number, tool) in [PDFEditorTool.ink, .freeText, .stickyNote, .rectangle, .ellipse, .arrow].enumerated() {
            model.tool = tool
            let start = CGPoint(x: 80, y: 625 - number * 65), end = CGPoint(x: 245, y: 600 - number * 65)
            view.mouseDown(with: event(.leftMouseDown, start, in: view, page: page))
            view.mouseDragged(with: event(.leftMouseDragged, end, in: view, page: page))
            view.mouseUp(with: event(.leftMouseUp, end, in: view, page: page))
            view.render(model.archive!)
            await settle()
        }
        for tool in [PDFEditorTool.highlight, .underline, .strikeOut] {
            model.tool = tool; view.currentSelection = page.selection(for: NSRange(location: 0, length: 8)); view.commitMarkup(); view.render(model.archive!); await settle()
        }
        try require(Set(model.archive!.annotations.map(\.kind)) == Set(AnnotationKind.allCases), "native mouse and text-selection paths create all nine annotation kinds")
        // Changing selection must not replace PDFKit objects for saved content.
        let preservedAnnotation = page.annotations.first { $0.value(forAnnotationKey: .name) as? String == model.archive!.annotations[0].id }!
        for item in model.archive!.annotations.prefix(4) { model.selectedID = item.id; view.render(model.archive!) }
        try require(page.annotations.contains { $0 === preservedAnnotation }, "selection preserves saved native annotations instead of rebuilding all content")
        model.selectedID = nil; view.render(model.archive!)
        try require(!page.annotations.contains { $0.value(forAnnotationKey: .name) as? String == "ul-preview-selection" }, "deselection removes the previous outline without orphan overlays")
        model.tool = .select
        let rectangle = model.archive!.annotations.first { $0.kind == .rectangle }!
        let before = rectangle.bounds
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: before.midX, y: before.midY), in: view, page: page))
        view.mouseDragged(with: event(.leftMouseDragged, CGPoint(x: before.midX + 25, y: before.midY + 18), in: view, page: page))
        view.mouseUp(with: event(.leftMouseUp, CGPoint(x: before.midX + 25, y: before.midY + 18), in: view, page: page))
        let moved = model.archive!.annotations.first { $0.id == rectangle.id }!.bounds
        try require(abs(moved.minX - before.minX - 25) < 0.01 && abs(moved.minY - before.minY - 18) < 0.01, "native drag transforms viewport coordinates to stable PDF page coordinates")
        await settle()
        model.undo.undo(); try require(model.archive!.annotations.first { $0.id == rectangle.id }?.bounds == before, "annotation drag undo restores geometry")
        model.undo.redo(); view.render(model.archive!)
        model.rotate(); view.render(model.archive!); view.scaleFactor = 1.15; view.layoutDocumentView(); await settle()
        model.tool = .ellipse
        let rotateStart = CGPoint(x: 280, y: 400), rotateEnd = CGPoint(x: 365, y: 455)
        view.mouseDown(with: event(.leftMouseDown, rotateStart, in: view, page: page)); view.mouseDragged(with: event(.leftMouseDragged, rotateEnd, in: view, page: page)); view.mouseUp(with: event(.leftMouseUp, rotateEnd, in: view, page: page))
        let rotated = model.archive!.annotations.last!
        try require(abs(rotated.bounds.minX - 280) < 0.01 && abs(rotated.bounds.minY - 400) < 0.01, "native annotation geometry stays correct after zoom and page rotation")
        let count = model.archive!.annotations.count; model.tool = .eraser; view.render(model.archive!)
        view.mouseDown(with: event(.leftMouseDown, CGPoint(x: rotated.bounds.midX, y: rotated.bounds.midY), in: view, page: page)); view.mouseUp(with: event(.leftMouseUp, CGPoint(x: rotated.bounds.midX, y: rotated.bounds.midY), in: view, page: page))
        try require(model.archive!.annotations.count == count - 1, "native eraser removes hit annotation")
        model.undo.undo(); _ = await model.flush()
        try require(try DocumentDisk.hash(source) == originalHash, "native editing and save never mutate source PDF")
        let reopened = try model.store.load()
        try require(reopened.annotations.annotations == model.archive!.annotations && reopened.document.page(at: 0)?.rotation == 90, "native edits and rotated reading state survive reopen")
        try model.store.export(model.archive!, to: root.appendingPathComponent("Native-annotated.pdf"))
        try model.store.export(model.archive!, to: root.appendingPathComponent("Native-flattened.pdf"), flattened: true)
        let fixedArchive = model.archive!, fixedAnnotation = model.archive!.annotations[0]
        var currentAnnotation = fixedAnnotation; currentAnnotation.text = "Newer annotation content"
        model.replace(currentAnnotation); guard await model.flush() else { throw DocumentFailure.conflict }
        await model.load(version: originalHash, annotationRevision: fixedArchive.revision, annotationID: fixedAnnotation.id)
        try require(model.readOnly && model.selected?.text == fixedAnnotation.text && model.archive?.revision == fixedArchive.revision, "native annotation reference selects the exact immutable revision as read-only")
        model.remove([fixedAnnotation.id]); try require(model.archive?.annotations.contains { $0.id == fixedAnnotation.id } == true, "historical annotation edit attempts cannot mutate the cited version")
        await model.load()
        window.contentView = NSHostingView(rootView: HSplitView {
            AnnotatedPDFEditor(documentID: "native-pdf", sourceURL: source, sidecarURL: root.appendingPathComponent("annotations"), language: "zh-Hans").frame(minWidth: 500)
            BlockNoteEditor(packageURL: package, noteID: noteID, title: note.title, language: "zh-Hans", currentPageLink: DocumentPageLink(documentID: "native-pdf", page: 1, label: "Original", sourceHash: originalHash)).frame(minWidth: 400)
        })
        await settle()
    }
    static func event(_ type: NSEvent.EventType, _ point: CGPoint, in view: PDFView, page: PDFPage) -> NSEvent {
        let location = view.convert(view.convert(point, from: page), to: nil)
        return NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
    }
    static func report(error: String?) {
        let report: [String: Any] = ["checks": checks, "passed": checks.count, "error": error as Any? ?? NSNull(), "scope": "Real native text-input and PDF mouse events; simulated IME composition protocol; physical keyboard/IME and external Preview visibility are separate"]
        let data = try! JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]); try? data.write(to: root.appendingPathComponent("native-checks.json")); print(String(decoding: data, as: UTF8.self))
    }
    static func makePDF(_ url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792); guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw DocumentFailure.invalidFormat }
        context.beginPDFPage(nil); context.setFillColor(NSColor.white.cgColor); context.fill(box)
        let line = CTLineCreateWithAttributedString(NSAttributedString(string: "Original lecture page · 日本語 · 中文", attributes: [.font: NSFont.systemFont(ofSize: 18)]))
        context.textPosition = CGPoint(x: 35, y: 735); CTLineDraw(line, context); context.endPDFPage(); context.closePDF()
    }
}
