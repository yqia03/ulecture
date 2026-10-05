import SwiftUI
import AppKit

struct TextDocumentDraft: Codable {
    var documentID: String
    var baseHash: String
    var text: String
    var updatedAt: Date
}

final class TextDocumentStore {
    let documentID: String
    let sourceURL: URL
    let draftURL: URL
    private let lock: NSRecursiveLock
    private var observedHash: String?
    private var encoding: String.Encoding = .utf8
    private var publishedDraftCutoff = Date.distantPast
    init(documentID: String, sourceURL: URL, draftURL: URL) { self.documentID = documentID; self.sourceURL = sourceURL; self.draftURL = draftURL; lock = DocumentDisk.serialLock(for: sourceURL) }
    func load() throws -> (String, String, TextDocumentDraft?) {
        lock.lock(); defer { lock.unlock() }
        let bytes = try Data(contentsOf: sourceURL)
        var detected = String.Encoding.utf8
        let text = try String(contentsOf: sourceURL, usedEncoding: &detected)
        guard try DocumentDisk.hash(sourceURL) == DocumentDisk.hash(bytes) else { throw DocumentFailure.conflict }
        observedHash = DocumentDisk.hash(bytes); encoding = detected
        let draft = try? DocumentDisk.read(TextDocumentDraft.self, from: draftURL)
        guard draft == nil || draft?.documentID == documentID else { throw DocumentFailure.invalidFormat }
        return (text, observedHash!, draft)
    }
    func saveDraft(_ draft: TextDocumentDraft) throws {
        lock.lock(); defer { lock.unlock() }
        guard draft.updatedAt > publishedDraftCutoff else { return }
        try DocumentDisk.writableDirectory(draftURL.deletingLastPathComponent(), create: true)
        if let previous = try? DocumentDisk.read(TextDocumentDraft.self, from: draftURL), previous.updatedAt > draft.updatedAt { return }
        try DocumentDisk.write(DocumentDisk.json(draft), to: draftURL)
    }
    func save(_ text: String, editedAt: Date = Date()) throws -> String {
        lock.lock(); defer { lock.unlock() }
        guard let observedHash, try DocumentDisk.hash(sourceURL) == observedHash else { throw DocumentFailure.conflict }
        guard let data = text.data(using: encoding, allowLossyConversion: false) else { throw DocumentFailure.message("This text cannot be saved in its original encoding. Save a UTF-8 copy to preserve every character.") }
        try DocumentDisk.write(data, to: sourceURL); self.observedHash = DocumentDisk.hash(data)
        publishedDraftCutoff = max(publishedDraftCutoff, editedAt)
        if let draft = try? DocumentDisk.read(TextDocumentDraft.self, from: draftURL), draft.text == text { try? FileManager.default.removeItem(at: draftURL) }
        return self.observedHash!
    }
    func preserveRecoveryAndReload(_ visible: TextDocumentDraft) throws -> (String, String) {
        lock.lock(); defer { lock.unlock() }
        guard visible.documentID == documentID else { throw DocumentFailure.invalidFormat }
        let directory = draftURL.deletingLastPathComponent()
        try DocumentDisk.writableDirectory(directory, create: true)
        try DocumentDisk.write(DocumentDisk.json(visible), to: directory.appendingPathComponent("draft-preserved-\(UUID().uuidString).json"), replace: false)
        publishedDraftCutoff = max(publishedDraftCutoff, visible.updatedAt)
        if let pending = try? DocumentDisk.read(TextDocumentDraft.self, from: draftURL), pending.updatedAt <= visible.updatedAt {
            try FileManager.default.removeItem(at: draftURL); try DocumentDisk.syncDirectory(directory)
        }
        let result = try load(); return (result.0, result.1)
    }
}

@MainActor final class TextSourceModel: ObservableObject, DocumentEditingSession {
    @Published var text: String?
    @Published var state = "loading"
    @Published var error: String?
    @Published var sourceHash = ""
    let store: TextDocumentStore
    private var changed = 0
    private var saving = false
    private var conflict = false
    private var debounce: Task<Void, Never>?
    var onSave: ((String, String) -> Void)?
    init(store: TextDocumentStore) { self.store = store; DocumentEditingSessions.register(self) }
    func load() async {
        do {
            let store = self.store; let loaded = try await Task.detached { try store.load() }.value
            sourceHash = loaded.1; text = loaded.0; state = "saved"; error = nil; conflict = false
            if let draft = loaded.2, draft.text != loaded.0 {
                text = draft.text; state = "saving"
                if draft.baseHash != loaded.1 { conflict = true; state = "saveFailed"; error = DocumentFailure.conflict.localizedDescription }
            }
        } catch { self.error = error.localizedDescription; state = "saveFailed" }
    }
    func edit(_ value: String) {
        text = value; changed += 1; state = "saving"; debounce?.cancel()
        let draft = TextDocumentDraft(documentID: store.documentID, baseHash: sourceHash, text: value, updatedAt: Date()), store = self.store
        Task.detached { try? store.saveDraft(draft) }
        debounce = Task { try? await Task.sleep(nanoseconds: 450_000_000); guard !Task.isCancelled else { return }; debounce = nil; _ = await flush() }
    }
    func flush() async -> Bool {
        debounce?.cancel(); debounce = nil
        while saving { await Task.yield() }
        guard !conflict else { return false }
        guard state != "saved", let text else { return self.text != nil }
        let start = changed; saving = true
        do {
            let store = self.store, draft = TextDocumentDraft(documentID: store.documentID, baseHash: sourceHash, text: text, updatedAt: Date())
            sourceHash = try await Task.detached { try store.saveDraft(draft); return try store.save(text, editedAt: draft.updatedAt) }.value
            saving = false; error = nil; state = changed == start ? "saved" : "saving"; onSave?(text, sourceHash)
            if changed != start { return await flush() }; return true
        } catch { self.error = error.localizedDescription; state = "saveFailed"; saving = false; return false }
    }
    func discardDraftAndReload() async {
        debounce?.cancel(); while saving { await Task.yield() }
        // Preserve what is visible even if the earlier background draft write failed.
        do {
            let store = self.store, visible = TextDocumentDraft(documentID: store.documentID, baseHash: sourceHash, text: text ?? "", updatedAt: Date())
            let pair = try await Task.detached { try store.preserveRecoveryAndReload(visible) }.value
            text = pair.0; sourceHash = pair.1; conflict = false; state = "saved"; error = nil
        } catch { self.error = error.localizedDescription }
    }
}

struct TextSourceEditor: View {
    @StateObject private var editor: TextSourceModel
    let language: String
    let onSelection: (DocumentSelection) -> Void
    let onSave: (String, String) -> Void
    let onOpenLink: ((DocumentPageLink) -> Void)?
    @State private var preview = false
    init(documentID: String, sourceURL: URL, draftURL: URL, language: String = "en", onSelection: @escaping (DocumentSelection) -> Void = { _ in }, onSave: @escaping (String, String) -> Void = { _, _ in }, onOpenLink: ((DocumentPageLink) -> Void)? = nil) {
        _editor = StateObject(wrappedValue: TextSourceModel(store: TextDocumentStore(documentID: documentID, sourceURL: sourceURL, draftURL: draftURL)))
        self.language = language; self.onSelection = onSelection; self.onSave = onSave; self.onOpenLink = onOpenLink
    }
    private func t(_ key: String) -> String { EditorText.get(key, language) }
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(editor.store.sourceURL.lastPathComponent).font(.headline).lineLimit(1)
                Spacer()
                if editor.store.sourceURL.pathExtension.lowercased() == "md" { Button(t(preview ? "source" : "preview")) { preview.toggle() } }
                Menu(t("export")) { Button(t("saveCopy"), action: saveCopy); Button("PDF", action: exportPDF); Button(t("convertBlocks"), action: convert) }
            }.controlSize(.small).padding(12)
            Divider()
            if let text = editor.text {
                if preview { MarkdownDocumentPreview(text: text, onOpenLink: onOpenLink) }
                else { PlainSourceText(text: Binding(get: { editor.text ?? "" }, set: editor.edit), onSelection: { selected in onSelection(DocumentSelection(documentID: editor.store.documentID, text: selected, sourceHash: editor.state == "saved" ? editor.sourceHash : nil)) }) }
            } else { ProgressView(t("loading")).frame(maxWidth: .infinity, maxHeight: .infinity) }
            EditorStatusBar(state: editor.state, error: editor.error, language: language) { Task { _ = await editor.flush() } }
            if editor.state == "saveFailed" { HStack { Button(t("reload")) { Task { await editor.discardDraftAndReload() } }; Button(t("saveCopy"), action: saveCopy) }.controlSize(.small).padding(8) }
        }.task { editor.onSave = onSave; await editor.load() }.onDisappear { Task { _ = await editor.flush() } }
    }
    private func saveCopy() {
        guard let text = editor.text else { return }; let panel = NSSavePanel(); panel.nameFieldStringValue = editor.store.sourceURL.lastPathComponent
        if panel.runModal() == .OK, let url = panel.url { do { try DocumentDisk.write(Data(text.utf8), to: url, replace: false) } catch { editor.error = error.localizedDescription } }
    }
    private func convert() {
        guard let text = editor.text else { return }; let panel = NSSavePanel(); panel.nameFieldStringValue = editor.store.sourceURL.deletingPathExtension().lastPathComponent + ".ulnote"
        if panel.runModal() == .OK, let url = panel.url {
            let title = editor.store.sourceURL.deletingPathExtension().lastPathComponent
            Task { do { try await Task.detached { _ = try BlockNoteStore(packageURL: url, noteID: UUID().uuidString).importMarkdown(Data(text.utf8), title: title) }.value } catch { editor.error = error.localizedDescription } }
        }
    }
    private func exportPDF() {
        guard let text = editor.text else { return }
        let panel = NSSavePanel(); let title = editor.store.sourceURL.deletingPathExtension().lastPathComponent; panel.nameFieldStringValue = title + ".pdf"
        let blocks = editor.store.sourceURL.pathExtension.lowercased() == "md" ? MarkdownBlockImporter.blocks(text) : [NoteBlock(kind: .paragraph, text: text)]
        if panel.runModal() == .OK, let url = panel.url {
            Task { do { try await Task.detached { try BlockNoteExporter.pdf(BlockNoteDocument(id: UUID().uuidString, title: title, blocks: blocks), store: nil, to: url) }.value } catch { editor.error = error.localizedDescription } }
        }
    }
}

private struct PlainSourceText: NSViewRepresentable {
    @Binding var text: String
    let onSelection: (String) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView(); let view = scroll.documentView as! NSTextView
        view.isRichText = false; view.allowsUndo = true; view.isAutomaticQuoteSubstitutionEnabled = false; view.isAutomaticDashSubstitutionEnabled = false
        view.font = .monospacedSystemFont(ofSize: 14, weight: .regular); view.textContainerInset = NSSize(width: 16, height: 14)
        view.delegate = context.coordinator; view.string = text; return scroll
    }
    func updateNSView(_ view: NSScrollView, context: Context) { context.coordinator.parent = self; if let textView = view.documentView as? NSTextView, !textView.hasMarkedText(), textView.string != text { textView.string = text } }
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: PlainSourceText
        init(_ parent: PlainSourceText) { self.parent = parent }
        func textDidChange(_ notification: Notification) { if let view = notification.object as? NSTextView, !view.hasMarkedText() { parent.text = view.string } }
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let view = notification.object as? NSTextView, NSMaxRange(view.selectedRange()) <= (view.string as NSString).length else { return }
            parent.onSelection((view.string as NSString).substring(with: view.selectedRange()))
        }
    }
}

struct MarkdownDocumentPreview: View {
    let text: String
    var onOpenLink: ((DocumentPageLink) -> Void)? = nil
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                ForEach(MarkdownBlockImporter.blocks(text)) { block in
                    if block.kind == .table {
                        ForEach(block.cells.indices, id: \.self) { row in HStack { ForEach(block.cells[row].indices, id: \.self) { column in Text(.init(block.cells[row][column])).frame(maxWidth: .infinity, alignment: .leading).padding(6) } }.background(Color.secondary.opacity(row == 0 ? 0.12 : 0.04)) }
                    } else if block.kind == .code || block.kind == .rawMarkdown { Text(block.text).font(.system(.body, design: .monospaced)).padding(9).frame(maxWidth: .infinity, alignment: .leading).background(Color.secondary.opacity(0.08)) }
                    else { (Text(block.kind == .list ? "• " : block.kind == .todo ? (block.checked ? "☑ " : "☐ ") : block.kind == .quote ? "❝ " : "") + Text(AttributedString(block.attributedText))).font(block.kind == .heading ? .system(size: CGFloat(30 - 3 * block.level), weight: .semibold) : .body).frame(maxWidth: .infinity, alignment: .leading) }
                }
            }.padding(20).textSelection(.enabled)
        }.environment(\.openURL, OpenURLAction { url in if let reference = DocumentPageLink.parse(url), let onOpenLink { onOpenLink(reference); return .handled }; return .systemAction })
    }
}
