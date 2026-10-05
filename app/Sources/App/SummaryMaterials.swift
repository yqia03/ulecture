import SwiftUI

struct SummaryMaterialsView: View {
    @EnvironmentObject var model: AppModel
    let classID: String
    let assetIDs: Set<String>
    let useTranscript: Bool
    let useNotes: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(model.t("willSendMaterials")).font(.subheadline.weight(.medium))
            ForEach(model.classroomPDFs(classID)) { pdf in
                if let asset = pdf.assetID {
                    if assetIDs.contains(asset) { pdfRange(pdf, asset: asset) }
                    else { Text(pdf.title + " · " + model.t("notSelected")).font(.caption).foregroundStyle(.secondary) }
                }
            }
            transcriptRange
            noteRange
            if !hasPDFText && !hasPDFReadError { Text(model.t("noPDFForSummary")).font(.caption).foregroundStyle(.secondary) }
            Text(model.t("pdfHelp")).font(.caption2).foregroundStyle(.secondary)
        }.padding(.vertical, 8)
    }
    private func pdfRange(_ pdf: WorkspaceItem, asset: String) -> some View {
        let loaded = loadPages(asset)
        let pages = loaded.pages
        let readable = pages.filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let missing = pages.filter { $0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return VStack(alignment: .leading, spacing: 3) {
            Text(pdf.title).font(.caption.weight(.medium))
            if let error = loaded.error { Text(model.detail(error)).font(.caption).foregroundStyle(.secondary) }
            else { Text(model.t("readablePages") + " " + SummaryPresentation.compactPages(readable.map(\.pageNumber)) + " · \(readable.count)/\(pages.count)").font(.caption) }
            if !missing.isEmpty { Text(model.t("excludedSources") + " · " + model.t("page") + " " + SummaryPresentation.compactPages(missing.map(\.pageNumber))).font(.caption).foregroundStyle(.secondary) }
        }
    }
    private var hasPDFText: Bool {
        assetIDs.contains { asset in loadPages(asset).pages.contains { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty } }
    }
    private var hasPDFReadError: Bool { assetIDs.contains { loadPages($0).error != nil } }
    private func loadPages(_ asset: String) -> (pages: [PDFTextPage], error: String?) {
        do {
            guard let library = model.library else { return ([], model.t("libraryUnavailable")) }
            return (try library.pdfPages(assetID: asset), nil)
        } catch { return ([], error.localizedDescription) }
    }
    private var transcriptRange: some View {
        let rows = model.transcriptRows[classID] ?? []
        return VStack(alignment: .leading, spacing: 3) {
            Text(model.t("confirmedTranscript") + " · " + model.t(useTranscript ? "includedSources" : "notSelected")).font(.caption.weight(.medium))
            if useTranscript {
                if let start = rows.map(\.startMS).min(), let end = rows.map(\.endMS).max() {
                    Text(timeLabel(start) + " – " + timeLabel(end) + " · \(rows.count) " + model.t("segments")).font(.caption)
                    if !(model.gapsByClass[classID] ?? []).isEmpty { Text(model.t("summaryGapNotice")).font(.caption2).foregroundStyle(.secondary) }
                } else { Text(model.t("noTranscript")).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private var noteRange: some View {
        let notes = model.visibleItems.filter { $0.kind == .note && $0.classroomID == classID }
        return VStack(alignment: .leading, spacing: 3) {
            Text(model.t("allClassNotes") + " · " + model.t(useNotes ? "includedSources" : "notSelected")).font(.caption.weight(.medium))
            if useNotes {
                ForEach(notes) { note in noteRow(note) }
                if notes.isEmpty { Text(model.t("emptySavedNotes")).font(.caption).foregroundStyle(.secondary) }
            }
        }
    }
    private func noteRow(_ note: WorkspaceItem) -> some View {
        let loaded: Result<NoteRevision?, Error> = Result { try model.library?.noteRevision(noteID: note.id) }
        let revision = try? loaded.get()
        let draft = model.drafts[note.id]
        return VStack(alignment: .leading, spacing: 3) {
            Text(note.title).font(.caption.weight(.medium))
            if case .failure(let error) = loaded { Text(model.t("noteLoadFailed") + " · " + model.detail(error.localizedDescription)).font(.caption).foregroundStyle(.secondary) }
            else if let revision, !revision.markdown.isEmpty { Text("v\(revision.version) · \(revision.markdown.count) " + model.t("characters") + " · " + revision.savedAt.formatted()).font(.caption) }
            else { Text(model.t("emptySavedNotes")).font(.caption).foregroundStyle(.secondary) }
            if let draft, draft != (revision?.markdown ?? "") { Text(model.t("summarySavesDraft")).font(.caption2).foregroundStyle(.secondary) }
        }
    }
}
