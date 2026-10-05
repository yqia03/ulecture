import SwiftUI
import AppKit

struct BackupSettingsView: View {
    @EnvironmentObject var model: AppModel
    @State private var selection = ""
    var candidates: [WorkspaceItem] { model.items.filter { $0.deletedAt == nil }.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending } }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(model.t("backupHelp")).font(.callout).foregroundStyle(.secondary)
            Picker(model.t("backupScope"), selection: $selection) {
                Text("—").tag("")
                ForEach(candidates) { item in Text(item.title + " · " + model.t(item.kind.rawValue)).tag(item.id) }
            }.frame(maxWidth: 520)
            HStack {
                Button(model.t("backup")) { if let item = candidates.first(where: { $0.id == selection }) { model.export(item, backup: true) } }.disabled(selection.isEmpty)
                Button(model.t("restoreBackup")) { model.restoreBackup() }
            }
        }.disabled(model.busy).frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { if selection.isEmpty { selection = model.selectedID ?? candidates.first?.id ?? "" } }
    }
}
