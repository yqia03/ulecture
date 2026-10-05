import SwiftUI
import UniformTypeIdentifiers

struct RootView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var prefs = AppPreferences.shared
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var creation: WorkspaceKind?
    @State private var renameItem: WorkspaceItem?
    @State private var deleteItem: WorkspaceItem?
    @State private var inputName = ""
    @StateObject private var dragScroller = WorkspaceDragScroller()
    var colors: AppPalette { AppPalette(dark: prefs.dark) }
    var body: some View {
        GeometryReader { geo in
            let sidebarWidth: CGFloat = geo.size.width < 800 ? 208 : 240
            HStack(spacing: 0) {
                // Keep the tree mounted so reopening the sidebar retains its
                // expansion/scroll state and does not rebuild every visible row.
                sidebar.frame(width: sidebarWidth)
                    .frame(width: model.sidebarVisible ? sidebarWidth : 0, alignment: .leading)
                    .clipped().opacity(model.sidebarVisible ? 1 : 0)
                    .allowsHitTesting(model.sidebarVisible).disabled(!model.sidebarVisible)
                    .accessibilityHidden(!model.sidebarVisible)
                colors.border.frame(width: model.sidebarVisible ? 1 : 0)
                VStack(spacing: 0) {
                    topBar
                    if let id = model.activeClassID, model.audio.phase == .capturing, id != model.selectedClassID || model.route != "workspace" {
                        HStack {
                            Image(systemName: "waveform"); Text(model.t("capturing"))
                            Button(model.items.first { $0.id == id }?.title ?? model.t("classroom")) { if let item = model.items.first(where: { $0.id == id }) { model.openItem(item) } }
                            Spacer(); Button(model.t("pause")) { model.pauseClass() }
                        }.padding(10).background(Color.orange.opacity(0.12))
                    }
                    if model.library?.isReadOnly == true { Text(model.t("readOnly")).font(.caption).foregroundStyle(.orange).padding(8) }
                    if model.busy { ProgressView().controlSize(.small).padding(5) }
                    content.frame(maxWidth: .infinity, maxHeight: .infinity)
                }.background(colors.canvas)
            }
        }
        .background(colors.canvas)
        .ignoresSafeArea(.container, edges: .top)
        .frame(minWidth: 680, minHeight: 540)
        .buttonStyle(QuietButtonStyle())
        .groupBoxStyle(QuietGroupBoxStyle())
        .tint(prefs.dark ? .white : Color(white: 0.16))
        .preferredColorScheme(prefs.dark ? .dark : .light)
        .environmentObject(model)
        .environmentObject(prefs)
        .onChange(of: model.sidebarVisible) { _, visible in if !visible { dragScroller.stop() } }
        .alert(model.t("error"), isPresented: Binding(get: { model.error != nil }, set: { if !$0 { model.error = nil } })) {
            Button(model.t("retry")) { model.retryUnsaved() }
            Button(model.t("close"), role: .cancel) { model.error = nil }
        } message: { Text(model.detail(model.error ?? "")) }
        .sheet(isPresented: Binding(get: { creation != nil || renameItem != nil }, set: { if !$0 { creation = nil; renameItem = nil } })) {
            VStack(alignment: .leading, spacing: 18) {
                Text(model.t(renameItem == nil ? "new" : "rename")).font(.title2)
                TextField(model.t("name"), text: $inputName).textFieldStyle(.roundedBorder).onSubmit(commitName)
                HStack { Spacer(); Button(model.t("cancel")) { creation = nil; renameItem = nil }; Button(model.t("save"), action: commitName).keyboardShortcut(.defaultAction).disabled(inputName.trimmingCharacters(in: .whitespaces).isEmpty) }
            }.padding(24).frame(width: 390)
        }
        .sheet(item: $model.sourcePreview) { source in
            VStack(alignment: .leading, spacing: 12) {
                Text(source.kind == .note ? model.t("noteSnapshot") : model.t("sources")).font(.title2)
                Text("v\(source.version) · \(source.hash.prefix(12))").font(.caption).foregroundStyle(.secondary)
                ScrollView { Text(source.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                Button(model.t("close")) { model.sourcePreview = nil }.keyboardShortcut(.cancelAction)
            }.padding(24).frame(width: 650, height: 500)
        }
        .sheet(item: $model.transcriptExportItem) { item in TranscriptExportSheet(item: item) }
        .confirmationDialog(model.t(deleteItem?.kind == .course ? "unmountProject" : "delete"), isPresented: Binding(get: { deleteItem != nil }, set: { if !$0 { deleteItem = nil } }), titleVisibility: .visible) {
            Button(model.t(deleteItem?.kind == .course ? "unmountProject" : "delete"), role: .destructive) { if let item = deleteItem { model.remove(item) }; deleteItem = nil }
        } message: { Text(model.t(deleteItem?.kind == .course ? "unmountHelp" : "deleteHelp")) }
        .overlay(alignment: .bottom) {
            if let notice = model.notice {
                HStack(alignment: .top) { Text(model.detail(notice)).font(.callout).textSelection(.enabled); if let url = model.exportedURL { Button(model.t("openFolder")) { NSWorkspace.shared.activateFileViewerSelecting([url]) } }; Button { model.notice = nil } label: { Image(systemName: "xmark") }.accessibilityLabel(model.t("close")) }
                    .padding(12).background(.regularMaterial, in: RoundedRectangle(cornerRadius: 9)).padding(16)
            }
        }
    }
    @ViewBuilder var content: some View {
        switch model.route {
        case "setup": SetupView()
        case "settings": SettingsView()
        case "textTool": TextTranslationView(controller: model.textTranslation, settings: model.textTranslationService, language: prefs.resolvedLanguage, scopes: model.items.filter { $0.kind == .course && $0.deletedAt == nil }.map { TranslationScope(id: $0.id, title: $0.title) })
        case "voiceTool":
            if let interpretation = model.interpretation {
                InterpretationRouteView(controller: interpretation, language: prefs.resolvedLanguage) { model.transcriptExportItem = $0 }
            }
            else { ContentUnavailableView(model.t("voiceTool"), systemImage: "waveform", description: Text(model.t("transcriptStorageUnavailable"))) }
        case "fileTool": DocumentTranslationView(controller: model.documentTranslation, terminology: model.textTranslation, language: prefs.resolvedLanguage, scopes: model.items.filter { $0.kind == .course && $0.deletedAt == nil }.map { TranslationScope(id: $0.id, title: $0.title) })
        case "trash": trash
        default: WorkspaceContentView()
        }
    }
    var pageTitle: String {
        if model.route == "workspace" { return model.selected?.title ?? model.t("workspace") }
        return model.t(model.route == "trash" ? "trash" : model.route)
    }
    var topBar: some View {
        HStack(spacing: 10) {
            if !model.sidebarVisible {
                Color.clear.frame(width: 66)
                Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { model.sidebarVisible = true } } label: { Image(systemName: "sidebar.left").frame(width: 28, height: 28) }
                    .buttonStyle(SidebarRowStyle()).accessibilityLabel(model.t("sidebar"))
            }
            Image(systemName: model.selected?.kind.symbol ?? (model.route == "settings" ? "gearshape" : "folder"))
                .font(.system(size: 13)).foregroundStyle(.secondary)
            Text(pageTitle).font(.system(size: 13, weight: .medium)).lineLimit(1)
            WindowDragRegion().frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .padding(.horizontal, 16).frame(height: 44)
        .background(colors.canvas)
        .overlay(alignment: .bottom) { colors.border.frame(height: 1) }
    }
    var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Color.clear.frame(width: 64)
                Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.15)) { model.sidebarVisible = false } } label: { Image(systemName: "sidebar.left").frame(width: 28, height: 28) }
                    .buttonStyle(SidebarRowStyle()).accessibilityLabel(model.t("sidebar"))
                WindowDragRegion().frame(maxWidth: .infinity, maxHeight: .infinity)
            }.padding(.horizontal, 12).frame(height: 44)
            HStack { Text("ULecture").font(.system(size: 15, weight: .semibold)); Spacer() }
                .padding(.horizontal, 16).padding(.top, 8).padding(.bottom, 16)
            if !prefs.hideSetup { nav("setup", "checklist") }
            nav("textTool", "character.bubble"); nav("fileTool", "doc.text"); nav("voiceTool", "waveform")
            HStack(spacing: 2) {
                Button { model.route = "workspace"; model.selectedID = nil } label: {
                    Text(model.t("workspace")).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading).frame(height: 30).contentShape(Rectangle())
                }.buttonStyle(.plain)
                creationMenu
            }.padding(.horizontal, 16).padding(.top, 22).padding(.bottom, 5)
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 2) {
                    ForEach(model.children(nil)) { item in WorkspaceTreeRow(item: item, depth: 0, rename: askRename, remove: { deleteItem = $0 }) }
                    if model.visibleItems.isEmpty { Text(model.t("noItems")).font(.system(size: 12)).foregroundStyle(.secondary).padding(.horizontal, 16).padding(.vertical, 12) }
                    Color.clear.frame(minHeight: 64).contentShape(Rectangle())
                        .onDrop(of: [.text, .fileURL], isTargeted: nil) { model.handleDrop($0, parentID: nil) }
                }
                .background(WorkspaceScrollAttachment(scroller: dragScroller).frame(width: 0, height: 0))
            }
            .environmentObject(dragScroller)
            .onDisappear { dragScroller.stop() }
            if let last = model.lastDeletedID { Button(model.t("undoDelete")) { model.restore(last) }.font(.caption).padding(10) }
            nav("trash", "trash")
            HStack {
                Button { prefs.dark.toggle() } label: { Image(systemName: prefs.dark ? "sun.max" : "moon").frame(width: 32, height: 32) }
                    .buttonStyle(SidebarRowStyle()).accessibilityLabel(model.t("appearance"))
                Spacer()
                Button { model.route = "settings" } label: { Label(model.t("settings"), systemImage: "gearshape").padding(.horizontal, 10).frame(height: 32).contentShape(Rectangle()) }
                    .buttonStyle(SidebarRowStyle(selected: model.route == "settings"))
            }.padding(.horizontal, 10).padding(.vertical, 10)
                .overlay(alignment: .top) { colors.border.frame(height: 1) }
        }.background(colors.sidebar)
    }
    func nav(_ key: String, _ icon: String) -> some View {
        Button { model.route = key } label: {
            HStack(spacing: 10) {
                Image(systemName: icon).font(.system(size: 14)).frame(width: 16)
                Text(model.t(key)).font(.system(size: 13)); Spacer(minLength: 0)
            }.padding(.horizontal, 10).frame(maxWidth: .infinity).frame(height: 34).contentShape(Rectangle())
        }.buttonStyle(SidebarRowStyle(selected: model.route == key)).padding(.horizontal, 8)
            .accessibilityIdentifier("sidebar.\(key)")
    }
    var creationMenu: some View {
        Menu {
            ForEach([WorkspaceKind.course, .folder, .note, .classroom], id: \.rawValue) { kind in
                Button(model.t(kind.rawValue)) { creation = kind; inputName = model.t(kind.rawValue) + " " + Date().formatted(date: .abbreviated, time: .omitted) }
                    .disabled(kind == .classroom && model.selected?.courseID == nil && model.selected?.kind != .course)
            }
            Divider(); Button(model.t("importPDF")) { model.importPDF(parentID: model.suitableParent(for: .pdf)) }
            Button(model.t("refreshProjects")) { model.refreshProjects() }
        } label: { Image(systemName: "plus") }.menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().accessibilityLabel(model.t("new"))
    }
    func askRename(_ item: WorkspaceItem) { renameItem = item; inputName = item.title }
    func commitName() {
        if let item = renameItem { model.rename(item, title: inputName) }
        else if let kind = creation { model.create(kind, title: inputName, parentID: model.suitableParent(for: kind)) }
        creation = nil; renameItem = nil
    }
    var trash: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(model.t("trash")).font(.largeTitle)
            ScrollView { LazyVStack { ForEach(model.items.filter { $0.deletedAt != nil }) { item in HStack { Label(item.title, systemImage: item.kind.symbol); Spacer(); Button(model.t("restore")) { model.restore(item.id) } }.padding(10) } } }
        }.padding(28)
    }
}

struct WorkspaceTreeRow: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var dragScroller: WorkspaceDragScroller
    let item: WorkspaceItem
    let depth: Int
    let rename: (WorkspaceItem) -> Void
    let remove: (WorkspaceItem) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var expanded = true
    @State private var hovered = false
    @FocusState private var rowFocused: Bool
    @FocusState private var actionFocused: Bool
    @State private var trackingMenus = Set<ObjectIdentifier>()
    @State private var dropPosition: WorkspaceDropPosition?
    @State private var newKind: WorkspaceKind?
    @State private var newName = ""
    private var container: Bool { [.course, .folder].contains(item.kind) }
    private var actionsVisible: Bool { hovered || rowFocused || actionFocused || !trackingMenus.isEmpty }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ZStack(alignment: .trailing) {
                HStack(spacing: 8) {
                        Color.clear.frame(width: 14)
                        Image(systemName: item.kind.symbol).frame(width: 16).foregroundStyle(.secondary)
                        Text(item.title).lineLimit(1)
                        if model.missingDocumentIDs.contains(item.id) || model.unavailableProjectIDs.contains(item.courseID ?? item.id) { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange).help(model.t("projectOffline")) }
                        Spacer(minLength: 0)
                    }
                    .padding(.leading, CGFloat(depth * 12 + 6)).padding(.trailing, container ? 58 : 32)
                    .frame(maxWidth: .infinity).frame(height: 34).contentShape(Rectangle())
                    .background(((model.selectedID == item.id && model.route == "workspace") || rowFocused || actionFocused ? AppPalette(dark: model.preferences.dark).selected : hovered ? AppPalette(dark: model.preferences.dark).hover : Color.clear), in: RoundedRectangle(cornerRadius: 8))
                    .onTapGesture { model.openItem(item) }
                    .onDrag { NSItemProvider(object: item.id as NSString) }
                    .focusable().focusEffectDisabled().focused($rowFocused)
                    .onKeyPress(.return) { model.openItem(item); return .handled }
                    .onKeyPress(.space) { model.openItem(item); return .handled }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(item.title).accessibilityAddTraits(.isButton)
                    .accessibilityAction { model.openItem(item) }
                    .accessibilityIdentifier("workspace.\(item.id)")
                HStack(spacing: 0) {
                    if container || !model.children(item.id).isEmpty {
                        Button { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.14)) { expanded.toggle() } } label: { Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.system(size: 9)).frame(width: 24, height: 30) }
                            .buttonStyle(.plain).accessibilityLabel(item.title)
                    }
                    Spacer().allowsHitTesting(false)
                    if container {
                        Menu {
                            ForEach([WorkspaceKind.folder, .note, .classroom], id: \.rawValue) { kind in
                                Button(model.t(kind.rawValue)) { newKind = kind; newName = model.t(kind.rawValue) }
                            }
                            Divider(); Button(model.t("importPDF")) { model.importPDF(parentID: item.id) }
                        } label: { Image(systemName: "plus").frame(width: 24, height: 28) }
                            .focused($actionFocused)
                            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().opacity(actionsVisible ? 1 : 0)
                            .accessibilityLabel(model.t("new")).accessibilityIdentifier("workspace.add.\(item.id)")
                    }
                    Menu { itemMenu } label: { Image(systemName: "ellipsis").frame(width: 24, height: 28) }
                        .focused($actionFocused)
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().opacity(actionsVisible ? 1 : 0).accessibilityLabel(model.t("move") + " / " + model.t("rename"))
                }.padding(.leading, CGFloat(depth * 12)).padding(.trailing, 4)
            }.font(.system(size: 12.5))
                .onHover { hovered = $0 }
                .onReceive(NotificationCenter.default.publisher(for: NSMenu.didBeginTrackingNotification)) { notification in
                    if actionsVisible, let menu = notification.object as? NSMenu { trackingMenus.insert(ObjectIdentifier(menu)) }
                }
                .onReceive(NotificationCenter.default.publisher(for: NSMenu.didEndTrackingNotification)) { notification in
                    if let menu = notification.object as? NSMenu { trackingMenus.remove(ObjectIdentifier(menu)) }
                }
                .overlay(alignment: dropPosition == .before ? .top : .bottom) {
                    if dropPosition == .before || dropPosition == .after { Rectangle().fill(Color.accentColor).frame(height: 2).allowsHitTesting(false) }
                }
                .overlay { if dropPosition == .into { RoundedRectangle(cornerRadius: 6).stroke(Color.accentColor, lineWidth: 1.5).allowsHitTesting(false) } }
                .contextMenu { itemMenu }
                .onDrop(of: [.text, .fileURL], delegate: WorkspaceRowDropDelegate(model: model, item: item, scroller: dragScroller, position: $dropPosition))
            if expanded { ForEach(model.children(item.id)) { child in WorkspaceTreeRow(item: child, depth: min(depth + 1, 7), rename: rename, remove: remove) } }
        }.padding(.horizontal, depth == 0 ? 8 : 0)
            .sheet(isPresented: Binding(get: { newKind != nil }, set: { if !$0 { newKind = nil } })) {
                VStack(alignment: .leading, spacing: 16) {
                    Text(model.t("new")).font(.title2)
                    TextField(model.t("name"), text: $newName).textFieldStyle(.roundedBorder)
                    HStack { Spacer(); Button(model.t("cancel")) { newKind = nil }; Button(model.t("save")) { if let kind = newKind { model.create(kind, title: newName, parentID: item.id) }; newKind = nil }.keyboardShortcut(.defaultAction).disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty) }
                }.padding(24).frame(width: 360)
            }
    }
    @ViewBuilder var itemMenu: some View {
        Button(model.t("open")) { model.openItem(item) }
        Button(model.t("rename")) { rename(item) }
        if item.kind != .course { Menu(model.t("move")) {
            ForEach(model.visibleItems.filter { [.course, .folder].contains($0.kind) && $0.id != item.id }) { parent in Button(parent.title) { model.move(item, to: parent.id) } }
        } }
        Button(model.t("moveUp")) { model.moveSibling(item, offset: -1) }
        Button(model.t("moveDown")) { model.moveSibling(item, offset: 1) }
        if [.course, .folder, .classroom].contains(item.kind) { Button(model.t("importPDF")) { model.importPDF(parentID: item.id) } }
        Divider()
        Button(model.t("transcriptsAndTranslations")) { model.transcriptExportItem = item }
        Divider(); Button(model.t(item.kind == .course ? "unmountProject" : "delete"), role: .destructive) { remove(item) }
    }
}

/// Frequent interpretation updates stay inside this route, not the course tree.
private struct InterpretationRouteView: View {
    @ObservedObject var controller: InterpretationController
    let language: String
    let export: (WorkspaceItem) -> Void
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Spacer()
                if let session = controller.selected {
                    Button(Localizer.string("transcriptsAndTranslations", language: language)) { export(session) }
                        .disabled(controller.transcripts.isEmpty && controller.online.captions.isEmpty)
                }
            }.padding(.horizontal, 20).padding(.top, 8)
            InterpretationView(controller: controller, language: language)
        }
    }
}
