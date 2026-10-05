import SwiftUI
import AppKit

@MainActor extension AppModel {
    func export(_ item: WorkspaceItem, selection: ReadableExportSelection) {
        guard let library, flushDrafts(), !busy else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = item.title + "-export"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await Task.detached { try library.exportReadable(itemID: item.id, to: url, selection: selection) }.value
                exportedURL = url
                notice = t("exportDone") + "\n" + url.path
            } catch { report(error) }
        }
    }
}

struct WorkspaceExportMenu: View {
    @EnvironmentObject var model: AppModel
    let item: WorkspaceItem
    var body: some View {
        Button(model.t("transcriptsAndTranslations")) { model.transcriptExportItem = item }.disabled(model.busy || (try? model.library?.transcriptSessions(for: item.id).isEmpty) != false)
    }
}

struct TranscriptExportSheet: View {
    @EnvironmentObject var model: AppModel
    let item: WorkspaceItem
    @State private var bilingual = true
    @State private var format = TranscriptExportFormat.txt
    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(model.t("transcriptsAndTranslations")).font(.title2)
            Picker(model.t("content"), selection: $bilingual) {
                Text(model.t("transcriptOnly")).tag(false)
                Text(model.t("transcriptBilingual")).tag(true)
            }.pickerStyle(.radioGroup)
            Picker(model.t("format"), selection: $format) { ForEach(TranscriptExportFormat.allCases, id: \.rawValue) { Text($0.rawValue.uppercased()).tag($0) } }
            HStack { Spacer(); Button(model.t("cancel")) { model.transcriptExportItem = nil }; Button(model.t("export")) { model.exportTranscripts(item, format: format, bilingual: bilingual) }.keyboardShortcut(.defaultAction) }
        }.padding(24).frame(width: 410)
    }
}

@MainActor extension AppModel {
    func exportTranscripts(_ item: WorkspaceItem, format: TranscriptExportFormat, bilingual: Bool) {
        guard let library, !busy else { return }
        do {
            let files = try library.transcriptExportFiles(itemID: item.id, format: format, bilingual: bilingual)
            let panel = NSSavePanel(); panel.canCreateDirectories = true
            panel.nameFieldStringValue = files.count == 1 ? files.keys.first! : item.title + "-transcripts"
            guard panel.runModal() == .OK, let destination = panel.url else { return }
            transcriptExportItem = nil; busy = true
            Task {
                defer { busy = false }
                do {
                    try await Task.detached {
                        let fm = FileManager.default
                        guard !fm.fileExists(atPath: destination.path) else { throw LibraryError.message("目标已存在，请选择新名称。") }
                        let temporary = destination.deletingLastPathComponent().appendingPathComponent(".ulecture-export-" + UUID().uuidString)
                        if files.count == 1 { try files.values.first!.write(to: temporary, options: .withoutOverwriting) }
                        else {
                            try fm.createDirectory(at: temporary, withIntermediateDirectories: false)
                            for (name, bytes) in files { try bytes.write(to: temporary.appendingPathComponent(name), options: .withoutOverwriting) }
                        }
                        try fm.moveItem(at: temporary, to: destination)
                    }.value
                    exportedURL = destination; notice = t("exportDone")
                } catch { report(error) }
            }
        } catch { report(error) }
    }
}
