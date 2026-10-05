import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct TranslationScope: Identifiable { var id: String; var title: String }

struct TextTranslationView: View {
    @ObservedObject var controller: TextTranslationController
    @ObservedObject var settings: CloudServiceSettings
    var language: String = "en"
    var scopes: [TranslationScope] = []
    @State private var showTerms = false
    @State private var editing: TranslationTerm?
    @State private var message: String?
    @State private var pendingImport: Data?
    @State private var importFormat = "json"
    @State private var conflict = false
    @State private var conflictDifference = ""
    private func t(_ key: String) -> String { CloudViewText.t(key, language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text(t("title")).font(.title2.bold())
                Spacer()
                Label(CloudViewText.providerName(settings.effectiveConfiguration.provider, language) + " · " + settings.selectedModel, systemImage: "cloud").foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 220), spacing: 16, alignment: .leading)], alignment: .leading, spacing: 10) {
                languagePicker("sourceLanguage", selection: Binding(get: { controller.document.sourceLanguage }, set: controller.setSourceLanguage), options: ["en", "ja"])
                languagePicker("targetLanguage", selection: Binding(get: { controller.document.targetLanguage }, set: controller.setTargetLanguage), options: ["zh-Hans", "zh-Hant"])
                VStack(alignment: .leading, spacing: 4) {
                    Text(t("domain")).font(.caption).foregroundStyle(.secondary)
                    Picker(t("domain"), selection: Binding(get: { controller.document.domain }, set: controller.setDomain)) { ForEach(TranslationDomain.allCases) { Text(t($0.rawValue)).tag($0) } }.labelsHidden()
                }
            }
            HSplitView {
                VStack(alignment: .leading, spacing: 8) {
                    Text(t("source")).font(.headline)
                    TextEditor(text: Binding(get: { controller.document.input }, set: controller.updateInput)).font(.body).scrollContentBackground(.hidden).padding(8).background(.background, in: RoundedRectangle(cornerRadius: 10)).accessibilityIdentifier("translation.input")
                }.frame(minWidth: 200)
                VStack(alignment: .leading, spacing: 8) {
                    HStack { Text(t("target")).font(.headline); Spacer(); Button(t("copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(controller.result, forType: .string) }.disabled(controller.result.isEmpty) }
                    ScrollView { Text(controller.result).frame(maxWidth: .infinity, alignment: .topLeading).padding(12).textSelection(.enabled) }.background(.background, in: RoundedRectangle(cornerRadius: 10)).accessibilityIdentifier("translation.result")
                }.frame(minWidth: 200)
            }.frame(minHeight: 180)
            HStack {
                if controller.isRunning {
                    ProgressView().controlSize(.small)
                    Button(t("cancel")) { controller.cancel() }.accessibilityIdentifier("translation.cancel")
                } else {
                    Button(t("translate")) { controller.translate() }.buttonStyle(.borderedProminent).disabled(controller.document.input.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || controller.storageBlocked || controller.glossaryStorageBlocked).accessibilityIdentifier("translation.start")
                    if controller.canRetry { Button(t("retry")) { controller.translate(retry: true) } }
                }
                Button(t("clear")) { controller.clear() }.disabled(controller.document.input.isEmpty)
                Spacer()
                Text(t(controller.document.status.rawValue) + (controller.totalChunks > 0 ? " · \(controller.completedChunks)/\(controller.totalChunks)" : "")).font(.caption).foregroundStyle(.secondary)
            }
            if let error = controller.lastError { Text(CloudViewText.failure(error, language)).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            if let message { Text(message).font(.callout).foregroundStyle(.red) }
            DisclosureGroup(t("terms"), isExpanded: $showTerms) { termsPanel }.accessibilityIdentifier("translation.terms")
        }.padding(20)
        .onDisappear { controller.flush() }
        .sheet(item: $editing) { term in TranslationTermEditor(term: term, controller: controller, language: language) }
        .confirmationDialog(t("conflict"), isPresented: $conflict, titleVisibility: .visible) {
            Button(t("keep")) { importPending(.keepExisting) }
            Button(t("replace")) { importPending(.replaceExisting) }
            Button(t("cancel"), role: .cancel) { pendingImport = nil }
        } message: { Text(conflictDifference) }
    }
    private func languagePicker(_ label: String, selection: Binding<String>, options: [String]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t(label)).font(.caption).foregroundStyle(.secondary)
            Picker(t(label), selection: selection) { ForEach(options, id: \.self) { Text(t($0)).tag($0) } }.labelsHidden()
        }
    }
    private var termsPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(t("termHelp")).font(.caption).foregroundStyle(.secondary)
            HStack {
                Picker(t("scope"), selection: Binding(get: { controller.document.scopeID }, set: controller.setScope)) {
                    Text(t("textScope")).tag("text")
                    ForEach(scopes.filter { $0.id != "text" }) { Text($0.title).tag($0.id) }
                }
                Button(t("add")) { editing = TranslationTerm(sourceLanguage: controller.document.sourceLanguage, source: "", targetLanguage: controller.document.targetLanguage, translation: "", scopeID: controller.document.scopeID) }
                Button(t("import")) { chooseImport() }
                Menu(t("export")) { Button("JSON") { export("json") }; Button("CSV") { export("csv") } }.disabled(controller.currentTerms.isEmpty)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(controller.currentTerms) { term in
                        HStack {
                            Toggle(t("enabled"), isOn: Binding(get: { term.enabled }, set: { enabled in var changed = term; changed.enabled = enabled; attempt { try controller.saveTerm(changed) } })).labelsHidden().accessibilityLabel(t("enabled") + ": " + term.source)
                            VStack(alignment: .leading, spacing: 3) { Text(term.source + " → " + term.translation); Text(t(term.sourceLanguage) + " · " + t(term.targetLanguage) + (term.note.isEmpty ? "" : " · " + term.note)).font(.caption).foregroundStyle(.secondary).lineLimit(2) }
                            Spacer()
                            Button(t("edit")) { editing = term }
                            Button(t("delete")) { attempt { try controller.removeTerm(term.id) } }
                        }.padding(8).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }.frame(maxHeight: 180)
            Text(t("importHelp")).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
        }.padding(.top, 8)
    }
    private func attempt(_ operation: () throws -> Void) { do { try operation(); message = nil } catch is TranslationTermConflict { message = t("conflict") } catch { message = CloudViewText.failure(cloudFailure(error), language) } }
    private func chooseImport() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json, .commaSeparatedText]; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        do {
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            guard (attributes[.size] as? NSNumber)?.intValue ?? 0 <= 2_000_000 else { throw CloudFailure.responseTooLarge }
            pendingImport = try Data(contentsOf: url); importFormat = url.pathExtension.lowercased() == "csv" ? "csv" : "json"
            importPending(.rejectConflicts)
        } catch { message = CloudViewText.failure(cloudFailure(error), language) }
    }
    private func importPending(_ policy: TermImportPolicy) {
        guard let data = pendingImport else { return }
        do { _ = try controller.importTerms(data, format: importFormat, policy: policy); pendingImport = nil; message = nil }
        catch let problem as TranslationTermConflict { conflictDifference = problem.existing.source + ": " + problem.existing.translation + " → " + problem.incoming.translation; conflict = true }
        catch { pendingImport = nil; message = CloudViewText.failure(cloudFailure(error), language) }
    }
    private func export(_ format: String) {
        let panel = NSSavePanel(); panel.allowedContentTypes = format == "csv" ? [.commaSeparatedText] : [.json]; panel.nameFieldStringValue = "ULecture-terms." + format
        guard panel.runModal() == .OK, let url = panel.url else { return }
        attempt { try controller.exportTerms(format: format).write(to: url, options: .atomic) }
    }
}

private struct TranslationTermEditor: View {
    @State var term: TranslationTerm
    @ObservedObject var controller: TextTranslationController
    let language: String
    @Environment(\.dismiss) private var dismiss
    @State private var error: String?
    private func t(_ key: String) -> String { CloudViewText.t(key, language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(t("terms")).font(.headline)
            HStack {
                Picker(t("sourceLanguage"), selection: $term.sourceLanguage) { ForEach(["en", "ja"], id: \.self) { Text(t($0)).tag($0) } }
                Picker(t("targetLanguage"), selection: $term.targetLanguage) { ForEach(["zh-Hans", "zh-Hant"], id: \.self) { Text(t($0)).tag($0) } }
            }
            TextField(t("source"), text: $term.source)
            TextField(t("target"), text: $term.translation)
            TextField(t("note"), text: $term.note, axis: .vertical).lineLimit(2...4)
            Toggle(t("enabled"), isOn: $term.enabled)
            if let error { Text(error).foregroundStyle(.red).font(.callout) }
            HStack { Spacer(); Button(t("cancel")) { dismiss() }; Button(t("save")) { do { try controller.saveTerm(term); dismiss() } catch let problem as TranslationTermConflict { error = t("conflict") + "\n" + problem.existing.translation + " → " + problem.incoming.translation } catch { self.error = CloudViewText.failure(cloudFailure(error), language) } }.keyboardShortcut(.defaultAction) }
        }.textFieldStyle(.roundedBorder).padding(24).frame(width: 560)
    }
}
