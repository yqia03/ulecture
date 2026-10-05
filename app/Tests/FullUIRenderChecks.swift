import AppKit
import SwiftUI
import PDFKit
import CoreText

/// Renders the real application view tree in a hidden process-owned window. This is
/// layout evidence, not a desktop automation or proof of interactive acceptance.
@main @MainActor enum FullUIRenderChecks {
    struct Scene { let name: String; let itemID: String?; let route: String; let panel: String? }
    static var entries = [[String: Any]]()
    static var output: URL!
    static func argument(_ name: String) -> String? { CommandLine.arguments.firstIndex(of: name).flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil } }
    static func main() {
        let application = NSApplication.shared; application.setActivationPolicy(.prohibited)
        Task {
            do { try await run(); exit(0) }
            catch { print("FAIL: \(error.localizedDescription)"); exit(1) }
        }
        application.run()
    }
    static func pdf(_ url: URL) throws {
        var box = CGRect(x: 0, y: 0, width: 612, height: 792)
        guard let context = CGContext(url as CFURL, mediaBox: &box, nil) else { throw DocumentFailure.invalidFormat }
        for page in 1...2 {
            context.beginPDFPage(nil); context.setFillColor(NSColor.white.cgColor); context.fill(box)
            for (index, text) in ["Working memory · \(page)", "课堂资料 · 日本語の教材", "A source used for native layout verification.", "Information remains available while we reason."].enumerated() {
                context.textPosition = CGPoint(x: 40, y: 720 - index * 40)
                CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: [.font: NSFont.systemFont(ofSize: index == 0 ? 25 : 17)])), context)
            }
            context.endPDFPage()
        }; context.closePDF()
    }
    static func fixture(_ root: URL) throws -> [String: String] {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.path) else { throw DocumentFailure.message("Use a fresh isolated workspace.") }
        let first = root.appendingPathComponent("课程一 · Learning"), second = root.appendingPathComponent("Course 2 · 日本語")
        for directory in [first, second] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        try Data("# Working memory\n\n课堂笔记 · 日本語ノート\n\n- Review the evidence\n- [ ] Revisit the examples\n".utf8).write(to: first.appendingPathComponent("阅读与思考.md"))
        try Data("Plain text · 中文 · 日本語\nA real UTF-8 source document.\n".utf8).write(to: first.appendingPathComponent("Plain.txt"))
        try pdf(first.appendingPathComponent("Memory lecture.pdf")); try pdf(first.appendingPathComponent("Missing source.pdf")); try pdf(first.appendingPathComponent("Preserved source.pdf"))
        let library = try LibraryStore(rootURL: root.appendingPathComponent("Workspace")), catalog = WorkspaceCatalog(library: library)
        let course = try catalog.createCourse(title: first.lastPathComponent), otherCourse = try catalog.createCourse(title: second.lastPathComponent)
        for filename in ["阅读与思考.md", "Plain.txt", "Memory lecture.pdf", "Missing source.pdf", "Preserved source.pdf"] {
            _ = try catalog.importDocument(from: first.appendingPathComponent(filename), parentID: course.id)
        }
        try library.configureTranscriptStorage(rootURL: root.appendingPathComponent("Transcripts"))
        let session = try catalog.create(kind: .classroom, title: "English lecture · 第一节", parentID: course.id)
        let empty = try catalog.create(kind: .folder, title: "Empty folder", parentID: course.id)
        let note = try catalog.create(kind: .note, title: "完整块笔记 · Study", parentID: course.id)
        let noteStore = BlockNoteStore(packageURL: try catalog.documentURL(id: note.id), noteID: note.id)
        var document = try noteStore.create(title: note.title)
        document.blocks = [NoteBlock(kind: .heading, text: "Working memory · 工作记忆", level: 1), NoteBlock(kind: .paragraph, text: "中文・日本語・English. A native block note with persistent content."), NoteBlock(kind: .list, text: "Review evidence before drawing conclusions"), NoteBlock(kind: .todo, text: "Compare source pages", checked: true), NoteBlock(kind: .table, cells: [["Concept", "说明"], ["Working memory", "短时保持与处理"]]), NoteBlock(kind: .quote, text: "A versioned citation stays with its source."), NoteBlock(kind: .code, text: "let evidence = source.version", codeLanguage: "swift")]
        _ = try noteStore.save(document)
        let items = try library.items()
        for item in items where item.courseID == course.id && [.note, .pdf].contains(item.kind) { try catalog.link(documentID: item.id, sessionID: session.id) }
        let preservedItem = items.first { $0.title.hasPrefix("Preserved source") }!
        let preservedStore = PDFAnnotationStore(documentID: preservedItem.id, sourceURL: try catalog.documentURL(id: preservedItem.id), sidecarURL: try catalog.metadataDirectory(documentID: preservedItem.id))
        var preserved = try preservedStore.load().annotations
        preserved.annotations = [StoredPDFAnnotation(kind: .rectangle, page: 2, bounds: CGRect(x: 40, y: 510, width: 260, height: 90))]
        preserved = try preservedStore.save(preserved)
        try catalog.move(id: preservedItem.id, parentID: otherCourse.id)
        guard try catalog.linkedDocumentIDs(sessionID: session.id).contains(preservedItem.id) else { throw DocumentFailure.message("Cross-course move lost its classroom source relationship") }
        try fm.removeItem(at: catalog.documentURL(id: preservedItem.id))
        try library.saveTranscript(TranscriptRecord(id: UUID().uuidString, classroomID: session.id, epochID: UUID().uuidString, startMS: 2000, endMS: 6300, text: "Working memory helps us reason about information while we learn.", language: "en"))
        var state = try library.classroom(id: session.id)!; state.state = "ended"; state.timelineMilliseconds = 7000; state.translationUserPaused = true; try library.saveClassroom(state)
        let legacySource = SummarySource(kind: .note, entityID: note.id, version: 1, text: "Persisted historical Markdown fixture · 中文・日本語")
        let legacy = CloudSummary(snapshot: SummarySnapshot(classID: session.id, sources: [legacySource]),
            dispatch: CloudDispatch(version: 1, configuration: CloudConfiguration(provider: .openAI), preset: .current(for: .openAI), sentAt: Date()),
            claims: [SummaryClaim(text: "Historical summary fixture retained across migration.", referenceIDs: [legacySource.id])], status: "completed")
        try library.putRecord(collection: "cloud-state", id: session.id, ownerID: session.id, value: CloudState(classID: session.id, translationUserPaused: true, summaries: [legacy]))
        let missing = items.first { $0.title == "Missing source" }!
        try fm.removeItem(at: catalog.documentURL(id: missing.id))
        return ["course": course.id, "class": session.id, "note": note.id, "empty": empty.id, "preserved": preservedItem.id, "preservedHash": preserved.sourceHash,
                "pdf": items.first { $0.title == "Memory lecture.pdf" || $0.title == "Memory lecture" }!.id,
                "missing": items.first { $0.title == "Missing source.pdf" || $0.title == "Missing source" }!.id,
                "md": items.first { $0.title.hasPrefix("阅读与思考") }!.id, "txt": items.first { $0.title.hasPrefix("Plain") }!.id]
    }
    static func run() async throws {
        guard let path = argument("--ui-test-workspace"), let target = argument("--render-output"), argument("--model-cache") != nil else { throw DocumentFailure.message("Isolated workspace, model cache and render output are required.") }
        output = URL(fileURLWithPath: target); try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let ids = try fixture(URL(fileURLWithPath: path))
        let defaults = AppPreferences.shared.defaults, keys = ["interfaceLanguage", "darkAppearance", "hideSetup", "classPanel"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer { for key in keys { if let value = previous[key] ?? nil { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        let model = AppModel(); model.workspaceRefreshTask?.cancel(); model.workspaceRefreshTask = nil
        guard model.library != nil, model.isTestMode else { throw DocumentFailure.message(model.error ?? "Isolated application failed to open") }
        model.legacyLibraryURL = nil; model.preferences.hideSetup = false
        model.classNoteIDs[ids["class"]!] = ids["note"]!; model.pdfSelection[ids["class"]!] = ids["pdf"]!
        var onlineIDs: [String: String] = [:]
        if let controller = model.interpretation, let library = model.library {
            for mode in [InterpretationMode.googleOnline, .openAIOnline] {
                await controller.newSession(title: mode == .googleOnline ? "Google · Live interpretation" : "OpenAI · Live interpretation")
                await controller.setMode(mode)
                guard let id = controller.selected?.id else { throw DocumentFailure.invalidFormat }
                onlineIDs[mode.rawValue] = id
                var runtime = try library.interpretationRuntime(sessionID: id)!
                runtime.state = "paused"; runtime.startedAt = Date(); runtime.generation = 1
                try library.saveInterpretationRuntime(runtime)
                for (track, text) in [("source", "Learning improves when we connect evidence with prior knowledge."), ("translation", "将证据与已有知识联系起来，可以改善学习。") ] {
                    let caption = InterpretationCaptionRecord(sessionID: id, generation: 1, track: track, text: text, language: track == "source" ? "en" : "zh", receivedAtMS: 1200)
                    try library.saveInterpretationCaption(caption)
                }
            }
            await controller.newSession(title: "Local recognition + online text translation")
            await controller.setMode(.localSpeechText)
            onlineIDs[InterpretationMode.localSpeechText.rawValue] = controller.selected?.id
        }
        let scenes = [Scene(name: "23-interpretation-service", itemID: nil, route: "settings", panel: nil), Scene(name: "24-google-interpretation", itemID: nil, route: "voiceTool", panel: nil), Scene(name: "25-openai-interpretation", itemID: nil, route: "voiceTool", panel: nil), Scene(name: "01-setup", itemID: nil, route: "setup", panel: nil), Scene(name: "02-workspace", itemID: nil, route: "workspace", panel: nil), Scene(name: "03-course", itemID: ids["course"], route: "workspace", panel: nil), Scene(name: "04-pdf", itemID: ids["pdf"], route: "workspace", panel: nil), Scene(name: "05-block-note", itemID: ids["note"], route: "workspace", panel: nil), Scene(name: "06-markdown", itemID: ids["md"], route: "workspace", panel: nil), Scene(name: "07-text", itemID: ids["txt"], route: "workspace", panel: nil), Scene(name: "08-class-notes", itemID: ids["class"], route: "workspace", panel: "notes"), Scene(name: "09-transcript", itemID: ids["class"], route: "workspace", panel: "transcript"), Scene(name: "10-assistant", itemID: ids["class"], route: "workspace", panel: "summary"), Scene(name: "11-text-translation", itemID: nil, route: "textTool", panel: nil), Scene(name: "12-file-translation", itemID: nil, route: "fileTool", panel: nil), Scene(name: "13-interpretation", itemID: nil, route: "voiceTool", panel: nil), Scene(name: "14-settings", itemID: nil, route: "settings", panel: nil), Scene(name: "20-ai-service", itemID: nil, route: "settings", panel: nil), Scene(name: "21-text-service", itemID: nil, route: "settings", panel: nil), Scene(name: "22-document-service", itemID: nil, route: "settings", panel: nil), Scene(name: "15-trash", itemID: nil, route: "trash", panel: nil), Scene(name: "16-empty-folder", itemID: ids["empty"], route: "workspace", panel: nil), Scene(name: "17-missing-source", itemID: ids["missing"], route: "workspace", panel: nil), Scene(name: "19-preserved-source", itemID: ids["preserved"], route: "workspace", panel: nil)]
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 840), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        for language in ["zh-Hans", "zh-Hant", "en", "ja"] {
            for dark in [false, true] {
                model.preferences.language = language; model.preferences.dark = dark
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                for width in [1280, 760] {
                    let requestedPages = argument("--pages").map { Set($0.components(separatedBy: ",")) }
                    for scene in scenes where requestedPages == nil || requestedPages!.contains(scene.name) {
                        guard await DocumentEditingSessions.flushAll() else { throw DocumentFailure.message("Editor flush failed during render navigation") }
                        if scene.name == "19-preserved-source" {
                            let encoded = DocumentPageLink(documentID: ids["preserved"]!, page: 2, label: "Preserved source", sourceHash: ids["preservedHash"]!).url!
                            guard let link = DocumentPageLink.parse(encoded), link.sourceHash == ids["preservedHash"] else { throw DocumentFailure.invalidFormat }
                            DocumentNavigationState.shared.request(documentID: link.documentID, sourceHash: link.sourceHash, page: link.page)
                            model.pdfPages[link.documentID] = link.page
                        }
                        if let id = scene.itemID, let item = model.items.first(where: { $0.id == id }) { model.openItem(item) }
                        else { model.selectedID = nil; model.route = scene.route }
                        if let panel = scene.panel { model.preferences.panel = panel }
                        if scene.name == "13-interpretation", let id = onlineIDs[InterpretationMode.localSpeechText.rawValue] { await model.interpretation?.selectSession(id) }
                        if scene.name == "24-google-interpretation", let id = onlineIDs[InterpretationMode.googleOnline.rawValue] { await model.interpretation?.selectSession(id) }
                        if scene.name == "25-openai-interpretation", let id = onlineIDs[InterpretationMode.openAIOnline.rawValue] { await model.interpretation?.selectSession(id) }
                        model.notice = nil; model.error = nil
                        let content: AnyView
                        if ["20-ai-service", "21-text-service", "22-document-service"].contains(scene.name) {
                            let service = scene.name == "20-ai-service" ? model.cloudService : (scene.name == "21-text-service" ? model.textTranslationService : model.documentTranslationService)
                            let title = scene.name == "20-ai-service" ? "aiService" : (scene.name == "21-text-service" ? "textTranslationService" : "documentTranslationService")
                            content = AnyView(ScrollView { VStack(alignment: .leading, spacing: 20) {
                                Text(CloudViewText.t(title, language)).font(.title2.bold())
                                ProviderSettingsView(settings: service, language: language, allowsSharedService: scene.name != "20-ai-service")
                            }.padding(32).frame(maxWidth: 880).frame(maxWidth: .infinity) }.background(AppPalette(dark: dark).canvas).preferredColorScheme(dark ? .dark : .light))
                        } else if scene.name == "23-interpretation-service" {
                            content = AnyView(ScrollView { VStack(alignment: .leading, spacing: 20) {
                                Text(InterpretationOnlineText.text("interpretationService", language: language)).font(.title2.bold())
                                InterpretationServiceSettingsView(settings: model.interpretationService, language: language)
                            }.padding(32).frame(maxWidth: 880).frame(maxWidth: .infinity) }.background(AppPalette(dark: dark).canvas).preferredColorScheme(dark ? .dark : .light))
                        } else { content = AnyView(RootView(model: model)) }
                        let host = NSHostingView(rootView: content)
                        window.setContentSize(CGSize(width: width, height: 840)); window.contentView = host
                        host.frame = CGRect(x: 0, y: 0, width: width, height: 840)
                        if scene.name == "04-pdf" { try capture(host, name: "18-document-opening", language: language, dark: dark, width: width, note: "Immediate render before asynchronous document preparation; opening-state appearance only.") }
                        try await Task.sleep(nanoseconds: 220_000_000)
                        if scene.name == "10-assistant", model.assistant?.legacySummaries.count != 1 { throw DocumentFailure.message("The real assistant did not expose the persisted legacy summary") }
                        try capture(host, name: scene.name, language: language, dark: dark, width: width, note: "Real RootView with isolated persisted library; no user action dispatched.")
                        window.contentView = nil
                    }
                    print("Rendered \(language) \(dark ? "dark" : "light") \(width)")
                }
            }
        }
        guard model.audio.phase != .capturing, model.probe.phase != .capturing, !model.serviceSettings.credentialUnlocked else { throw DocumentFailure.message("Unexpected active service state") }
        window.close()
        let report: [String: Any] = ["suite": "FullUIRenderChecks", "images": entries, "count": entries.count, "scope": "Process-owned hidden NSHostingView renders, not desktop screenshots or interactive acceptance; no audio or real cloud requests", "limitations": ["PDFKit page layers can be blank in hidden cacheDisplay although the PDF document is loaded; use separate visible native and external Preview evidence for page content.", "Scrollable settings and long content initially show the top viewport; later sections and interactive controls need separate UI inspection.", "Opening-state images are first layout frames, not a deterministic assertion that an asynchronous operation is still pending."], "workspace": path]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("results.json"))
        print("Rendered \(entries.count) images to \(output.path)")
    }
    static func capture(_ host: NSView, name: String, language: String, dark: Bool, width: Int, note: String) throws {
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw DocumentFailure.message("No native render buffer") }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]), png.count > 3000 else { throw DocumentFailure.message("Empty native render") }
        let filename = "\(name)-\(language)-\(dark ? "dark" : "light")-\(width).png"
        try png.write(to: output.appendingPathComponent(filename))
        func pdfViews(_ view: NSView) -> [PDFView] { (view as? PDFView).map { [$0] } ?? view.subviews.flatMap(pdfViews) }
        let loadedPages = pdfViews(host).compactMap { $0.document?.pageCount }
        if ["04-pdf", "19-preserved-source"].contains(name), loadedPages != [2] { throw DocumentFailure.message("The actual PDF reader was not bound to its two-page source") }
        if name == "19-preserved-source" {
            guard let reader = pdfViews(host).first, let page = reader.currentPage, reader.document?.index(for: page) == 1,
                  reader.document?.page(at: 1)?.annotations.contains(where: { $0.type == "Square" }) == true else { throw DocumentFailure.message("The preserved source reference lost its page or annotation after cross-course move and external removal") }
        }
        entries.append(["page": name, "language": language, "theme": dark ? "dark" : "light", "width": width, "height": 840, "pixelWidth": bitmap.pixelsWide, "pixelHeight": bitmap.pixelsHigh, "bytes": png.count, "path": filename, "scope": note, "pdfPageCounts": loadedPages])
    }
}
