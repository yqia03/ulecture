import SwiftUI
import AppKit
import PDFKit
import UniformTypeIdentifiers

struct DocumentTranslationView: View {
    @ObservedObject var controller: DocumentTranslationController
    @ObservedObject var terminology: TextTranslationController
    var language: String = "en"
    var scopes: [TranslationScope] = []
    @State private var source: URL?
    @State private var sourceLanguage = "en"
    @State private var targetLanguage = "zh-Hans"
    @State private var mode: DocumentOutputMode = .translated
    @State private var engine: DocumentTranslationEngine?
    @State private var domain: TranslationDomain = .general
    @State private var scopeID = "text"
    @State private var saved: URL?
    @State private var localError: String?
    private func t(_ key: String) -> String { ConversionText.t(key, language) }
    private var selectedEngine: DocumentTranslationEngine {
        engine ?? (["md", "txt", "ulnote"].contains(source?.pathExtension.lowercased() ?? "") ? .native : .babelDOC)
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Text(t("fileTitle")).font(.title2.bold()); Spacer(); Text(CloudViewText.providerName(controller.settings.effectiveConfiguration.provider, language) + " · " + controller.settings.selectedModel).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle) }
            controls
            if !controller.resources.pdfReady { Text(t("resourcesMissing")).foregroundStyle(.red) }
            if selectedEngine == .babelDOC && !controller.babelDOCResources.ready { Text(t("babelDOCMissing")).foregroundStyle(.red) }
            if !controller.jobs.isEmpty {
                Picker(t("history"), selection: $controller.selectedID) { ForEach(controller.jobs) { Text($0.title + " · " + t($0.effectiveEngine.rawValue) + " · " + statusText($0)).tag(Optional($0.id)) } }
            }
            jobContent
            if let error = localError ?? controller.lastError { Text(t(error)).foregroundStyle(.red).font(.callout) }
            if let saved { HStack { Text(t("savedAt")); Button(saved.lastPathComponent) { NSWorkspace.shared.activateFileViewerSelecting([saved]) } }.font(.caption) }
        }.padding(20)
    }
    private var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Button(t("choose"), action: choose).accessibilityIdentifier("documentTranslation.choose")
                Text(source?.lastPathComponent ?? t("formats")).lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                Spacer()
            }
            Picker(t("scope"), selection: $scopeID) {
                Text(t("textScope")).tag("text")
                ForEach(scopes.filter { $0.id != "text" }) { Text($0.title).tag($0.id) }
            }.frame(maxWidth: 420)
            HStack(alignment: .top, spacing: 16) {
                Picker(t("engine"), selection: $engine) {
                    Text(t("automaticEngine")).tag(Optional<DocumentTranslationEngine>.none)
                    ForEach(DocumentTranslationEngine.allCases, id: \.self) { Text(t($0.rawValue)).tag(Optional($0)) }
                }.frame(maxWidth: 340).accessibilityIdentifier("documentTranslation.engine")
                Text(t(selectedEngine == .babelDOC ? "babelDOCHelp" : "nativeHelp")).font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16, alignment: .leading)], alignment: .leading, spacing: 10) {
                parameter("sourceLanguage") { Picker(t("sourceLanguage"), selection: $sourceLanguage) { ForEach(["en", "ja"], id: \.self) { Text(t($0)).tag($0) } } }
                parameter("targetLanguage") { Picker(t("targetLanguage"), selection: $targetLanguage) { ForEach(["zh-Hans", "zh-Hant"], id: \.self) { Text(t($0)).tag($0) } } }
                parameter("domain") { Picker(t("domain"), selection: $domain) { ForEach(TranslationDomain.allCases) { Text(t($0.rawValue)).tag($0) } } }
                parameter("mode") { Picker(t("mode"), selection: $mode) { ForEach(DocumentOutputMode.allCases, id: \.self) { Text(t($0.rawValue)).tag($0) } } }
            }
            HStack {
                if controller.isRunning { Button(t("cancel")) { controller.cancel() } }
                else { Button(t("translate")) {
                    guard let source else { return }; saved = nil; localError = nil
                    controller.start(source: source, sourceLanguage: sourceLanguage, targetLanguage: targetLanguage, mode: mode, domain: domain, scopeID: scopeID, glossaryRevision: terminology.glossary.revision, terms: terminology.glossary.snapshot(scopeID: scopeID, source: sourceLanguage, target: targetLanguage), engine: engine)
                }.buttonStyle(.borderedProminent).disabled(source == nil || (selectedEngine == .babelDOC && !controller.babelDOCResources.ready)).accessibilityIdentifier("documentTranslation.start") }
            }
        }
    }
    private func parameter<Content: View>(_ key: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t(key)).font(.caption).foregroundStyle(.secondary)
            content().labelsHidden()
        }
    }
    @ViewBuilder private var jobContent: some View {
            if let job = controller.selectedJob {
                HStack {
                    if controller.isRunning && [.preparing, .translating, .rendering].contains(job.status) { ProgressView().controlSize(.small) }
                    Text(statusText(job)).font(.callout)
                    Spacer()
                    if job.effectiveEngine == .native { Text("\(job.completedCount)/\(job.totalCount) " + t("regions")).font(.caption.monospacedDigit()) }
                    else if let progress = job.engineProgress { Text(progress, format: .percent.precision(.fractionLength(0))).font(.caption.monospacedDigit()) }
                    if !controller.isRunning && [.failed, .partial, .cancelled, .interrupted].contains(job.status) { Button(t(job.effectiveEngine == .babelDOC ? "babelDOCRetry" : "retry")) { controller.retry() } }
                }
                if job.effectiveEngine == .babelDOC, let progress = job.engineProgress, [.preparing, .translating, .rendering].contains(job.status) {
                    ProgressView(value: progress).accessibilityIdentifier("documentTranslation.engineProgress")
                }
                if let error = job.error { Text(t(error)).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
                if let url = controller.outputURL {
                    TranslatedPDFPreview(url: url).id(url.path + "-\(job.completedCount)-" + job.status.rawValue).frame(minHeight: 240).accessibilityIdentifier("documentTranslation.preview")
                    HStack {
                        Button(t("download")) { download(job) }
                        Button(t("saveAs")) { saveAs(job, companion: false) }
                        if controller.companionURL != nil { Button(t("companion")) { saveAs(job, companion: true) } }
                        Spacer()
                    }
                } else { ContentUnavailableView(t("fileTitle"), systemImage: "doc.text", description: Text(t("empty"))).frame(maxWidth: .infinity, maxHeight: .infinity) }
                coverage(job)
            } else { ContentUnavailableView(t("fileTitle"), systemImage: "doc.text", description: Text(t("empty"))).frame(maxWidth: .infinity, maxHeight: .infinity) }
    }
    private func coverage(_ job: DocumentTranslationJob) -> some View {
                DisclosureGroup(t("coverage")) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            if job.effectiveEngine == .babelDOC {
                                Text("BabelDOC" + (job.engineVersion.map { " · " + $0 } ?? "")).font(.caption.bold())
                                Text(t("babelDOCOutputReview")).font(.caption).foregroundStyle(.secondary)
                            }
                            ForEach(job.warnings, id: \.self) { Text(t($0)).font(.caption).foregroundStyle(.secondary) }
                            ForEach(job.pages) { page in pageCoverage(page, job) }
                            fontCoverage(job)
                            noteCoverage(job)
                            ForEach(job.regions.filter { $0.kind == "unprocessedImageText" || $0.error != nil }) { region in Text(t("page") + " \(region.page) · " + region.source).font(.caption).textSelection(.enabled) }
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }.frame(maxHeight: 150)
                }
    }
    private func statusText(_ job: DocumentTranslationJob) -> String {
        guard job.effectiveEngine == .babelDOC else { return t(job.status.rawValue) }
        switch job.status {
        case .translating: return t("babelDOCTranslating")
        case .completed: return t("babelDOCCompleted")
        case .cancelled: return t("babelDOCCancelled")
        case .interrupted: return t("babelDOCInterrupted")
        case .partial: return t("babelDOCPartial")
        default: return t(job.status.rawValue)
        }
    }
    private func pageCoverage(_ page: DocumentPageLayout, _ job: DocumentTranslationJob) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(mappingLabel(page, job)).font(.caption.bold())
            ForEach(page.warnings, id: \.self) { Text(t($0)).font(.caption).foregroundStyle(.secondary) }
            if page.rasterDPI != nil { Text("300 dpi").font(.caption).foregroundStyle(.secondary) }
            if let reason = page.rasterReason { Text(t(reason)).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private func fontCoverage(_ job: DocumentTranslationJob) -> some View {
        ForEach(job.fontReports ?? []) { report in
            VStack(alignment: .leading) {
                Text(fontLabel(report)).font(.caption)
                if !report.renderedFonts.isEmpty { Text(t("renderedFonts") + ": " + report.renderedFonts.joined(separator: ", ")).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private func fontLabel(_ report: DocumentFontReport) -> String {
        t("missingFont") + ": " + report.requestedFont + " · " + t("page") + " " + report.sourcePages.map { String($0) }.joined(separator: ", ")
    }
    private func noteCoverage(_ job: DocumentTranslationJob) -> some View {
        ForEach(job.slideNotes ?? []) { note in
            VStack(alignment: .leading) {
                Text(t("speakerNotes") + " · " + t("page") + " \(note.sourcePage)").font(.caption.bold())
                Text(note.text).font(.caption).textSelection(.enabled)
            }
        }
    }
    private func mappingLabel(_ page: DocumentPageLayout, _ job: DocumentTranslationJob) -> String {
        let pages = job.mapping.first { $0.sourcePage == page.number }?.outputPages.map { String($0) }.joined(separator: ", ") ?? "—"
        return t("page") + " \(page.number) → " + t("outputPages") + " " + pages
    }
    private func choose() {
        let panel = NSOpenPanel(); panel.allowsMultipleSelection = false; panel.canChooseDirectories = true; panel.treatsFilePackagesAsDirectories = false
        panel.allowedContentTypes = ["pdf", "ppt", "pptx", "md", "txt", "ulnote"].compactMap { UTType(filenameExtension: $0) }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        source = url; localError = nil
    }
    private func fileName(_ job: DocumentTranslationJob) -> String { job.title.replacingOccurrences(of: "/", with: "-") + "-" + job.targetLanguage + "-" + job.mode.rawValue }
    private func download(_ job: DocumentTranslationJob) {
        do { guard let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first else { throw DocumentConversionError.persistence }; saved = try controller.export(to: downloads.appendingPathComponent(fileName(job) + ".pdf")); localError = nil }
        catch { localError = DocumentTranslationController.code(error) }
    }
    private func saveAs(_ job: DocumentTranslationJob, companion: Bool) {
        let ext = companion ? (controller.companionURL?.pathExtension ?? "txt") : "pdf"
        let panel = NSSavePanel(); panel.nameFieldStringValue = fileName(job) + "." + ext
        if let type = UTType(filenameExtension: ext) { panel.allowedContentTypes = [type] }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { saved = try controller.export(to: url, companion: companion); localError = nil } catch { localError = DocumentTranslationController.code(error) }
    }
}

private struct TranslatedPDFPreview: NSViewRepresentable {
    let url: URL
    func makeNSView(context: Context) -> PDFView { let view = PDFView(); view.autoScales = true; view.displayMode = .singlePageContinuous; view.document = PDFDocument(url: url); return view }
    func updateNSView(_ view: PDFView, context: Context) { if view.document?.documentURL != url { view.document = PDFDocument(url: url) } }
}
