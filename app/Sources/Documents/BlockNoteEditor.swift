import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor enum DocumentNoteActions {
    /// Active editors own their version and undo history. AI append is an explicit edit, never a stale disk overwrite.
    static func append(_ blocks: [NoteBlock], packageURL: URL, documentID: String, title: String) async throws -> BlockNoteDocument {
        if let editor = DocumentEditingSessions.noteEditor(at: packageURL) {
            if editor.readOnly { await editor.showRevision(nil) }
            guard !editor.readOnly, await editor.flush() else { throw DocumentFailure.message(editor.error ?? DocumentFailure.conflict.localizedDescription) }
            editor.mutate("Append note content") { $0.blocks += blocks }
            guard await editor.flush(), let saved = editor.document else { throw DocumentFailure.message(editor.error ?? "The note could not be saved.") }
            return saved
        }
        return try await Task.detached {
            let store = BlockNoteStore(packageURL: packageURL, noteID: documentID)
            var note = try store.create(title: title); note.blocks += blocks
            return try store.save(note)
        }.value
    }
}

@MainActor final class BlockNoteEditorModel: ObservableObject, DocumentEditingSession {
    @Published var document: BlockNoteDocument?
    @Published var state = "loading"
    @Published var error: String?
    @Published var notice: String?
    @Published var selectedBlock: String?
    @Published var readOnly = false
    let store: BlockNoteStore
    let undo = UndoManager()
    var onSave: ((BlockNoteDocument) -> Void)?
    private var debounce: Task<Void, Never>?
    private var saving = false
    private var pendingDraft: BlockNoteDocument?
    private var draftWriter: Task<Void, Never>?
    private var generation = 0
    private var conflict = false
    init(packageURL: URL, noteID: String) { store = BlockNoteStore(packageURL: packageURL, noteID: noteID); DocumentEditingSessions.register(self) }
    func load(title: String, language: String, revision: Int? = nil) async {
        guard document == nil else { return }
        do {
            let store = self.store
            if let revision {
                document = try await Task.detached { try store.revision(revision) }.value
                readOnly = true; state = "saved"; selectedBlock = document?.blocks.first?.id
                return
            }
            let pair = try await Task.detached { () -> (BlockNoteDocument, BlockNoteDocument?) in
                let saved = FileManager.default.fileExists(atPath: store.packageURL.appendingPathComponent("note.json").path) ? try store.load() : try store.create(title: title)
                return (saved, try store.recoverableDraft())
            }.value
            document = pair.0; state = "saved"
            if let draft = pair.1, draft.blocks != pair.0.blocks || draft.title != pair.0.title {
                document = draft; state = "saving"; notice = EditorText.get("recovered", language)
                conflict = draft.revision != pair.0.revision
                if conflict { state = "saveFailed"; error = DocumentFailure.conflict.localizedDescription }
            }
            selectedBlock = document?.blocks.first?.id
        } catch { self.error = error.localizedDescription; state = "saveFailed" }
    }
    func mutate(_ action: String, recordUndo: Bool = true, _ operation: (inout BlockNoteDocument) -> Void) {
        guard !readOnly, var next = document else { return }
        let previous = next
        operation(&next)
        guard next != previous else { return }
        if recordUndo { undo.registerUndo(withTarget: self) { target in MainActor.assumeIsolated { target.restoreContent(previous) } }; undo.setActionName(action) }
        next.savedAt = Date(); document = next; generation += 1; state = "saving"
        schedule()
    }
    private func restoreContent(_ previous: BlockNoteDocument) {
        mutate("Edit") { next in next.blocks = previous.blocks; next.title = previous.title }
    }
    func edit(_ id: String, _ operation: (inout NoteBlock) -> Void, recordUndo: Bool = true) {
        mutate("Edit", recordUndo: recordUndo) { note in if let index = note.blocks.firstIndex(where: { $0.id == id }) { operation(&note.blocks[index]) } }
    }
    func add(_ kind: NoteBlockKind, after: String? = nil) {
        let block = NoteBlock(kind: kind, cells: kind == .table ? [["", ""], ["", ""]] : [])
        mutate("Add block") { note in
            let index = after.flatMap { id in note.blocks.firstIndex { $0.id == id } }.map { $0 + 1 } ?? note.blocks.count
            note.blocks.insert(block, at: index)
        }; selectedBlock = block.id
    }
    func move(_ id: String, before: String?) { mutate("Move block") { $0.moveBlock(id, before: before) } }
    func remove(_ id: String) { mutate("Delete block") { $0.blocks.removeAll { $0.id == id }; if $0.blocks.isEmpty { $0.blocks.append(NoteBlock(kind: .paragraph)) } } }
    func importImage(_ url: URL, into id: String? = nil) async {
        do {
            let store = self.store; let resource = try await Task.detached { try store.importImage(from: url) }.value
            if let id { edit(id) { $0.resource = resource } }
            else { mutate("Add image") { $0.blocks.append(NoteBlock(kind: .image, resource: resource)) } }
        } catch { self.error = error.localizedDescription }
    }
    private func schedule() {
        debounce?.cancel()
        pendingDraft = document
        if draftWriter == nil {
            draftWriter = Task {
                // Coalesce a burst into one latest snapshot while retaining a
                // single in-flight write. Never launch one detached task per key.
                await Task.yield()
                while let snapshot = pendingDraft {
                    pendingDraft = nil
                    do { let store = self.store; try await Task.detached { try store.saveDraft(snapshot) }.value }
                    catch { self.error = error.localizedDescription; state = "saveFailed" }
                }
                draftWriter = nil
            }
        }
        debounce = Task { try? await Task.sleep(nanoseconds: 450_000_000); guard !Task.isCancelled else { return }; debounce = nil; _ = await flush() }
    }
    func flush() async -> Bool {
        if readOnly { return true }
        debounce?.cancel(); debounce = nil
        while let writer = draftWriter { await writer.value }
        while saving { await Task.yield() }
        guard state != "saved", let snapshot = document else { return document != nil }
        guard !conflict else { return false }
        saving = true; let start = generation
        do {
            let store = self.store
            let saved = try await Task.detached { try store.saveDraft(snapshot); return try store.save(snapshot) }.value
            document?.revision = saved.revision; if start == generation { document?.savedAt = saved.savedAt }
            error = nil; state = start == generation ? "saved" : "saving"; saving = false; onSave?(saved)
            if start != generation { return await flush() }
            return true
        } catch { self.error = error.localizedDescription; state = "saveFailed"; saving = false; return false }
    }
    func reload() async {
        debounce?.cancel(); while let writer = draftWriter { await writer.value }; while saving { await Task.yield() }
        do { let store = self.store, snapshot = document; document = try await Task.detached { if let snapshot { try store.preserveRecovery(snapshot) }; return try store.load() }.value; conflict = false; error = nil; notice = nil; state = "saved"; undo.removeAllActions() }
        catch { self.error = error.localizedDescription; state = "saveFailed" }
    }
    func showRevision(_ revision: Int?) async {
        if document != nil, !(await flush()) { return }
        do {
            let store = self.store
            let pair = try await Task.detached { () -> (BlockNoteDocument, Bool) in
                if let revision { return (try store.revision(revision), true) }
                return (try store.load(), false)
            }.value
            document = pair.0; readOnly = pair.1; state = "saved"; error = nil; notice = nil; undo.removeAllActions()
        } catch { self.error = error.localizedDescription }
    }
    func saveCopy(to url: URL) async {
        guard let snapshot = document else { return }
        do {
            let originalStore = store
            try await Task.detached {
                let copy = BlockNoteStore(packageURL: url, noteID: UUID().uuidString)
                var next = snapshot; next.id = copy.noteID; next.revision = 0
                for index in next.blocks.indices {
                    if let resource = next.blocks[index].resource { next.blocks[index].resource = try copy.importImage(from: originalStore.resourceURL(resource)) }
                }
                _ = try copy.save(next)
            }.value
            notice = url.path
        } catch { self.error = error.localizedDescription }
    }
}

struct BlockNoteEditor: View {
    @StateObject private var editor: BlockNoteEditorModel
    let title: String
    let language: String
    let navigationRequest: BlockNavigationRequest?
    var currentPageLink: DocumentPageLink?
    var onSelection: (DocumentSelection) -> Void
    var onOpenLink: (DocumentPageLink) -> Void
    var onSave: (BlockNoteDocument) -> Void
    @State private var dragID: String?
    @State private var dropID: String?
    init(packageURL: URL, noteID: String, title: String = "", language: String = "en", currentPageLink: DocumentPageLink? = nil, navigationRequest: BlockNavigationRequest? = nil,
         onSelection: @escaping (DocumentSelection) -> Void = { _ in }, onOpenLink: @escaping (DocumentPageLink) -> Void = { _ in }, onSave: @escaping (BlockNoteDocument) -> Void = { _ in }) {
        _editor = StateObject(wrappedValue: BlockNoteEditorModel(packageURL: packageURL, noteID: noteID))
        self.title = title; self.language = language; self.currentPageLink = currentPageLink; self.navigationRequest = navigationRequest; self.onSelection = onSelection; self.onOpenLink = onOpenLink; self.onSave = onSave
    }
    private func t(_ key: String) -> String { EditorText.get(key, language) }
    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            if let document = editor.document {
                if editor.readOnly {
                    HStack { Text(t("noteHistory") + " · \(document.revision)"); Spacer(); Button(t("currentVersion")) { Task { await editor.showRevision(nil) } } }.font(.caption).padding(9).background(Color.accentColor.opacity(0.08))
                }
                if let notice = editor.notice { Text(notice).font(.caption).foregroundStyle(.secondary).padding(8).frame(maxWidth: .infinity, alignment: .leading) }
                ScrollViewReader { proxy in ScrollView {
                    LazyVStack(alignment: .leading, spacing: 7) {
                        ForEach(document.blocks) { block in
                            BlockEditorRow(block: block, editor: editor, language: language, onSelection: onSelection, onOpenLink: onOpenLink, beginDrag: { dragID = block.id; return NSItemProvider(object: ("ulecture-block:" + document.id + ":" + block.id) as NSString) })
                                .overlay(alignment: .top) { if dropID == block.id { Color.accentColor.frame(height: 3) } }
                                .onDrop(of: [.text], delegate: NoteBlockDrop(target: block.id, dragged: $dragID, hovered: $dropID, editor: editor))
                        }
                        Button { editor.add(.paragraph) } label: { Label(t("addBlock"), systemImage: "plus").frame(maxWidth: .infinity, alignment: .leading).padding(8) }.buttonStyle(.plain).foregroundStyle(.secondary)
                            .onDrop(of: [.text], delegate: NoteBlockDrop(target: nil, dragged: $dragID, hovered: $dropID, editor: editor))
                    }.padding(14)
                }.onChange(of: navigationRequest) { _, request in if let request { Task { await editor.showRevision(request.revision); editor.selectedBlock = request.blockID; await Task.yield(); proxy.scrollTo(request.blockID, anchor: .center) } } }
                 .onAppear { if let request = navigationRequest { Task { await editor.showRevision(request.revision); editor.selectedBlock = request.blockID; await Task.yield(); proxy.scrollTo(request.blockID, anchor: .center) } } }
                }
                EditorStatusBar(state: editor.state, error: editor.error, language: language) { Task { _ = await editor.flush() } }
                if editor.state == "saveFailed" {
                    HStack { Button(t("reload")) { Task { await editor.reload() } }; Button(t("saveCopy"), action: saveCopy) }.controlSize(.small).padding(8)
                }
            } else {
                VStack(spacing: 12) { if let error = editor.error { Text(EditorText.failure(error, language)).textSelection(.enabled) } else { ProgressView(t("loading")) } }.frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }.background(Color(nsColor: .textBackgroundColor))
            .task { editor.onSave = onSave; await editor.load(title: title, language: language, revision: navigationRequest?.revision) }
            .onDisappear { Task { _ = await editor.flush() } }
    }
    private var toolbar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 9) {
                Menu { ForEach(NoteBlockKind.allCases.filter { $0 != .rawMarkdown }, id: \.self) { kind in
                    Button(t(kind.rawValue)) { if kind == .image { importImage() } else { editor.add(kind, after: editor.selectedBlock) } }
                } } label: { Label(t("addBlock"), systemImage: "plus") }.menuIndicator(.hidden).disabled(editor.readOnly)
                ForEach(["bold", "italic", "underline"], id: \.self) { key in
                    Button { NotificationCenter.default.post(name: .ulBlockFormat, object: editor.selectedBlock, userInfo: ["action": key]) } label: { Image(systemName: key) }.help(t(key)).accessibilityLabel(t(key)).disabled(editor.readOnly)
                }
                Button { editor.undo.undo() } label: { Image(systemName: "arrow.uturn.backward") }.help(t("undo")).accessibilityLabel(t("undo"))
                Button { editor.undo.redo() } label: { Image(systemName: "arrow.uturn.forward") }.help(t("redo")).accessibilityLabel(t("redo"))
                if let link = currentPageLink { Button { if let id = editor.selectedBlock { editor.edit(id) { $0.links.append(link) } } } label: { Image(systemName: "link") }.help(t("pageLink")).accessibilityLabel(t("pageLink")) }
                Menu(t("export")) {
                    Button("Markdown") { exportMarkdown() }
                    Button("PDF") { exportPDF() }
                    Button(t("saveCopy"), action: saveCopy)
                }.menuIndicator(.hidden)
            }.controlSize(.small).padding(10)
        }.frame(height: 44)
    }
    private func importImage() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]
        if panel.runModal() == .OK, let url = panel.url { Task { await editor.importImage(url) } }
    }
    private func saveCopy() {
        let panel = NSSavePanel(); panel.nameFieldStringValue = title + " copy.ulnote"; panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { Task { await editor.saveCopy(to: url) } }
    }
    private func exportMarkdown() {
        guard let value = editor.document else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = value.title + ".md"
        if panel.runModal() == .OK, let url = panel.url {
            Task { do { let store = editor.store; try await Task.detached { try BlockNoteExporter.markdown(value, store: store, to: url) }.value } catch { editor.error = error.localizedDescription } }
        }
    }
    private func exportPDF() {
        guard let value = editor.document else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = value.title + ".pdf"
        if panel.runModal() == .OK, let url = panel.url {
            Task { do { let store = editor.store; try await Task.detached { try BlockNoteExporter.pdf(value, store: store, to: url) }.value } catch { editor.error = error.localizedDescription } }
        }
    }
}

private struct NoteBlockDrop: DropDelegate {
    let target: String?
    @Binding var dragged: String?
    @Binding var hovered: String?
    let editor: BlockNoteEditorModel
    func validateDrop(info: DropInfo) -> Bool { dragged != nil && dragged != target }
    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }
    func dropEntered(info: DropInfo) { if dragged != nil { hovered = target } }
    func dropExited(info: DropInfo) { if hovered == target { hovered = nil } }
    func performDrop(info: DropInfo) -> Bool {
        guard let id = dragged else { return false }; editor.move(id, before: target); dragged = nil; hovered = nil; return true
    }
}

private struct BlockEditorRow: View {
    let block: NoteBlock
    @ObservedObject var editor: BlockNoteEditorModel
    let language: String
    let onSelection: (DocumentSelection) -> Void
    let onOpenLink: (DocumentPageLink) -> Void
    let beginDrag: () -> NSItemProvider
    @State private var textHeight: CGFloat = 40
    private func t(_ key: String) -> String { EditorText.get(key, language) }
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            VStack(spacing: 0) {
            Image(systemName: "line.3.horizontal").font(.system(size: 11)).frame(width: 22, height: 24).contentShape(Rectangle())
                .onDrag(beginDrag).accessibilityLabel(t("moveBlock")).opacity(editor.readOnly ? 0.35 : 1)
            Menu {
                ForEach(NoteBlockKind.allCases.filter { $0 != .image && $0 != .table }, id: \.self) { kind in Button(t(kind.rawValue)) { editor.edit(block.id) { $0.kind = kind } } }
                Divider()
                Button(t("moveUp")) { move(-1) }; Button(t("moveDown")) { move(1) }
                Button(t("duplicate")) { editor.mutate("Duplicate") { note in if let index = note.blocks.firstIndex(where: { $0.id == block.id }) { var copy = block; copy.id = UUID().uuidString; note.blocks.insert(copy, at: index + 1) } } }
                if block.kind == .list || block.kind == .todo {
                    Button(t("indent")) { editor.edit(block.id) { $0.indent = min(20, ($0.indent ?? 0) + 1) } }
                    Button(t("outdent")) { editor.edit(block.id) { $0.indent = max(0, ($0.indent ?? 0) - 1) } }
                    if block.kind == .list { Button(t(block.ordered ? "unordered" : "ordered")) { editor.edit(block.id) { $0.ordered.toggle() } } }
                }
                Button(t("delete")) { editor.remove(block.id) }
            } label: { Image(systemName: "ellipsis").font(.system(size: 11)).frame(width: 22, height: 17) }.menuIndicator(.hidden).menuStyle(.borderlessButton).fixedSize()
                .accessibilityLabel(t(block.kind.rawValue))
                .disabled(editor.readOnly)
            }.frame(width: 22)
            VStack(alignment: .leading, spacing: 5) {
                blockContent
                ForEach(block.links) { link in Button { onOpenLink(link) } label: { Label(link.label + " · " + t("page") + " \(link.page)", systemImage: "link") }.buttonStyle(.link).font(.caption) }
            }.padding(.leading, CGFloat(block.indent ?? 0) * 15).frame(maxWidth: .infinity, alignment: .leading)
        }.padding(5).background(editor.selectedBlock == block.id ? Color.accentColor.opacity(0.045) : Color.clear).clipShape(RoundedRectangle(cornerRadius: 7))
            .contentShape(Rectangle()).onTapGesture { editor.selectedBlock = block.id }
    }
    @ViewBuilder private var blockContent: some View {
        switch block.kind {
        case .table: table
        case .image: image
        default:
            HStack(alignment: .top, spacing: 6) {
                if block.kind == .todo { Toggle("", isOn: Binding(get: { block.checked }, set: { value in editor.edit(block.id) { $0.checked = value } })).labelsHidden().padding(.top, 9) }
                if block.kind == .list { Text(block.ordered ? "1." : "•").padding(.top, 8) }
                if block.kind == .quote { RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.3)).frame(width: 3) }
                VStack(alignment: .leading, spacing: 3) {
                    if block.kind == .heading {
                        Picker("", selection: Binding(get: { block.level }, set: { value in editor.edit(block.id) { $0.level = value; $0.richText = nil } })) { ForEach(1...6, id: \.self) { Text("H\($0)").tag($0) } }.labelsHidden().frame(width: 60).controlSize(.mini)
                    }
                    if block.kind == .code { TextField(t("codeLanguage"), text: Binding(get: { block.codeLanguage }, set: { value in editor.edit(block.id) { $0.codeLanguage = value } })).font(.caption).textFieldStyle(.plain) }
                    BlockRichText(block: block, undo: editor.undo, readOnly: editor.readOnly, height: $textHeight, onOpenLink: onOpenLink, onChange: { text, data in editor.edit(block.id, { $0.text = text; $0.richText = data }, recordUndo: false) }, onSelection: { selected in
                        editor.selectedBlock = block.id
                        onSelection(DocumentSelection(documentID: editor.store.noteID, text: selected, blockID: block.id, revision: editor.state == "saved" ? editor.document?.revision : nil))
                    }).frame(height: max(32, textHeight))
                }
            }.padding(block.kind == .code || block.kind == .rawMarkdown ? 7 : 0).background(block.kind == .code || block.kind == .rawMarkdown ? Color.secondary.opacity(0.07) : Color.clear).clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }
    private var table: some View {
        VStack(alignment: .leading, spacing: 5) {
            ScrollView(.horizontal) {
                VStack(spacing: 1) {
                    ForEach(block.cells.indices, id: \.self) { row in
                        HStack(spacing: 1) {
                            ForEach(block.cells[row].indices, id: \.self) { column in
                                TextField("", text: Binding(get: { block.cells[row][column] }, set: { value in editor.edit(block.id) { $0.cells[row][column] = value } }), axis: .vertical)
                                    .textFieldStyle(.plain).padding(8).frame(minWidth: 100, idealWidth: 140).background(Color.primary.opacity(row == 0 ? 0.07 : 0.025))
                            }
                        }
                    }
                }
            }
            HStack {
                Button(t("addRow")) { editor.edit(block.id) { $0.cells.append(Array(repeating: "", count: $0.cells.first?.count ?? 2)) } }
                Button(t("addColumn")) { editor.edit(block.id) { for index in $0.cells.indices { $0.cells[index].append("") } } }
                Menu("…") {
                    Button(t("removeRow")) { editor.edit(block.id) { if $0.cells.count > 1 { $0.cells.removeLast() } } }
                    Button(t("removeColumn")) { editor.edit(block.id) { for index in $0.cells.indices where $0.cells[index].count > 1 { $0.cells[index].removeLast() } } }
                }.menuIndicator(.hidden)
            }.controlSize(.mini)
        }.disabled(editor.readOnly)
    }
    private var image: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let path = block.resource, let url = try? editor.store.resourceURL(path), let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().scaledToFit().frame(maxWidth: block.imageWidth)
                Slider(value: Binding(get: { block.imageWidth }, set: { value in editor.edit(block.id) { $0.imageWidth = value } }), in: 100...1000).frame(maxWidth: 220)
            } else { Label(t("missingImage"), systemImage: "photo.badge.exclamationmark").foregroundStyle(.secondary) }
            TextField(t("image"), text: Binding(get: { block.text }, set: { value in editor.edit(block.id) { $0.text = value } })).textFieldStyle(.plain)
            Button(t("image")) { let panel = NSOpenPanel(); panel.allowedContentTypes = [.image]; if panel.runModal() == .OK, let url = panel.url { Task { await editor.importImage(url, into: block.id) } } }.controlSize(.small)
        }.disabled(editor.readOnly)
    }
    private func move(_ delta: Int) {
        guard let blocks = editor.document?.blocks, let index = blocks.firstIndex(where: { $0.id == block.id }) else { return }
        let target = delta < 0 ? index - 1 : index + 2
        guard delta > 0 || target >= 0 else { return }
        editor.move(block.id, before: target < blocks.count ? blocks[target].id : nil)
    }
}

extension Notification.Name { static let ulBlockFormat = Notification.Name("ULecture.BlockFormat") }

private final class BlockTextView: NSTextView {
    weak var sharedUndo: UndoManager?
    var resized: (() -> Void)?
    override var undoManager: UndoManager? { sharedUndo ?? super.undoManager }
    override func setFrameSize(_ newSize: NSSize) { super.setFrameSize(newSize); resized?() }
}

private struct BlockRichText: NSViewRepresentable {
    let block: NoteBlock
    let undo: UndoManager
    let readOnly: Bool
    @Binding var height: CGFloat
    let onOpenLink: (DocumentPageLink) -> Void
    let onChange: (String, Data?) -> Void
    let onSelection: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let container = NSScrollView(); container.drawsBackground = false; container.hasVerticalScroller = false
        let text = BlockTextView(frame: .zero); text.isRichText = true; text.importsGraphics = false; text.allowsUndo = true; text.sharedUndo = undo
        text.isAutomaticQuoteSubstitutionEnabled = false; text.isAutomaticDashSubstitutionEnabled = false; text.drawsBackground = false
        text.textContainerInset = NSSize(width: 3, height: 6); text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        text.autoresizingMask = [.width]; text.textContainer?.widthTracksTextView = true; text.textContainer?.containerSize = NSSize(width: 500, height: CGFloat.greatestFiniteMagnitude)
        text.delegate = context.coordinator; container.documentView = text; context.coordinator.textView = text
        text.resized = { [weak coordinator = context.coordinator] in coordinator?.measure() }
        context.coordinator.observer = NotificationCenter.default.addObserver(forName: .ulBlockFormat, object: nil, queue: .main) { [weak coordinator = context.coordinator] notification in
            guard let coordinator, notification.object as? String == coordinator.parent.block.id else { return }; coordinator.format(notification.userInfo?["action"] as? String ?? "")
        }
        apply(text); context.coordinator.rendered = block; return container
    }
    func updateNSView(_ view: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let text = view.documentView as? BlockTextView else { return }
        text.isEditable = !readOnly
        let old = context.coordinator.rendered
        if !text.hasMarkedText(), old?.text != block.text || old?.richText != block.richText || old?.kind != block.kind || old?.level != block.level {
            let selection = text.selectedRange(); apply(text)
            let count = (text.string as NSString).length
            text.setSelectedRange(NSRange(location: min(selection.location, count), length: min(selection.length, max(0, count - min(selection.location, count)))))
        }
        if !text.hasMarkedText() { context.coordinator.rendered = block }
        context.coordinator.measure()
    }
    private func apply(_ text: NSTextView) {
        let attributed = NSMutableAttributedString(attributedString: block.attributedText)
        let font: NSFont = block.kind == .heading ? .boldSystemFont(ofSize: CGFloat(28 - block.level * 3)) : block.kind == .code || block.kind == .rawMarkdown ? .monospacedSystemFont(ofSize: 13, weight: .regular) : .systemFont(ofSize: 15)
        if block.richText == nil { attributed.addAttribute(.font, value: font, range: NSRange(location: 0, length: attributed.length)) }
        // NSTextStorage without a foreground color draws black, including in dark
        // appearance. Keep the semantic default color in the secure rich-text archive;
        // explicitly authored colors retain their original value.
        attributed.enumerateAttribute(.foregroundColor, in: NSRange(location: 0, length: attributed.length)) { color, range, _ in
            if color == nil { attributed.addAttribute(.foregroundColor, value: NSColor.textColor, range: range) }
        }
        text.textStorage?.setAttributedString(attributed); text.typingAttributes = [.font: font, .foregroundColor: NSColor.textColor]
        text.isRichText = block.kind != .code && block.kind != .rawMarkdown
        text.isEditable = !readOnly
        text.setAccessibilityLabel(block.kind.rawValue)
        text.identifier = NSUserInterfaceItemIdentifier("block-" + block.id)
    }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: BlockRichText; weak var textView: BlockTextView?; var observer: NSObjectProtocol?; var rendered: NoteBlock?
        init(_ parent: BlockRichText) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let text = textView, !text.hasMarkedText() else { return }
            let value = text.attributedString()
            let data = try? NoteRichText.encode(value)
            rendered = parent.block; rendered?.text = value.string; rendered?.richText = data
            parent.onChange(value.string, data); measure()
        }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let text = textView else { return }; let range = text.selectedRange()
            guard NSMaxRange(range) <= (text.string as NSString).length else { return }
            parent.onSelection((text.string as NSString).substring(with: range))
        }
        func textView(_ textView: NSTextView, clickedOnLink link: Any, at charIndex: Int) -> Bool {
            let url = (link as? URL) ?? (link as? String).flatMap(URL.init(string:))
            guard let url, let reference = DocumentPageLink.parse(url) else { return false }
            parent.onOpenLink(reference); return true
        }
        func measure() {
            guard let text = textView, let layout = text.layoutManager, let container = text.textContainer else { return }
            layout.ensureLayout(for: container)
            let measured = max(32, ceil(layout.usedRect(for: container).height) + 14)
            if abs(parent.height - measured) > 1 { DispatchQueue.main.async { [weak self] in self?.parent.height = measured } }
        }
        func format(_ action: String) {
            guard let text = textView else { return }; text.window?.makeFirstResponder(text)
            let range = text.selectedRange(); guard range.length > 0, let storage = text.textStorage else { return }
            let before = storage.attributedSubstring(from: range)
            text.undoManager?.registerUndo(withTarget: self) { target in target.replace(range, with: before) }
            if action == "underline" {
                let enabled = (storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int ?? 0) == 0
                storage.addAttribute(.underlineStyle, value: enabled ? NSUnderlineStyle.single.rawValue : 0, range: range)
            } else {
                let trait: NSFontTraitMask = action == "bold" ? .boldFontMask : .italicFontMask
                storage.enumerateAttribute(.font, in: range) { value, subrange, _ in
                    let font = value as? NSFont ?? .systemFont(ofSize: 15)
                    let updated = NSFontManager.shared.traits(of: font).contains(trait) ? NSFontManager.shared.convert(font, toNotHaveTrait: trait) : NSFontManager.shared.convert(font, toHaveTrait: trait)
                    storage.addAttribute(.font, value: updated, range: subrange)
                }
            }
            text.didChangeText()
        }
        private func replace(_ range: NSRange, with value: NSAttributedString) {
            guard let text = textView, let storage = text.textStorage, NSMaxRange(range) <= storage.length else { return }
            let previous = storage.attributedSubstring(from: range)
            text.undoManager?.registerUndo(withTarget: self) { $0.replace(NSRange(location: range.location, length: value.length), with: previous) }
            storage.replaceCharacters(in: range, with: value); text.didChangeText()
        }
        deinit { if let observer { NotificationCenter.default.removeObserver(observer) } }
    }
}
