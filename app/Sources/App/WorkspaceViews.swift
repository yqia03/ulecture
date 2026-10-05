import SwiftUI
import PDFKit
import AppKit

struct WorkspaceContentView: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let item = model.selected {
            if item.kind == .classroom { ClassroomView(classID: item.id) }
            else if item.kind == .pdf || item.kind == .note { DocumentStudyWorkspace(item: item) }
            else { WorkspaceCollectionView(item: item) }
        } else {
            VStack(alignment: .leading, spacing: 20) {
                Text(model.t("workspace")).font(.largeTitle.weight(.semibold))
                if model.visibleItems.isEmpty { Text(model.t("noItems")).foregroundStyle(.secondary) }
                if model.library == nil { Button(model.t("retry")) { model.openDefaultWorkspace() } }
                else {
                    Button(model.t("new") + " " + model.t("course")) { model.create(.course, title: model.t("course") + " " + Date().formatted(date: .numeric, time: .omitted)) }
                    ForEach(model.children(nil)) { item in
                        Button { model.openItem(item) } label: {
                            Label(item.title, systemImage: item.kind.symbol).frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                Spacer()
            }.padding(32).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        }
    }
}

struct WorkspaceAssistantPane: View {
    @EnvironmentObject var model: AppModel
    var body: some View {
        if let assistant = model.assistant { AIAssistantView(controller: assistant, language: model.preferences.resolvedLanguage) }
        else { ProgressView(model.t("loading")).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
}

/// The document remains mounted while a narrow window switches to the assistant tab.
struct DocumentStudyWorkspace: View {
    @EnvironmentObject var model: AppModel
    let item: WorkspaceItem
    @State private var showAssistant = false
    @State private var selectedTab = "document"
    @State private var documentWidth: Double = 680
    var body: some View {
        GeometryReader { geometry in
            let wide = geometry.size.width >= 850
            let minimum = 400.0, maximum = max(minimum, geometry.size.width - 327)
            let contentWidth = showAssistant && wide ? min(maximum, max(minimum, documentWidth)) : geometry.size.width
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    Text(item.title).font(.headline).lineLimit(1)
                    Spacer()
                    if showAssistant && !wide {
                        Picker("", selection: $selectedTab) { Text(EditorText.get("document", model.preferences.resolvedLanguage)).tag("document"); Text(EditorText.get("assistant", model.preferences.resolvedLanguage)).tag("assistant") }.pickerStyle(.segmented).labelsHidden().frame(maxWidth: 240)
                    }
                    Button { showAssistant.toggle(); selectedTab = showAssistant && !wide ? "assistant" : "document" } label: { Label(EditorText.get("assistant", model.preferences.resolvedLanguage), systemImage: showAssistant ? "sidebar.trailing" : "sparkles") }.buttonStyle(.bordered)
                }.padding(.horizontal, 14).padding(.vertical, 9)
                Divider()
                ZStack(alignment: .leading) {
                    document.frame(width: contentWidth).frame(maxHeight: .infinity).opacity(!wide && showAssistant && selectedTab == "assistant" ? 0 : 1).allowsHitTesting(wide || !showAssistant || selectedTab == "document").accessibilityHidden(!wide && showAssistant && selectedTab == "assistant")
                    if showAssistant {
                        HStack(spacing: 0) {
                            if wide { Color.clear.frame(width: contentWidth).allowsHitTesting(false); WorkspaceDivider(label: EditorText.get("assistant", model.preferences.resolvedLanguage), width: $documentWidth, range: minimum...maximum) }
                            WorkspaceAssistantPane().frame(maxWidth: .infinity, maxHeight: .infinity)
                        }.opacity(wide || selectedTab == "assistant" ? 1 : 0).allowsHitTesting(wide || selectedTab == "assistant").accessibilityHidden(!wide && selectedTab != "assistant")
                    }
                }
            }
        }
    }
    @ViewBuilder private var document: some View { if item.kind == .pdf { PDFReader(item: item) } else { NotePane(note: item, pdf: nil) } }
}

struct WorkspaceCollectionView: View {
    @EnvironmentObject var model: AppModel
    let item: WorkspaceItem
    @State private var pendingClasses = Set<String>()
    @State private var recordedClasses = Set<String>()
    var children: [WorkspaceItem] { model.children(item.id) }
    var classes: [WorkspaceItem] {
        (item.kind == .course ? model.visibleItems.filter { $0.kind == .classroom && $0.courseID == item.id } : children.filter { $0.kind == .classroom })
            .sorted { $0.createdAt > $1.createdAt }
    }
    var dates: [Date] { Array(Set(classes.map { Calendar.current.startOfDay(for: $0.createdAt) })).sorted(by: >) }
    var badgeKey: String { item.id + classes.map { $0.id + String($0.updatedAt.timeIntervalSinceReferenceDate) + (model.classRecords[$0.id]?.state ?? "") }.joined() }
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(item.title).font(.largeTitle.weight(.semibold))
            HStack {
                if item.kind == .course || item.courseID != nil { Button(model.t("new") + " " + model.t("classroom")) { model.create(.classroom, title: Date().formatted(date: .abbreviated, time: .shortened), parentID: item.id) } }
                Button(model.t("new") + " " + model.t("note")) { model.create(.note, title: model.t("note"), parentID: item.id) }
                Button(model.t("importPDF")) { model.importPDF(parentID: item.id) }
                Spacer(); WorkspaceExportMenu(item: item)
            }
            List {
                let other = children.filter { $0.kind != .classroom }
                if !other.isEmpty { Section(model.t("otherMaterials")) { ForEach(other) { row($0) } } }
                ForEach(dates, id: \.self) { date in
                    Section(date.formatted(date: .complete, time: .omitted)) {
                        ForEach(classes.filter { Calendar.current.isDate($0.createdAt, inSameDayAs: date) }) { row($0) }
                    }
                }
            }.listStyle(.plain)
        }.padding(26)
        .task(id: badgeKey) { await loadBadges() }
    }
    func row(_ child: WorkspaceItem) -> some View {
        Button { model.openItem(child) } label: {
            HStack(spacing: 12) {
                Label(child.title, systemImage: child.kind.symbol)
                Spacer()
                if let record = model.classRecords[child.id] {
                    VStack(alignment: .trailing, spacing: 4) {
                        Text(child.createdAt.formatted(date: .abbreviated, time: .shortened))
                        HStack(spacing: 8) {
                            Text(model.t(record.state))
                            if model.clouds[child.id].map({ $0.pendingCount > 0 }) ?? pendingClasses.contains(child.id) { Label(model.t("pendingTranslation"), systemImage: "clock") }
                            if recordedClasses.contains(child.id) { Label(model.t("recordingAvailable"), systemImage: "waveform") }
                        }
                    }.font(.caption).foregroundStyle(.secondary)
                }
            }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8).contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
    func loadBadges() async {
        guard let library = model.library else { return }
        let ids = classes.map(\.id)
        do {
            let result = try await Task.detached { () -> (Set<String>, Set<String>) in
                var pending = Set<String>(), recorded = Set<String>()
                for id in ids {
                    if let cloud = try library.record(collection: "cloud-state", id: id, as: CloudState.self), cloud.jobs.contains(where: { $0.status != .completed && $0.status != .obsolete }) { pending.insert(id) }
                    if !(try library.recordings(classroomID: id)).isEmpty { recorded.insert(id) }
                }
                return (pending, recorded)
            }.value
            guard !Task.isCancelled else { return }
            pendingClasses = result.0; recordedClasses = result.1
        } catch { model.report(error) }
    }
}

struct ClassroomView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: AppPreferences
    @ObservedObject private var layout = WorkspaceLayoutPreferences.shared
    let classID: String
    var item: WorkspaceItem? { model.items.first { $0.id == classID } }
    var record: ClassroomRecord { model.classRecords[classID] ?? ClassroomRecord(id: classID) }
    var hasSide: Bool { ["transcript", "summary"].contains(prefs.panel) }
    var saveStatus: String {
        let notes = model.visibleItems.filter { $0.kind == .note && $0.classroomID == classID }
        if model.pendingEndIDs.contains(classID) || model.pendingClassRecords[classID] != nil || model.pendingTranscripts.contains(where: { $0.classroomID == classID }) || model.pendingRecordings.contains(where: { $0.sessionID == classID }) || model.pendingGaps.contains(where: { $0.sessionID == classID }) || model.clouds[classID]?.lastError == .persistence || notes.contains(where: { model.saveStates[$0.id] == "saveFailed" }) { return "saveFailed" }
        if notes.contains(where: { model.saveStates[$0.id] == "saving" }) { return "saving" }
        return "saved"
    }
    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                HStack(spacing: 12) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(item?.title ?? model.t("classroom")).font(.headline).lineLimit(1)
                        HStack(spacing: 6) {
                            Text(model.t(model.pendingEndIDs.contains(classID) ? "pendingUnsaved" : record.state))
                            Text("· " + model.t(record.inputSource == "system" ? "systemAudio" : "microphone"))
                            Text("· " + model.t(saveStatus)).foregroundStyle(saveStatus == "saveFailed" ? .red : .secondary)
                        }.font(.caption).foregroundStyle(.secondary)
                    }
                    TimelineView(.periodic(from: .now, by: 1)) { _ in
                        let live = model.audio.sessionID == classID && [.capturing, .starting].contains(model.audio.phase)
                        let offset = live ? max(Double(record.timelineMilliseconds) / 1000, model.audio.currentOffset) : Double(record.timelineMilliseconds) / 1000
                        Text(Self.clockLabel(offset)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                            .fixedSize().accessibilityLabel(model.t("elapsedTime") + " " + Self.clockLabel(offset))
                    }
                    Spacer()
                    if record.state != "ended" {
                        if model.activeClassID == classID && model.audio.phase == .capturing { Button(model.t("pause")) { model.pauseClass() }.keyboardShortcut("p", modifiers: [.command, .shift]) }
                        else { Button(model.t(record.state == "draft" ? "start" : "resume")) { model.startClass(classID) }.disabled(model.busy || model.audio.draining || model.pendingEndIDs.contains(classID) || model.library?.isReadOnly == true) }
                        Button(model.t("end")) { model.endClass(classID) }.disabled(model.busy || model.library?.isReadOnly == true)
                    }
                    if let item { WorkspaceExportMenu(item: item) }
                }.padding(16)
                Divider()
                controls(wide: geo.size.width >= 1000)
                if geo.size.width >= 1000 { wideLayout(width: geo.size.width) }
                else if geo.size.width >= 760 && prefs.panel == "notes" {
                    HSplitView { pdf.frame(minWidth: 350); notes.frame(minWidth: 290) }
                } else { selectedPanel }
            }
        }
        .onAppear { model.ensureCloud(classID); if let note = model.classroomNote(classID) { model.loadDraft(note.id) } }
    }
    static func clockLabel(_ offset: Double) -> String {
        let seconds = Int(max(0, offset))
        return String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
    }
    func controls(wide: Bool) -> some View {
        HStack(spacing: 10) {
            if wide {
                Button(model.t(layout.showNotes ? "hideNotes" : "showNotes")) { layout.showNotes.toggle() }
                Button(model.t("transcript")) { prefs.panel = prefs.panel == "transcript" ? "notes" : "transcript" }
                    .fontWeight(prefs.panel == "transcript" ? .semibold : .regular)
                Button(EditorText.get("assistant", model.preferences.resolvedLanguage)) { prefs.panel = prefs.panel == "summary" ? "notes" : "summary" }
                    .fontWeight(prefs.panel == "summary" ? .semibold : .regular)
                if hasSide { Button(model.t("closeSidePanel")) { prefs.panel = "notes" } }
            } else {
                Picker("", selection: $prefs.panel) {
                    Text("PDF").tag("pdf"); Text(model.t("notes")).tag("notes"); Text(model.t("transcript")).tag("transcript"); Text(EditorText.get("assistant", model.preferences.resolvedLanguage)).tag("summary")
                }.pickerStyle(.segmented).labelsHidden()
            }
            Spacer(minLength: 0)
            if !model.classroomPDFs(classID).isEmpty {
                Menu("PDF") { ForEach(model.classroomPDFs(classID)) { pdf in Button(pdf.title) { model.pdfSelection[classID] = pdf.id } } }.fixedSize()
            }
            Button { model.importPDF(parentID: classID) } label: { Image(systemName: "doc.badge.plus") }.accessibilityLabel(model.t("importPDF"))
        }.controlSize(.small).padding(10)
    }
    @ViewBuilder func wideLayout(width: CGFloat) -> some View {
        let minimumPDF = 320.0
        let reserved = (layout.showNotes ? 287.0 : 0) + (hasSide ? 307.0 : 0)
        let pdfMax = max(minimumPDF, width - reserved)
        let pdfSize = min(pdfMax, max(minimumPDF, layout.pdfWidth))
        HStack(spacing: 0) {
            pdf.frame(width: layout.showNotes || hasSide ? pdfSize : width)
            if layout.showNotes || hasSide {
                WorkspaceDivider(label: model.t("resizePanel") + " PDF", width: $layout.pdfWidth, range: minimumPDF...pdfMax)
            }
            if layout.showNotes {
                if hasSide {
                    let notesMax = max(280, width - pdfSize - 314)
                    notes.frame(width: min(notesMax, max(280, layout.notesWidth)))
                    WorkspaceDivider(label: model.t("resizePanel") + " " + model.t("notes"), width: $layout.notesWidth, range: 280...notesMax)
                } else { notes.frame(maxWidth: .infinity) }
            }
            if hasSide { side.frame(maxWidth: .infinity) }
        }
    }
    @ViewBuilder var selectedPanel: some View {
        switch prefs.panel { case "pdf": pdf; case "transcript", "summary": side; default: notes }
    }
    @ViewBuilder var side: some View {
        if prefs.panel == "summary" { WorkspaceAssistantPane() } else { TranscriptPane(classID: classID, audio: model.audio) }
    }
    @ViewBuilder var notes: some View {
        if let note = model.classroomNote(classID) { NotePane(note: note, pdf: model.selectedPDF(classID), classroomContextID: classID) }
        else { Button(model.t("new") + " " + model.t("note")) { model.create(.note, title: model.t("notes"), parentID: classID) }.padding(24) }
    }
    @ViewBuilder var pdf: some View {
        if let item = model.selectedPDF(classID) { PDFReader(item: item) }
        else {
            VStack(spacing: 18) {
                Image(systemName: "doc.richtext").font(.system(size: 40)).foregroundStyle(.tertiary)
                Text(model.t("noPDF")); Button(model.t("importPDF")) { model.importPDF(parentID: classID) }
                Text(model.t("pdfHelp")).font(.caption).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }.padding(30).frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

struct PDFReader: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var navigation = DocumentNavigationState.shared
    let item: WorkspaceItem
    @State private var sourceURL: URL?
    @State private var sidecarURL: URL?
    @State private var failure: String?
    @State private var conversionWarnings: [String] = []
    @State private var usingPreservedSource = false
    @State private var resolutionGeneration = UUID()
    var body: some View {
        VStack(spacing: 0) {
            if usingPreservedSource {
                HStack {
                    Text(EditorText.get("oldVersion", model.preferences.resolvedLanguage))
                    Spacer()
                    Button(EditorText.get("currentVersion", model.preferences.resolvedLanguage)) {
                        navigation.request(documentID: item.id, sourceHash: nil, page: model.pdfPages[item.id] ?? 1)
                        Task { await resolve() }
                    }
                }.font(.caption).padding(10).background(Color.accentColor.opacity(0.08))
            }
            if !conversionWarnings.isEmpty { Text(conversionWarnings.map { ConversionText.t($0, model.preferences.resolvedLanguage) }.joined(separator: "\n")).font(.caption).foregroundStyle(.secondary).padding(10).frame(maxWidth: .infinity, alignment: .leading) }
            if let sourceURL, let sidecarURL {
                AnnotatedPDFEditor(documentID: item.id, sourceURL: sourceURL, sidecarURL: sidecarURL,
                                   initialPage: model.pdfPages[item.id] ?? 1, language: model.preferences.resolvedLanguage, navigationRequest: navigation.requests[item.id],
                                   onSelection: { model.documentSelection = $0 }, onPage: { model.pdfPages[item.id] = $0 })
                    .id(item.id + sourceURL.path)
            } else if let failure {
                VStack(spacing: 12) { Text(EditorText.failure(ConversionText.t(model.detail(failure), model.preferences.resolvedLanguage), model.preferences.resolvedLanguage)).textSelection(.enabled); Button(model.t("retry")) { Task { await resolve() } } }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { ProgressView(model.t("loading")).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.task(id: item.id + String(item.updatedAt.timeIntervalSince1970)) { await resolve() }
            .onChange(of: navigation.requests[item.id]?.sourceHash) { _, _ in
                if sourceURL == nil { Task { await resolve() } }
            }
    }
    private func resolve() async {
        let generation = UUID(); resolutionGeneration = generation
        sourceURL = nil; failure = nil; conversionWarnings = []; usingPreservedSource = false
        do {
            let url = try model.documentURL(for: item)
            let directory = try model.annotationDirectory(for: item)
            if ["ppt", "pptx"].contains(url.pathExtension.lowercased()) {
                let prepared = try await DocumentPreparation.prepareForReading(source: url, cacheDirectory: directory.appendingPathComponent("conversion"))
                guard !Task.isCancelled, resolutionGeneration == generation else { return }
                sourceURL = prepared.pdfURL; conversionWarnings = prepared.warnings
            } else { guard !Task.isCancelled, resolutionGeneration == generation else { return }; sourceURL = url }
            sidecarURL = directory
        } catch {
            guard !Task.isCancelled, resolutionGeneration == generation else { return }
            let originalFailure = error.localizedDescription
            // Catalogs keep the missing locator and sidecar, so a fixed AI/note reference can
            // still open its exact preserved reading PDF even when the original PDF/PPT is gone.
            if let hash = navigation.requests[item.id]?.sourceHash {
                do {
                    let directory = try model.annotationDirectory(for: item)
                    let original = try? model.workspaceCatalog?.documentURL(id: item.id, allowMissing: true)
                    let location = try await Task.detached {
                        try PreservedPDFReadingSource.resolve(documentID: item.id, originalURL: original, sidecarURL: directory, sourceHash: hash)
                    }.value
                    guard !Task.isCancelled, resolutionGeneration == generation, navigation.requests[item.id]?.sourceHash == hash else { return }
                    sourceURL = location.sourceURL; sidecarURL = location.sidecarURL; usingPreservedSource = true
                    return
                } catch { if !Task.isCancelled, resolutionGeneration == generation { failure = error.localizedDescription } }
            } else { failure = originalFailure }
        }
    }
}

struct NotePane: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var navigation = DocumentNavigationState.shared
    let note: WorkspaceItem
    let pdf: WorkspaceItem?
    var classroomContextID: String? = nil
    @State private var packageURL: URL?
    @State private var textURL: URL?
    @State private var draftURL: URL?
    @State private var failure: String?
    @State private var referenceID = ""
    @State private var referencePage = 1
    @State private var reference: NotePageReference?
    @State private var referenceFailure: String?
    private var referenceDocuments: [WorkspaceItem] {
        let sessions = model.visibleItems.filter { $0.kind == .classroom && model.projectDocumentIDs(for: $0.id).contains(note.id) }
        let linked = Set(sessions.flatMap { model.projectDocumentIDs(for: $0.id) })
        return model.visibleItems.filter { $0.kind == .pdf && ($0.courseID == note.courseID || linked.contains($0.id)) }
            .sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
    }
    private var pageLink: DocumentPageLink? {
        if let pdf { return navigation.currentHashes[pdf.id].map { DocumentPageLink(documentID: pdf.id, page: model.pdfPages[pdf.id] ?? 1, label: pdf.title, sourceHash: $0) } }
        return reference?.link(page: referencePage)
    }
    var body: some View {
        VStack(spacing: 0) {
            if let classID = classroomContextID {
                HStack {
                    Menu(note.title) {
                        let linked = model.projectDocumentIDs(for: classID)
                        ForEach(model.visibleItems.filter { $0.kind == .note && linked.contains($0.id) }) { value in Button(value.title) { model.classNoteIDs[classID] = value.id } }
                        Divider(); Button(model.t("new") + " " + model.t("note")) { model.create(.note, title: model.t("notes"), parentID: classID) }
                    }.menuStyle(.borderlessButton).menuIndicator(.hidden).font(.headline)
                    Spacer()
                }.padding(.horizontal, 12).padding(.top, 8)
            }
            if let textURL, let draftURL {
                TextSourceEditor(documentID: note.id, sourceURL: textURL, draftURL: draftURL, language: model.preferences.resolvedLanguage,
                                 onSelection: { model.documentSelection = $0 }, onOpenLink: openLink).id(note.id + textURL.path)
            } else if let packageURL {
                if pdf == nil, !referenceDocuments.isEmpty {
                    HStack(spacing: 8) {
                        Picker(EditorText.get("document", model.preferences.resolvedLanguage), selection: $referenceID) {
                            Text(EditorText.get("choosePageDocument", model.preferences.resolvedLanguage)).tag("")
                            ForEach(referenceDocuments) { Text($0.title).tag($0.id) }
                        }.labelsHidden().frame(maxWidth: .infinity)
                        if let reference {
                            Text(EditorText.get("page", model.preferences.resolvedLanguage))
                            TextField("", value: $referencePage, format: .number).frame(width: 42).textFieldStyle(.roundedBorder)
                                .onChange(of: referencePage) { _, value in referencePage = min(reference.pageCount, max(1, value)) }
                            Stepper("", value: $referencePage, in: 1...reference.pageCount).labelsHidden()
                            Text("/ \(reference.pageCount)").foregroundStyle(.secondary)
                        } else if !referenceID.isEmpty && referenceFailure == nil { ProgressView().controlSize(.small) }
                    }.controlSize(.small).padding(.horizontal, 12).padding(.vertical, 8)
                    if let referenceFailure { Text(referenceFailure).font(.caption).foregroundStyle(.orange).padding(.horizontal, 12) }
                }
                BlockNoteEditor(packageURL: packageURL, noteID: note.id, title: note.title, language: model.preferences.resolvedLanguage,
                                currentPageLink: pageLink, navigationRequest: navigation.blockRequests[note.id], onSelection: { model.documentSelection = $0 }, onOpenLink: openLink,
                                onSave: { _ in model.saveStates[note.id] = "saved" }).id(note.id + packageURL.path)
            } else if let failure {
                VStack(spacing: 12) { Text(EditorText.failure(model.detail(failure), model.preferences.resolvedLanguage)).textSelection(.enabled); Button(model.t("retry")) { Task { await resolve() } } }.padding(24).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else { ProgressView(model.t("loading")).frame(maxWidth: .infinity, maxHeight: .infinity) }
        }.task(id: note.id + String(note.updatedAt.timeIntervalSince1970)) { await resolve() }
            .task(id: referenceID) { await resolvePageReference() }
    }
    private func resolvePageReference() async {
        reference = nil; referenceFailure = nil
        guard let item = referenceDocuments.first(where: { $0.id == referenceID }) else { return }
        do {
            let source = try model.documentURL(for: item), sidecar = try model.annotationDirectory(for: item)
            let pdfURL: URL
            if ["ppt", "pptx"].contains(source.pathExtension.lowercased()) {
                pdfURL = try await DocumentPreparation.prepareForReading(source: source, cacheDirectory: sidecar.appendingPathComponent("conversion")).pdfURL
            } else { pdfURL = source }
            let value = try await Task.detached { try NotePageReference.prepare(documentID: item.id, title: item.title, pdfURL: pdfURL, sidecarURL: sidecar) }.value
            guard !Task.isCancelled, referenceID == item.id else { return }
            reference = value; referencePage = min(value.pageCount, max(1, model.pdfPages[item.id] ?? 1))
        } catch { if !Task.isCancelled { referenceFailure = EditorText.failure(ConversionText.t(model.detail(error.localizedDescription), model.preferences.resolvedLanguage), model.preferences.resolvedLanguage) } }
    }
    private func resolve() async {
        packageURL = nil; textURL = nil; draftURL = nil; failure = nil
        guard let library = model.library else { failure = model.t("chooseProjectFirst"); return }
        let catalog = model.workspaceCatalog
        do {
            let location = try await Task.detached(priority: .userInitiated) {
                try NoteOpenLocation.resolve(item: note, library: library, catalog: catalog)
            }.value
            guard !Task.isCancelled else { return }
            packageURL = location.packageURL; textURL = location.textURL; draftURL = location.draftURL
        } catch { if !Task.isCancelled { failure = error.localizedDescription } }
    }
    private func openLink(_ link: DocumentPageLink) {
        guard let item = model.visibleItems.first(where: { $0.id == link.documentID || $0.assetID?.lowercased() == link.documentID.lowercased() }) else { model.error = model.t("sourceSnapshotOnly"); return }
        model.pdfPages[item.id] = link.page
        navigation.request(documentID: item.id, sourceHash: link.sourceHash, page: link.page)
        if let classID = classroomContextID { model.pdfSelection[classID] = item.id; model.preferences.panel = "pdf" }
        else { model.openItem(item) }
    }
}

struct MarkdownNotePreview: View {
    let text: String
    var body: some View { MarkdownDocumentPreview(text: text) }
}
