import AppKit
import SwiftUI
import PDFKit
import CoreText
import AVFoundation

/// Continuous captures of production RootView, PDFKit, NSTextView and subtitle
/// views using a fictional persisted workspace. Replay data is synthetic; this
/// is product footage, never evidence of live microphone or cloud recognition.
@main @MainActor enum PromoCaptureChecks {
    struct Fixture { var course: String; var otherCourse: String; var classroom: String; var note: String; var pdf: String }
    static var model: AppModel!, window: NSWindow!, host: NSHostingView<RootView>!, output: URL!, fixture: Fixture!
    static var writer: AVAssetWriter!, input: AVAssetWriterInput!, adaptor: AVAssetWriterInputPixelBufferAdaptor!
    static var events: [[String: Any]] = [], frame = 0
    static let fps = 30, totalFrames = 75 * 30
    static func arg(_ name: String) -> String? { CommandLine.arguments.firstIndex(of: name).flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil } }
    static func fail(_ text: String) -> NSError { NSError(domain: "PromoCaptureChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { do { try await run(); exit(0) } catch { print("FAIL: \(error.localizedDescription)"); exit(1) } }
        NSApplication.shared.run()
    }
    static func text(_ value: String, x: CGFloat, y: CGFloat, size: CGFloat, color: NSColor = .black, weight: NSFont.Weight = .regular, context: CGContext) {
        context.textPosition = CGPoint(x: x, y: y)
        let attributed = NSAttributedString(string: value, attributes: [.font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color])
        CTLineDraw(CTLineCreateWithAttributedString(attributed), context)
    }
    static func pdf(_ url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 720, height: 920)
        guard let c = CGContext(url as CFURL, mediaBox: &box, nil) else { throw fail("Could not create fictional PDF") }
        let pages: [(String, String, [(String, String)])] = [
            ("学习如何发生", "HOW LEARNING HAPPENS", [("01  注意", "把有限的注意力放在关键问题上。"), ("02  理解", "把新信息与已有知识建立联系。"), ("03  回忆", "尝试解释，比再次阅读更能发现盲点。")]),
            ("把信息变成理解", "FROM INFORMATION TO UNDERSTANDING", [("听见", "记录老师的原话，保留问题出现的语境。"), ("连接", "回到课件，为概念添加自己的例子。"), ("表达", "用自己的话写下核心观点与仍然存疑之处。")]),
            ("让学习留下线索", "LEAVE A TRAIL FOR YOUR NEXT REVIEW", [("课堂资料", "概念图、课件与参考材料"), ("学习记录", "转写原文、译文与自己的笔记"), ("下次复习", "从问题出发，回到对应材料。")])
        ]
        for (index, p) in pages.enumerated() {
            c.beginPDFPage(nil); c.setFillColor(NSColor.white.cgColor); c.fill(box)
            c.setFillColor(NSColor(white: 0.13, alpha: 1).cgColor); c.fill(CGRect(x: 0, y: 738, width: 720, height: 182))
            text("认知科学  /  虚构演示课程", x: 48, y: 868, size: 13, color: .lightGray, context: c)
            text(p.0, x: 48, y: 800, size: 37, color: .white, weight: .semibold, context: c)
            text(p.1, x: 48, y: 764, size: 11, color: .lightGray, context: c)
            for (n, row) in p.2.enumerated() {
                let y = CGFloat(645 - n * 177)
                c.setStrokeColor(NSColor(white: 0.85, alpha: 1).cgColor); c.move(to: CGPoint(x: 48, y: y - 96)); c.addLine(to: CGPoint(x: 672, y: y - 96)); c.strokePath()
                text(row.0, x: 48, y: y, size: 27, weight: .medium, context: c)
                text(row.1, x: 48, y: y - 44, size: 18, color: .darkGray, context: c)
            }
            text("ULecture  ·  演示资料，不含真实课程内容", x: 48, y: 44, size: 11, color: .gray, context: c)
            text(String(format: "%02d", index + 1), x: 645, y: 44, size: 12, color: .gray, context: c)
            c.endPDFPage()
        }; c.closePDF()
    }
    static func prepare(_ root: URL) throws -> Fixture {
        guard !FileManager.default.fileExists(atPath: root.path) else { throw fail("Use a fresh isolated demo workspace") }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = try LibraryStore(rootURL: root.appendingPathComponent("Workspace")), catalog = WorkspaceCatalog(library: library)
        try library.configureTranscriptStorage(rootURL: root.appendingPathComponent("Transcripts"))
        let course = try catalog.createCourse(title: "认知科学 · 演示课程")
        let second = try catalog.createCourse(title: "语言与表达 · 演示课程")
        let lesson = try catalog.create(kind: .classroom, title: "第一课 · 理解与记忆", parentID: course.id)
        let note = try catalog.create(kind: .note, title: "课堂笔记 · 从信息到理解", parentID: course.id)
        let source = root.appendingPathComponent("学习如何发生.pdf"); try pdf(source)
        let document = try catalog.importDocument(from: source, parentID: course.id)
        _ = try catalog.create(kind: .folder, title: "课后阅读", parentID: course.id)
        _ = try catalog.create(kind: .note, title: "表达练习", parentID: second.id)
        let store = BlockNoteStore(packageURL: try catalog.documentURL(id: note.id), noteID: note.id)
        var contents = try store.create(title: note.title)
        contents.blocks = [
            NoteBlock(kind: .heading, text: "把信息变成自己的理解", level: 1),
            NoteBlock(kind: .paragraph, text: "课堂主题：注意、理解与回忆。"),
            NoteBlock(kind: .heading, text: "三个值得记住的问题", level: 2),
            NoteBlock(kind: .list, text: "这个概念在回答什么问题？"),
            NoteBlock(kind: .list, text: "它与我已经知道的内容有什么联系？"),
            NoteBlock(kind: .list, text: "我能否不用课件解释清楚？"),
            NoteBlock(kind: .heading, text: "我的课堂记录", level: 2),
            NoteBlock(kind: .paragraph, text: "今天的关键发现："),
            NoteBlock(kind: .todo, text: "用一个生活中的例子解释工作记忆。"),
            NoteBlock(kind: .quote, text: "学习记录的价值，在于帮助下一次理解。")]
        _ = try store.save(contents)
        for id in [note.id, document.id] { try catalog.link(documentID: id, sessionID: lesson.id) }
        var record = try library.classroom(id: lesson.id)!; record.state = "ended"; record.timelineMilliseconds = 32000; try library.saveClassroom(record)
        for (index, pair) in lines.prefix(4).enumerated() { try library.saveTranscript(TranscriptRecord(id: "class-demo-\(index)", classroomID: lesson.id, epochID: "fictional", startMS: Int64(index * 7000), endMS: Int64(index * 7000 + 5000), text: pair.0, language: "en")) }
        return Fixture(course: course.id, otherCourse: second.id, classroom: lesson.id, note: note.id, pdf: document.id)
    }
    static let lines = [
        ("Learning begins with a question.", "学习，从一个问题开始。"),
        ("Connect a new idea to something you already know.", "把新观点与已有知识联系起来。"),
        ("Keep the source close while you take notes.", "记录笔记时，让资料留在身边。"),
        ("Understanding grows when we explain ideas in our own words.", "用自己的话解释，让理解逐渐清晰。"),
        ("A useful example makes an abstract idea easier to remember.", "一个恰当的例子，让抽象概念更容易记住。"),
        ("Return to the difficult parts and ask a better question.", "回到困难的地方，提出更好的问题。"),
        ("The original words preserve the context.", "原文，保留课堂语境。"),
        ("A translation offers another way into the meaning.", "译文，帮助理解另一种语言。"),
        ("Your notes bring these connections together.", "笔记，让这些联系留在一起。"),
        ("Leave a clear path for your next review.", "为下一次复习，留下清晰线索。")]
    static func navigate(_ id: String) throws {
        guard let item = model.items.first(where: { $0.id == id }) else { throw fail("Missing fictional item") }
        model.openItem(item); model.notice = nil; model.error = nil
    }
    static func pdfViews(_ view: NSView) -> [PDFView] { (view as? PDFView).map { [$0] } ?? view.subviews.flatMap(pdfViews) }
    static func textViews(_ view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews) }
    static func record(_ event: String) { events.append(["frame": frame, "seconds": Double(frame) / Double(fps), "event": event]) }
    static func setupWriter() throws {
        writer = try AVAssetWriter(outputURL: output.appendingPathComponent("actual-ui-continuous.mov"), fileType: .mov)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 1920, AVVideoHeightKey: 1080, AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 12_000_000]])
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB, kCVPixelBufferWidthKey as String: 1920, kCVPixelBufferHeightKey as String: 1080, kCVPixelBufferCGImageCompatibilityKey as String: true, kCVPixelBufferCGBitmapContextCompatibilityKey as String: true])
        writer.add(input); guard writer.startWriting() else { throw writer.error ?? fail("Writer failed") }; writer.startSession(atSourceTime: .zero)
    }
    static func image(_ view: NSView) throws -> CGImage {
        view.layoutSubtreeIfNeeded(); view.displayIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { throw fail("No native display buffer") }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        guard let image = bitmap.cgImage else { throw fail("No native frame") }; return image
    }
    static func drawNativePDFLayers(_ c: CGContext) {
        // PDFKit's tiled CALayers are not included by NSView.cacheDisplay.
        // Render the SAME PDFPage objects using PDFView's current page geometry,
        // zoom and scroll coordinates, clipped to its actual native viewport.
        let scale: CGFloat = 1.5
        func destination(_ r: CGRect) -> CGRect {
            CGRect(x: r.minX * scale, y: (host.isFlipped ? host.bounds.height - r.maxY : r.minY) * scale, width: r.width * scale, height: r.height * scale)
        }
        for view in pdfViews(host) {
            let viewport = destination(view.convert(view.bounds, to: host))
            c.saveGState(); c.clip(to: viewport)
            for page in view.visiblePages {
                let source = page.bounds(for: view.displayBox)
                let box = destination(view.convert(view.convert(source, from: page), to: host))
                c.setFillColor(NSColor.white.cgColor); c.fill(box)
                c.saveGState(); c.translateBy(x: box.minX, y: box.minY)
                c.scaleBy(x: box.width / source.width, y: box.height / source.height)
                c.translateBy(x: -source.minX, y: -source.minY); page.draw(with: view.displayBox, to: c); c.restoreGState()
            }
            c.restoreGState()
        }
    }
    static func appendFrame() async throws {
        guard let pool = adaptor.pixelBufferPool else { throw fail("Missing video pool") }
        var buffer: CVPixelBuffer?; CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        guard let buffer else { throw fail("Pixel buffer allocation failed") }
        CVPixelBufferLockBaseAddress(buffer, [])
        let c = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 1920, height: 1080, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)!
        c.interpolationQuality = .high; c.draw(try image(host), in: CGRect(x: 0, y: 0, width: 1920, height: 1080))
        drawNativePDFLayers(c)
        if let captions = model.interpretation?.subtitles, captions.isVisible, let view = captions.panel?.contentView {
            let shot = try image(view)
            // Composite the exact real native panel onto its process-owned main
            // window frame. No unrelated desktop windows enter the recording.
            let scale: CGFloat = 1.5, width = CGFloat(shot.width) / 2 * scale, height = CGFloat(shot.height) / 2 * scale
            c.draw(shot, in: CGRect(x: (1920 - width) / 2, y: 72, width: width, height: height))
        }
        if [0, 8*fps, 21*fps, 33*fps, 40*fps, 57*fps, 69*fps].contains(frame), let cg = c.makeImage() {
            let bitmap = NSBitmapImageRep(cgImage: cg)
            try bitmap.representation(using: .png, properties: [:])!.write(to: output.appendingPathComponent(String(format: "scene-%04d.png", frame)))
        }
        CVPixelBufferUnlockBaseAddress(buffer, [])
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: Int64(frame), timescale: Int32(fps))) else { throw writer.error ?? fail("Frame append failed") }
    }
    static func run() async throws {
        guard let workspacePath = arg("--ui-test-workspace"), let outputPath = arg("--capture-output"), arg("--model-cache") != nil else { throw fail("Pass isolated workspace, model cache and capture output") }
        output = URL(fileURLWithPath: outputPath); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        fixture = try prepare(URL(fileURLWithPath: workspacePath))
        let defaults = AppPreferences.shared.defaults
        guard let suite = arg("--ui-test-preferences"), suite.hasPrefix("local.ulecture.promo.") else { throw fail("Pass a dedicated promo preferences suite") }
        defer { defaults.removePersistentDomain(forName: suite) }
        model = AppModel(); model.workspaceRefreshTask?.cancel(); model.workspaceRefreshTask = nil; model.legacyLibraryURL = nil
        guard let library = model.library, let interpretation = model.interpretation, model.isTestMode else { throw fail("Actual application workspace failed") }
        model.preferences.language = "zh-Hans"; model.preferences.dark = false; model.preferences.hideSetup = true
        model.classNoteIDs[fixture.classroom] = fixture.note; model.pdfSelection[fixture.classroom] = fixture.pdf
        await interpretation.reloadSessions(); await interpretation.newSession(title: "理解与记忆 · 虚构课堂回放")
        guard let session = interpretation.selected else { throw fail("Demo session missing") }
        var state = CloudState(classID: session.id, translationUserPaused: true)
        for (index, pair) in lines.enumerated() {
            let row = TranscriptRecord(id: "interpretation-demo-\(index)", classroomID: session.id, epochID: "fictional", startMS: Int64(index * 5000), endMS: Int64(index * 5000 + 4300), text: pair.0, language: "en")
            try library.saveTranscript(row)
            let segment = CloudSegment(id: row.id, classID: row.classroomID, revision: row.revision, text: row.text, language: row.language, startMS: row.startMS, endMS: row.endMS, confirmedAt: row.confirmedAt)
            let dispatch = CloudDispatch(version: 1, configuration: CloudConfiguration(), preset: .current(for: .geminiDeveloper), sentAt: Date())
            let translation = CloudTranslation(id: "translation-demo-\(index)", segmentID: row.id, classID: session.id, sourceRevision: row.revision, targetLanguage: "zh-Hans", text: pair.1, dispatch: dispatch, savedAt: Date(), historical: true)
            state.jobs.append(CloudTranslationJob(segment: segment, targetLanguage: "zh-Hans", status: .completed, historical: true, dispatchVersion: 1, dispatches: [dispatch], translation: translation))
        }
        // Fixed authored translations are explicitly fixture content, not a
        // request to or an evaluation of any provider named in the real UI.
        try library.putRecord(collection: "cloud-state", id: session.id, ownerID: session.id, value: state)
        var sessionRecord = try library.classroom(id: session.id)!; sessionRecord.state = "ended"; sessionRecord.timelineMilliseconds = 50000; sessionRecord.translationUserPaused = true; try library.saveClassroom(sessionRecord)
        await interpretation.selectSession(session.id); interpretation.subtitles.language = "zh-Hans"
        interpretation.subtitles.update { $0.fontSize = 24; $0.sourceLines = 4; $0.translationLines = 4; $0.width = 1080; $0.red = 0.08; $0.green = 0.08; $0.blue = 0.08; $0.opacity = 0.96 }
        window = NSWindow(contentRect: CGRect(x: 20, y: 30, width: 1280, height: 720), styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.title = "ULecture"; window.titleVisibility = .hidden; window.titlebarAppearsTransparent = true; window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: RootView(model: model)); window.contentView = host; window.setContentSize(CGSize(width: 1280, height: 720)); window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true); try navigate(fixture.course)
        try await Task.sleep(nanoseconds: 500_000_000); try setupWriter()
        let typed = Array(" 把新的信息与已有知识联系起来，再用自己的话解释。")
        var noteEditor: BlockNoteEditorModel?, nativeText: NSTextView?, lastCapture = ProcessInfo.processInfo.systemUptime
        let captureStart = ProcessInfo.processInfo.systemUptime
        for index in 0..<totalFrames {
            frame = index
            switch index {
            case 0: record("Real course overview")
            case 4*fps: try navigate(fixture.otherCourse); record("Sidebar selects another course")
            case 6*fps: try navigate(fixture.pdf); record("Native PDF reader")
            case 17*fps: try navigate(fixture.note); record("Native block note editor")
            case 19*fps:
                let url = try model.workspaceCatalog!.documentURL(id: fixture.note)
                noteEditor = DocumentEditingSessions.noteEditor(at: url)
                guard let block = noteEditor?.document?.blocks.first(where: { $0.text == "今天的关键发现：" }), let native = textViews(host).first(where: { $0.identifier?.rawValue == "block-" + block.id }) else { throw fail("Actual note text input missing") }
                nativeText = native; window.makeFirstResponder(native); native.setSelectedRange(NSRange(location: (native.string as NSString).length, length: 0)); record("Native NSTextView typing")
            case 30*fps:
                guard await DocumentEditingSessions.flushAll() else { throw fail("Demo note flush failed") }
                try navigate(fixture.classroom); model.preferences.panel = "notes"; record("Course PDF and linked notes")
            case 38*fps:
                guard await DocumentEditingSessions.flushAll() else { throw fail("Demo navigation flush failed") }
                model.route = "voiceTool"; model.selectedID = nil; record("Saved independent session with source and bilingual TXT actions")
            case 45*fps:
                interpretation.subtitles.resetCaptions(); interpretation.subtitles.show(); record("Production subtitle panel: authored fixture playback begins")
            case 65*fps:
                interpretation.subtitles.hide(); record("Subtitle panel closes without changing persisted session")
            case 68*fps:
                try navigate(fixture.note); record("Return to saved native note")
            default: break
            }
            if index >= 8*fps && index < 15*fps, let pdf = pdfViews(host).first {
                let progress = Double(index - 8*fps) / Double(7*fps)
                if index < 11*fps { pdf.scaleFactor = 0.80 + 0.22 * progress }
                else if let doc = pdf.document, let page = doc.page(at: 1) { pdf.go(to: PDFDestination(page: page, at: CGPoint(x: 0, y: 900 - progress * 330))) }
            }
            if index >= 20*fps, index < 28*fps, (index - 20*fps) % 6 == 0, let nativeText {
                let character = (index - 20*fps) / 6
                if character < typed.count { nativeText.insertText(String(typed[character]), replacementRange: NSRange(location: (nativeText.string as NSString).length, length: 0)) }
            }
            if index >= 45*fps && index < 65*fps {
                let elapsed = index - 45*fps, line = elapsed / (2*fps)
                if elapsed % (2*fps) == 0 {
                    let text = lines[line].0
                    interpretation.subtitles.updateFragment(CaptionFragment(id: "playback-\(line)", revision: 1, order: Int64(line), text: String(text.prefix(max(1, text.count / 2))), state: .provisional))
                    record("Subtitle \(line) provisional at stable ID")
                }
                if elapsed % (2*fps) == 12 { interpretation.subtitles.updateFragment(CaptionFragment(id: "playback-\(line)", revision: 2, order: Int64(line), text: lines[line].0)); record("Subtitle \(line) final revision in place") }
                if elapsed % (2*fps) == 25 { interpretation.subtitles.updateFragment(CaptionFragment(id: "playback-\(line)", revision: 1, order: Int64(line), text: lines[line].1, sourceRevision: 2), translation: true); record("Subtitle \(line) authored translation arrives independently") }
            }
            await Task.yield(); try await appendFrame()
            let next = lastCapture + 1.0 / Double(fps), now = ProcessInfo.processInfo.systemUptime
            if next > now { try await Task.sleep(nanoseconds: UInt64((next - now) * 1e9)) }; lastCapture = max(next, now)
        }
        input.markAsFinished(); await writer.finishWriting(); guard writer.status == .completed else { throw writer.error ?? fail("Movie incomplete") }
        guard await model.prepareForExit() else { throw fail("Final demo save failed") }
        window.close()
        let report: [String: Any] = ["frames": totalFrames, "fps": fps, "seconds": 75, "width": 1920, "height": 1080, "captureWallSeconds": ProcessInfo.processInfo.systemUptime - captureStart, "source": "Continuous process-owned native RootView/NSTextView/SubtitlePanel frames; fictional authored course and translations. Exact native subtitle panel composited over main-window frame. PDFKit tiled layer rendered from the SAME native PDFPage objects at actual PDFView zoom/scroll coordinates and viewport.", "actualMicrophone": false, "actualCloud": false, "privateData": false, "events": events]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("capture-manifest.json"))
        print("PASS: 2250 continuous native UI frames, 75s, fictional workspace")
    }
}
