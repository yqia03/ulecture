import SwiftUI
import AppKit
import PDFKit

enum PDFEditorTool: String, CaseIterable {
    case read, select, highlight, underline, strikeOut, ink, eraser, freeText, stickyNote, rectangle, ellipse, arrow
    var annotationKind: AnnotationKind? { AnnotationKind(rawValue: rawValue) }
    var symbol: String {
        switch self {
        case .read: return "text.cursor"
        case .select: return "cursorarrow"
        case .highlight: return "highlighter"
        case .underline: return "underline"
        case .strikeOut: return "strikethrough"
        case .ink: return "pencil.tip"
        case .eraser: return "eraser"
        case .freeText: return "textformat"
        case .stickyNote: return "note.text"
        case .rectangle: return "rectangle"
        case .ellipse: return "circle"
        case .arrow: return "arrow.up.right"
        }
    }
    var isMarkup: Bool { self == .highlight || self == .underline || self == .strikeOut }
}

@MainActor final class PDFEditorModel: ObservableObject, DocumentEditingSession {
    @Published var pdf: PDFDocument?
    @Published var archive: PDFAnnotationDocument?
    @Published var state = "loading"
    @Published var error: String?
    @Published var page = 1
    @Published var tool: PDFEditorTool = .read
    @Published var color = Color.yellow
    @Published var lineWidth: Double = 2
    @Published var fontSize: Double = 15
    @Published var insertionText = ""
    @Published var selectedID: String?
    @Published var currentHash = ""
    @Published var historicalHashes: [String] = []
    @Published var zoom: CGFloat = 0
    @Published var actualScale: CGFloat = 1
    @Published var readOnly = false
    @Published var historicalRevision = false
    let store: PDFAnnotationStore
    let undo = UndoManager()
    var onSave: ((PDFAnnotationDocument) -> Void)?
    private var debounce: Task<Void, Never>?
    private var saving = false
    private var generation = 0
    private var conflict = false
    private var pinnedSourceHash: String?
    init(documentID: String, sourceURL: URL, sidecarURL: URL, page: Int) {
        store = PDFAnnotationStore(documentID: documentID, sourceURL: sourceURL, sidecarURL: sidecarURL); self.page = page
        undo.groupsByEvent = false
        DocumentEditingSessions.register(self)
    }
    var selected: StoredPDFAnnotation? { archive?.annotations.first { $0.id == selectedID } }
    @discardableResult func load(version: String? = nil, annotationRevision: Int? = nil, annotationID: String? = nil) async -> Bool {
        if archive != nil, !(await flush()) { return false }
        do {
            let store = self.store
            let loaded = try await Task.detached { try store.load(version: version, annotationRevision: annotationRevision) }.value
            archive = loaded.annotations; pdf = loaded.document; currentHash = loaded.currentHash; historicalHashes = loaded.historicalHashes
            pinnedSourceHash = version
            DocumentNavigationState.shared.currentHashes[store.documentID] = loaded.annotations.sourceHash
            conflict = loaded.draftConflict
            state = conflict ? "saveFailed" : loaded.recoveredDraft ? "saving" : "saved"; error = conflict ? DocumentFailure.conflict.localizedDescription : nil; historicalRevision = loaded.historicalRevision; readOnly = historicalRevision
            selectedID = annotationID.flatMap { id in loaded.annotations.annotations.contains { $0.id == id } ? id : nil }; undo.removeAllActions()
            if readOnly { tool = .read }
            if let annotationID, selectedID == nil { error = DocumentFailure.missingResource("Annotation " + annotationID).localizedDescription }
            page = max(1, min(page, loaded.document.pageCount)); zoom = 0
            return true
        } catch {
            self.error = error.localizedDescription; state = "saveFailed"
            // A read-only project still permits reading, while editing remains explicitly disabled.
            if pdf == nil { let url = store.sourceURL; pdf = await Task.detached { PDFDocument(url: url) }.value; readOnly = true }
            return false
        }
    }
    func checkExternalChange() async {
        guard !historicalRevision else { return }
        let url = store.sourceURL
        guard let hash = try? await Task.detached(operation: { try DocumentDisk.hash(url) }).value, hash != currentHash else { return }
        await load(version: pinnedSourceHash)
    }
    func mutate(_ title: String, _ operation: (inout PDFAnnotationDocument) -> Void) {
        guard !readOnly, var next = archive else { return }
        let previous = next
        operation(&next); guard next != previous else { return }
        let group = !undo.isUndoing && !undo.isRedoing
        if group { undo.beginUndoGrouping() }
        undo.registerUndo(withTarget: self) { target in MainActor.assumeIsolated { target.restore(previous) } }; undo.setActionName(title)
        if group { undo.endUndoGrouping() }
        next.savedAt = Date(); archive = next; generation += 1; state = "saving"; schedule()
    }
    private func restore(_ previous: PDFAnnotationDocument) { mutate("Edit annotation") { $0.annotations = previous.annotations; $0.viewRotations = previous.viewRotations } }
    func add(_ annotations: [StoredPDFAnnotation]) { guard !annotations.isEmpty else { return }; mutate("Add annotation") { $0.annotations += annotations }; selectedID = annotations.last?.id }
    func replace(_ annotation: StoredPDFAnnotation) { mutate("Edit annotation") { if let index = $0.annotations.firstIndex(where: { $0.id == annotation.id }) { $0.annotations[index] = annotation } } }
    func remove(_ ids: Set<String>) { mutate("Delete annotation") { $0.annotations.removeAll { ids.contains($0.id) } }; if ids.contains(selectedID ?? "") { selectedID = nil } }
    func updateSelected(_ operation: (inout StoredPDFAnnotation) -> Void) { if var value = selected { operation(&value); replace(value) } }
    func rotate() { mutate("Rotate view") { $0.viewRotations[String(page)] = (($0.viewRotations[String(page)] ?? 0) + 90) % 360 } }
    private func schedule() {
        debounce?.cancel()
        if let snapshot = archive { let store = self.store; Task.detached { try? store.saveDraft(snapshot) } }
        debounce = Task { try? await Task.sleep(nanoseconds: 300_000_000); guard !Task.isCancelled else { return }; debounce = nil; _ = await flush() }
    }
    func flush() async -> Bool {
        debounce?.cancel(); debounce = nil
        while saving { await Task.yield() }
        guard !readOnly else { return true }
        guard state != "saved", let snapshot = archive else { return pdf != nil }
        guard !conflict else { return false }
        saving = true; let start = generation
        do {
            let store = self.store
            let saved = try await Task.detached { try store.saveDraft(snapshot); return try store.save(snapshot) }.value
            archive?.revision = saved.revision; if generation == start { archive?.savedAt = saved.savedAt }; saving = false; error = nil
            state = generation == start ? "saved" : "saving"; onSave?(saved)
            if generation != start { return await flush() }; return true
        } catch { self.error = error.localizedDescription; state = "saveFailed"; saving = false; return false }
    }
    func export(to url: URL, flattened: Bool) async {
        guard await flush(), let snapshot = archive else { return }
        do { let store = self.store; try await Task.detached { try store.export(snapshot, to: url, flattened: flattened) }.value }
        catch { self.error = error.localizedDescription }
    }
    func saveCopy(to url: URL) async {
        guard let snapshot = archive else { return }
        do { let store = self.store; try await Task.detached { try store.export(snapshot, to: url) }.value }
        catch { self.error = error.localizedDescription }
    }
    func reloadPreservingChanges() async {
        debounce?.cancel(); while saving { await Task.yield() }
        guard let snapshot = archive else { await load(); return }
        do {
            let store = self.store
            try await Task.detached { try store.preserveRecovery(snapshot) }.value
            archive = nil; conflict = false; await load(version: snapshot.sourceHash)
        } catch { self.error = error.localizedDescription; state = "saveFailed" }
    }
    func reassociateSelected(to page: Int) async {
        guard let annotation = selected, await flush() else { return }
        guard await load(), !historicalRevision, let current = archive,
              !currentHash.isEmpty, current.sourceHash == currentHash else { return }
        do {
            let store = self.store, start = generation
            let updated = try await Task.detached {
                var target = current
                try store.reassociate(annotation, to: page, in: &target)
                return target.annotations
            }.value
            guard generation == start, archive?.sourceHash == current.sourceHash,
                  archive?.revision == current.revision else { throw DocumentFailure.conflict }
            mutate("Reassociate annotation") { $0.annotations = updated }; self.page = page
        } catch { self.error = error.localizedDescription }
    }
}

struct AnnotatedPDFEditor: View {
    @StateObject private var editor: PDFEditorModel
    let language: String
    let initialPage: Int
    let navigationRequest: PDFNavigationRequest?
    let onSelection: (DocumentSelection) -> Void
    let onPage: (Int) -> Void
    let onSave: (PDFAnnotationDocument) -> Void
    @State private var targetPage = 1
    @State private var showReassociate = false
    init(documentID: String, sourceURL: URL, sidecarURL: URL, initialPage: Int = 1, language: String = "en", navigationRequest: PDFNavigationRequest? = nil,
         onSelection: @escaping (DocumentSelection) -> Void = { _ in }, onPage: @escaping (Int) -> Void = { _ in }, onSave: @escaping (PDFAnnotationDocument) -> Void = { _ in }) {
        _editor = StateObject(wrappedValue: PDFEditorModel(documentID: documentID, sourceURL: sourceURL, sidecarURL: sidecarURL, page: initialPage))
        self.language = language; self.initialPage = initialPage; self.navigationRequest = navigationRequest; self.onSelection = onSelection; self.onPage = onPage; self.onSave = onSave
    }
    private func t(_ key: String) -> String { EditorText.get(key, language) }
    var body: some View {
        VStack(spacing: 0) {
            tools
            navigation
            if editor.historicalRevision {
                HStack { Text(t("annotationHistory") + " · \(editor.archive?.revision ?? 0)"); Spacer(); Button(t("currentVersion")) { Task { await editor.load(version: editor.archive?.sourceHash) } } }.font(.caption).padding(9).background(Color.accentColor.opacity(0.08))
            }
            if let hash = editor.archive?.sourceHash, hash != editor.currentHash {
                Text(t("oldVersion") + " · " + String(hash.prefix(12))).font(.caption).frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 12).padding(.bottom, 6)
            }
            if !editor.historicalHashes.isEmpty { Text(t("versionWarning")).font(.caption).foregroundStyle(.secondary).padding(.horizontal, 12).padding(.bottom, 7) }
            if let pdf = editor.pdf {
                NativeAnnotationPDF(document: pdf, editor: editor, language: language, onSelection: onSelection)
            } else {
                VStack(spacing: 12) { if let error = editor.error { Text(EditorText.failure(error, language)).textSelection(.enabled); Button(t("reload")) { Task { await editor.load() } } } else { ProgressView(t("loading")) } }.padding().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            if editor.selected != nil { inspector }
            EditorStatusBar(state: editor.state, error: editor.error, language: language) { Task { _ = await editor.flush() } }
            if editor.state == "saveFailed", editor.archive != nil {
                HStack {
                    Button(t("reload")) { Task { await editor.reloadPreservingChanges() } }
                    Button(t("saveCopy")) {
                        let panel = NSSavePanel(); panel.nameFieldStringValue = editor.store.sourceURL.deletingPathExtension().lastPathComponent + " annotated copy.pdf"
                        if panel.runModal() == .OK, let url = panel.url { Task { await editor.saveCopy(to: url) } }
                    }
                }.controlSize(.small).padding(8)
            }
        }.background(Color(nsColor: .textBackgroundColor))
            .task { editor.onSave = onSave; await editor.load(version: navigationRequest?.sourceHash, annotationRevision: navigationRequest?.annotationRevision, annotationID: navigationRequest?.annotationID); if let request = navigationRequest { editor.page = max(1, min(request.page, editor.pdf?.pageCount ?? 1)) } }
            .onChange(of: editor.page) { _, value in onPage(value) }
            .onChange(of: initialPage) { _, value in if value > 0 && value <= (editor.pdf?.pageCount ?? 0) { editor.page = value } }
            .onChange(of: navigationRequest) { _, request in if let request { Task { await editor.load(version: request.sourceHash, annotationRevision: request.annotationRevision, annotationID: request.annotationID); editor.page = max(1, min(request.page, editor.pdf?.pageCount ?? 1)) } } }
            .onDisappear { Task { _ = await editor.flush() } }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in Task { await editor.checkExternalChange() } }
            .popover(isPresented: $showReassociate) {
                VStack(alignment: .leading, spacing: 14) { Text(t("reassociate")).frame(maxWidth: 320); TextField(t("page"), value: $targetPage, formatter: NumberFormatter()).frame(width: 90); Button(t("done")) { showReassociate = false; Task { await editor.reassociateSelected(to: targetPage) } } }.padding(20)
            }
    }
    private var tools: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 3) {
                ForEach(PDFEditorTool.allCases, id: \.self) { tool in
                    Button { editor.tool = tool } label: { Image(systemName: tool.symbol).frame(width: 24, height: 26).background(editor.tool == tool ? Color.accentColor.opacity(0.14) : .clear).clipShape(RoundedRectangle(cornerRadius: 5)) }
                        .buttonStyle(.plain).help(t(tool.rawValue)).accessibilityLabel(t(tool.rawValue)).disabled(editor.readOnly && tool != .read)
                }
                Divider().frame(height: 20)
                ColorPicker(t("color"), selection: $editor.color, supportsOpacity: true).labelsHidden().frame(width: 28)
                Slider(value: $editor.lineWidth, in: 0.5...14).frame(width: 64).help(t("width"))
                Button { editor.undo.undo() } label: { Image(systemName: "arrow.uturn.backward") }.help(t("undo")).accessibilityLabel(t("undo"))
                Button { editor.undo.redo() } label: { Image(systemName: "arrow.uturn.forward") }.help(t("redo")).accessibilityLabel(t("redo"))
            }.padding(.horizontal, 9).padding(.vertical, 7).controlSize(.small)
        }.frame(height: 42)
    }
    private var navigation: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                Button { editor.page = max(1, editor.page - 1) } label: { Image(systemName: "chevron.left") }.disabled(editor.page <= 1)
                TextField(t("page"), value: $editor.page, formatter: NumberFormatter()).frame(width: 35).textFieldStyle(.roundedBorder)
                Text("/ \(editor.pdf?.pageCount ?? 0)").font(.caption)
                Button { editor.page = min(editor.pdf?.pageCount ?? 1, editor.page + 1) } label: { Image(systemName: "chevron.right") }.disabled(editor.page >= (editor.pdf?.pageCount ?? 1))
                Button { editor.zoom = max(0.05, editor.actualScale - 0.15) } label: { Image(systemName: "minus.magnifyingglass") }
                Button { editor.zoom = min(8, editor.actualScale + 0.15) } label: { Image(systemName: "plus.magnifyingglass") }
                Button(t("fit")) { editor.zoom = 0 }
                Button { editor.rotate() } label: { Image(systemName: "rotate.right") }.help(t("rotate")).accessibilityLabel(t("rotate"))
                Menu(t("export")) { Button(t("annotatedPDF")) { export(false) }; Button(t("flattenedPDF")) { export(true) } }.disabled(editor.readOnly)
                if !editor.historicalHashes.isEmpty {
                    Menu(t("oldVersion")) {
                        Button(t("currentVersion")) { Task { await editor.load() } }
                        ForEach(editor.historicalHashes, id: \.self) { hash in Button(String(hash.prefix(12))) { Task { await editor.load(version: hash) } } }
                    }
                }
            }.controlSize(.small).padding(.horizontal, 10).padding(.bottom, 8)
        }.frame(height: 36)
    }
    private var inspector: some View {
        HStack(spacing: 8) {
            if let value = editor.selected {
                Image(systemName: PDFEditorTool(rawValue: value.kind.rawValue)?.symbol ?? "pencil")
                if value.kind == .freeText || value.kind == .stickyNote {
                    TextField(t("annotationText"), text: Binding(get: { editor.selected?.text ?? "" }, set: { text in editor.updateSelected { $0.text = text } }), axis: .vertical).lineLimit(1...4).textFieldStyle(.roundedBorder)
                    Stepper(value: Binding(get: { editor.selected?.fontSize ?? 15 }, set: { size in editor.updateSelected { $0.fontSize = size } }), in: 7...72) { Text("\(Int(value.fontSize))").font(.caption) }.frame(width: 68)
                }
                ColorPicker(t("color"), selection: Binding(get: { Color(value.color.nsColor) }, set: { color in editor.updateSelected { $0.color = AnnotationColor(NSColor(color)) } })).labelsHidden().frame(width: 26)
                Slider(value: Binding(get: { value.lineWidth }, set: { width in editor.updateSelected { $0.lineWidth = width } }), in: 0.5...14).frame(width: 80)
                Button { editor.remove([value.id]) } label: { Image(systemName: "trash") }.help(t("delete")).accessibilityLabel(t("delete"))
                if editor.archive?.sourceHash != editor.currentHash { Button { targetPage = editor.page; showReassociate = true } label: { Image(systemName: "arrow.right.doc.on.clipboard") }.help(t("reassociate")).accessibilityLabel(t("reassociate")) }
                Spacer(minLength: 0)
            }
        }.controlSize(.small).padding(9).background(Color.secondary.opacity(0.05))
    }
    private func export(_ flattened: Bool) {
        let panel = NSSavePanel(); panel.nameFieldStringValue = editor.store.sourceURL.deletingPathExtension().lastPathComponent + (flattened ? "-flattened.pdf" : "-annotated.pdf")
        if panel.runModal() == .OK, let url = panel.url { Task { await editor.export(to: url, flattened: flattened) } }
    }
}

private struct NativeAnnotationPDF: NSViewRepresentable {
    let document: PDFDocument
    @ObservedObject var editor: PDFEditorModel
    let language: String
    let onSelection: (DocumentSelection) -> Void
    func makeNSView(context: Context) -> AnnotationPDFView {
        let view = AnnotationPDFView(); view.displayMode = .singlePageContinuous; view.displayDirection = .vertical; view.autoScales = false
        view.minScaleFactor = 0.05; view.maxScaleFactor = 8; view.backgroundColor = .underPageBackgroundColor
        view.editor = editor; view.language = language; view.selectionChanged = onSelection; view.observe()
        return view
    }
    func updateNSView(_ view: AnnotationPDFView, context: Context) {
        view.editor = editor; view.language = language; view.selectionChanged = onSelection
        view.updateFromEditor {
            if view.document !== document { view.document = document; view.installedIDs.removeAll(); view.lastArchive = nil; view.cachedWidth = nil }
            if let archive = editor.archive, archive != view.lastArchive || editor.selectedID != view.lastSelectedID { view.render(archive) }
            view.fitWidth = editor.zoom == 0
            if editor.zoom != 0 { view.scaleFactor = editor.zoom }; view.applyFit()
            let desired = max(0, min(document.pageCount - 1, editor.page - 1))
            if let page = document.page(at: desired), view.currentPage != page { view.go(to: page) }
        }
        if editor.tool.isMarkup, view.previousTool != editor.tool, view.currentSelection?.string?.isEmpty == false { DispatchQueue.main.async { [weak view] in view?.commitMarkup() } }
        view.previousTool = editor.tool
    }
}

@MainActor final class AnnotationPDFView: PDFView {
    weak var editor: PDFEditorModel?
    var language = "en"
    var selectionChanged: ((DocumentSelection) -> Void)?
    var fitWidth = true
    var installedIDs = Set<String>()
    var lastArchive: PDFAnnotationDocument?
    var lastSelectedID: String?
    var previousTool: PDFEditorTool = .read
    var cachedWidth: CGFloat?
    private var observers: [NSObjectProtocol] = []
    private var start: CGPoint?
    private var drawingPage: PDFPage?
    private var points: [CGPoint] = []
    private var moving: StoredPDFAnnotation?
    private var preview: PDFAnnotation?
    private var erased = Set<String>()
    private var resizing = false
    private var updatingFromEditor = false
    override var acceptsFirstResponder: Bool { true }
    override var undoManager: UndoManager? { editor?.undo ?? super.undoManager }
    func updateFromEditor(_ update: () -> Void) {
        updatingFromEditor = true
        defer { updatingFromEditor = false }
        update()
    }
    func observe() {
        observers.append(NotificationCenter.default.addObserver(forName: .PDFViewPageChanged, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, !self.updatingFromEditor, let document = self.document, let page = self.currentPage else { return }; let number = document.index(for: page) + 1
                if self.editor?.page != number {
                    // Document installation and fit-width emit transient page-one events.
                    // Only a still-current native navigation may update the editor later.
                    DispatchQueue.main.async { [weak self] in
                        guard let self, !self.updatingFromEditor, self.document === document, self.currentPage === page else { return }
                        self.editor?.page = number
                    }
                }
            }
        })
        observers.append(NotificationCenter.default.addObserver(forName: .PDFViewSelectionChanged, object: self, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { guard let self, let editor = self.editor, let selection = self.currentSelection, let text = selection.string else { return }
                let page = selection.pages.first.flatMap { self.document?.index(for: $0) }.map { $0 + 1 }
                self.selectionChanged?(DocumentSelection(documentID: editor.store.documentID, text: text, sourceHash: editor.archive?.sourceHash, page: page, revision: editor.archive?.revision))
            }
        })
    }
    override func layout() { super.layout(); applyFit() }
    func applyFit() {
        guard let document, bounds.width > 24 else { return }
        if fitWidth {
            let width = cachedWidth ?? (0..<document.pageCount).compactMap { document.page(at: $0) }.map { page -> CGFloat in let rect = page.bounds(for: .cropBox); return abs(page.rotation) % 180 == 90 ? rect.height : rect.width }.max() ?? 1
            cachedWidth = width
            let target = max(0.05, min(8, (bounds.width - 24) / width)); if abs(scaleFactor - target) > 0.002 { scaleFactor = target }
        }
        let scale = scaleFactor
        if abs((editor?.actualScale ?? scale) - scale) > 0.002 { DispatchQueue.main.async { [weak self] in self?.editor?.actualScale = scale } }
    }
    func render(_ archive: PDFAnnotationDocument) {
        guard let document else { return }
        // Selection is presentation state. Keep every saved native annotation
        // (and PDFKit's caches) intact when only the selection outline changes.
        if archive == lastArchive {
            if editor?.selectedID != lastSelectedID {
                if let previous = archive.annotations.first(where: { $0.id == lastSelectedID }), let page = document.page(at: previous.page - 1) {
                    for outline in page.annotations where outline.value(forAnnotationKey: .name) as? String == "ul-preview-selection" { page.removeAnnotation(outline) }
                }
                lastSelectedID = editor?.selectedID
                renderSelection(); needsDisplay = true
            }
            return
        }
        let replacedIDs = installedIDs.union(archive.annotations.map(\.id))
        let affected = Set((lastArchive?.annotations ?? []).map(\.page)).union(archive.annotations.map(\.page))
        for number in affected {
            guard let page = document.page(at: number - 1) else { continue }
            for annotation in page.annotations {
                if let id = annotation.value(forAnnotationKey: .name) as? String, replacedIDs.contains(id) || id.hasPrefix("ul-preview-") { page.removeAnnotation(annotation) }
            }
        }
        if lastArchive == nil || lastArchive?.viewRotations != archive.viewRotations {
            for (number, geometry) in archive.pages.enumerated() { document.page(at: number)?.rotation = (geometry.rotation + (archive.viewRotations[String(number + 1)] ?? 0)) % 360 }
            cachedWidth = nil
        }
        for annotation in archive.annotations { document.page(at: annotation.page - 1)?.addAnnotation(annotation.native()) }
        installedIDs = Set(archive.annotations.map(\.id)); lastArchive = archive; lastSelectedID = editor?.selectedID
        renderSelection()
        needsDisplay = true
    }
    private func renderSelection() {
        if let selected = editor?.selected, let page = document?.page(at: selected.page - 1) {
            let outline = PDFAnnotation(bounds: selected.bounds.insetBy(dx: -3, dy: -3), forType: .square, withProperties: nil)
            outline.setValue("ul-preview-selection", forAnnotationKey: .name); outline.color = .controlAccentColor; let border = PDFBorder(); border.lineWidth = 0.7; border.style = .dashed; outline.border = border; page.addAnnotation(outline)
        }
    }
    private func point(_ event: NSEvent, on page: PDFPage) -> CGPoint { convert(convert(event.locationInWindow, from: nil), to: page) }
    private func hit(_ point: CGPoint, page: PDFPage) -> StoredPDFAnnotation? {
        guard let document, let archive = editor?.archive else { return nil }
        let number = document.index(for: page) + 1
        return archive.annotations.reversed().first { !erased.contains($0.id) && $0.page == number && $0.bounds.insetBy(dx: -3 / max(scaleFactor, 0.05), dy: -3 / max(scaleFactor, 0.05)).contains(point) }
    }
    override func mouseDown(with event: NSEvent) {
        guard let editor, !editor.readOnly, editor.tool != .read && !editor.tool.isMarkup else {
            super.mouseDown(with: event)
            if editor?.tool.isMarkup == true { commitMarkup() }
            return
        }
        window?.makeFirstResponder(self)
        guard let page = page(for: convert(event.locationInWindow, from: nil), nearest: false) else { return }
        drawingPage = page; start = point(event, on: page); points = [start!]; erased.removeAll(); moving = nil; resizing = false
        if editor.tool == .select {
            moving = hit(start!, page: page); editor.selectedID = moving?.id
            if let value = moving, [.freeText, .rectangle, .ellipse].contains(value.kind) {
                resizing = hypot(start!.x - value.bounds.maxX, start!.y - value.bounds.minY) <= 9 / max(scaleFactor, 0.05)
            }
        } else if editor.tool == .eraser { erase(at: start!, page: page) }
    }
    override func mouseDragged(with event: NSEvent) {
        guard let editor, let page = drawingPage, let start else { super.mouseDragged(with: event); return }
        let now = point(event, on: page)
        if editor.tool == .eraser { erase(at: now, page: page); return }
        if editor.tool == .select, var value = moving {
            if resizing { value.bounds = CGRect(x: value.bounds.minX, y: min(now.y, value.bounds.maxY - 12), width: max(18, now.x - value.bounds.minX), height: max(12, value.bounds.maxY - now.y)) }
            else { value.translate(dx: now.x - start.x, dy: now.y - start.y) }
            showPreview(value, page: page); return
        }
        if editor.tool == .ink { points.append(now) }
        if let value = drawing(to: now, page: page) { showPreview(value, page: page) }
    }
    override func mouseUp(with event: NSEvent) {
        guard let editor, let page = drawingPage, let start else { super.mouseUp(with: event); if editor?.tool.isMarkup == true { commitMarkup() }; return }
        let now = point(event, on: page); clearPreview()
        if editor.tool == .select, var value = moving {
            if resizing { value.bounds = CGRect(x: value.bounds.minX, y: min(now.y, value.bounds.maxY - 12), width: max(18, now.x - value.bounds.minX), height: max(12, value.bounds.maxY - now.y)) }
            else { value.translate(dx: now.x - start.x, dy: now.y - start.y) }
            if value != moving { editor.replace(value) }
        } else if editor.tool == .eraser { editor.remove(erased) }
        else if let value = drawing(to: now, page: page) { editor.add([value]) }
        drawingPage = nil; self.start = nil; points = []; moving = nil
    }
    private func drawing(to end: CGPoint, page: PDFPage) -> StoredPDFAnnotation? {
        guard let editor, let start, let kind = editor.tool.annotationKind, let document else { return nil }
        var rect = CGRect(x: min(start.x, end.x), y: min(start.y, end.y), width: max(2, abs(start.x - end.x)), height: max(2, abs(start.y - end.y)))
        if kind == .ink, !points.isEmpty { let xs = points.map(\.x), ys = points.map(\.y); rect = CGRect(x: xs.min()! - 2, y: ys.min()! - 2, width: max(4, xs.max()! - xs.min()! + 4), height: max(4, ys.max()! - ys.min()! + 4)) }
        if kind == .freeText && rect.width < 10 { rect = CGRect(x: start.x, y: start.y - 40, width: 180, height: 40) }
        if kind == .stickyNote { rect = CGRect(x: start.x, y: start.y - 24, width: 24, height: 24) }
        var value = StoredPDFAnnotation(kind: kind, page: document.index(for: page) + 1, bounds: rect, color: AnnotationColor(NSColor(editor.color)), lineWidth: editor.lineWidth,
                                        text: kind == .freeText || kind == .stickyNote ? (editor.insertionText.isEmpty ? EditorText.get("annotationText", language) : editor.insertionText) : "", fontSize: editor.fontSize)
        if kind == .ink { value.ink = points.count == 1 ? [start, CGPoint(x: start.x + 0.1, y: start.y + 0.1)] : points }
        if kind == .arrow { value.startPoint = start; value.endPoint = end }
        return value
    }
    private func showPreview(_ value: StoredPDFAnnotation, page: PDFPage) {
        clearPreview(); let annotation = value.native(); annotation.setValue("ul-preview-drawing", forAnnotationKey: .name); page.addAnnotation(annotation); preview = annotation; needsDisplay = true
    }
    private func clearPreview() { if let preview { preview.page?.removeAnnotation(preview) }; preview = nil }
    private func erase(at point: CGPoint, page: PDFPage) {
        guard let value = hit(point, page: page), !erased.contains(value.id) else { return }; erased.insert(value.id)
        for annotation in page.annotations where annotation.value(forAnnotationKey: .name) as? String == value.id { page.removeAnnotation(annotation) }
    }
    func commitMarkup() {
        guard let editor, editor.tool.isMarkup, let kind = editor.tool.annotationKind, let selection = currentSelection, let document else { return }
        var values: [StoredPDFAnnotation] = []
        for line in selection.selectionsByLine() {
            for page in line.pages {
                let rect = line.bounds(for: page)
                guard !rect.isEmpty, rect.width.isFinite, rect.height.isFinite else { continue }
                values.append(StoredPDFAnnotation(kind: kind, page: document.index(for: page) + 1, bounds: rect, color: AnnotationColor(NSColor(editor.color)), lineWidth: editor.lineWidth, selectedText: line.string ?? ""))
            }
        }
        currentSelection = nil; editor.add(values)
    }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 51 || event.keyCode == 117, let id = editor?.selectedID { editor?.remove([id]); return }
        if event.modifierFlags.contains(.command), event.charactersIgnoringModifiers == "z" { if event.modifierFlags.contains(.shift) { editor?.undo.redo() } else { editor?.undo.undo() }; return }
        if [123, 124, 125, 126].contains(event.keyCode), editor?.selectedID != nil {
            let step: CGFloat = event.modifierFlags.contains(.shift) ? 10 : 1
            editor?.updateSelected { $0.translate(dx: event.keyCode == 123 ? -step : event.keyCode == 124 ? step : 0, dy: event.keyCode == 125 ? -step : event.keyCode == 126 ? step : 0) }; return
        }
        if event.keyCode == 53 { clearPreview(); drawingPage = nil; start = nil; erased.removeAll(); editor?.selectedID = nil; if let archive = editor?.archive { render(archive) }; return }
        super.keyDown(with: event)
    }
    deinit { observers.forEach(NotificationCenter.default.removeObserver) }
}
