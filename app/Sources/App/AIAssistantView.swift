import SwiftUI
import AppKit

struct AIAssistantView: View {
    @ObservedObject var controller: AIAssistantController
    let language: String
    @Environment(\.colorScheme) private var scheme
    @State private var savingTurn: String?
    @State private var saveParent = ""
    @State private var saveTitle = ""
    private func t(_ key: String) -> String { AssistantText.text(key, language: language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack { Label(t("assistant"), systemImage: "sparkles").font(.headline); Spacer(); if controller.busy { ProgressView().controlSize(.small); Button(t("cancel")) { controller.cancel() } } }
            DisclosureGroup(t("sources") + " (\(controller.selectedSourceIDs.count))") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(controller.options) { option in
                            sourceOptionView(option)
                        }
                        Text(t("sourceScopeHelp")).font(.caption).foregroundStyle(.secondary)
                        if controller.options.contains(where: { $0.kind == .pdf && controller.selectedSourceIDs.contains($0.id) }) {
                            Picker(t("ocrLanguage"), selection: Binding(get: { controller.ocrLanguage }, set: { controller.setOCRLanguage($0) })) {
                                Text("English").tag("en"); Text("日本語").tag("ja")
                            }
                            Text(t("ocrHelp")).font(.caption2).foregroundStyle(.secondary)
                        }
                        Button(t("refreshSourceVersions")) { Task { await controller.refreshSourceDetails() } }.disabled(controller.loadingSourceDetails)
                    }.frame(maxWidth: .infinity, alignment: .leading).padding(.vertical, 8)
                }.frame(maxHeight: 210).disabled(controller.busy || controller.readOnly)
            }
            if let error = controller.error {
                Text(t(error)).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                if controller.unsaved { Button(t("retrySave")) { controller.retrySaving() } }
            }
            if controller.conversation == nil { Text(t("chooseContext")).foregroundStyle(.secondary) }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if !controller.legacySummaries.isEmpty {
                        DisclosureGroup(t("legacySummaries") + " (\(controller.legacySummaries.count))") {
                            Text(t("legacySummariesHelp")).font(.caption).foregroundStyle(.secondary).padding(.vertical, 8)
                            ForEach(controller.legacySummaries) { summary in legacySummaryView(summary) }
                        }
                    }
                    ForEach(controller.turns) { turn in turnView(turn) }
                }.frame(maxWidth: .infinity, alignment: .leading)
            }.frame(maxHeight: .infinity)
            composer
        }
        .padding(16).background(AppPalette(dark: scheme == .dark).canvas).buttonStyle(QuietButtonStyle())
        .sheet(item: $controller.legacySource) { source in
            VStack(alignment: .leading, spacing: 14) {
                Text(t("legacyFixedSource")).font(.headline)
                Text(t("legacySourceHelp")).font(.callout).foregroundStyle(.secondary)
                Text(legacySourceLabel(source)).font(.caption).textSelection(.enabled)
                Text(t("version") + " \(source.version) · SHA-256 " + source.hash).font(.caption2.monospaced()).textSelection(.enabled)
                Text(source.entityID).font(.caption2.monospaced()).foregroundStyle(.secondary).textSelection(.enabled)
                ScrollView { Text(source.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button(t("close")) { controller.legacySource = nil }
                    Spacer()
                    Button(t("copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(source.text, forType: .string) }
                }
            }.padding(24).frame(minWidth: 450, idealWidth: 620, minHeight: 320, idealHeight: 500)
        }
        .sheet(item: $controller.fixedSource) { source in
            VStack(alignment: .leading, spacing: 14) {
                Text(sourceLabel(source)).font(.headline)
                Text(t("fixedSourceHelp")).font(.callout).foregroundStyle(.secondary)
                Text(t("version") + " \(source.version) · " + source.sourceHash).font(.caption2.monospaced()).textSelection(.enabled)
                if let ocr = source.ocr { ocrProvenanceView(ocr) }
                ScrollView { Text(source.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
                HStack {
                    Button(t("close")) { controller.fixedSource = nil }
                    Spacer()
                    Button(t("openCurrentSource")) { controller.openCurrentReference(source) }
                }
            }.padding(24).frame(minWidth: 450, idealWidth: 620, minHeight: 320, idealHeight: 500)
        }
        .sheet(isPresented: Binding(get: { savingTurn != nil }, set: { if !$0 { savingTurn = nil } })) {
            VStack(alignment: .leading, spacing: 14) {
                Text(t("saveAsNote")).font(.headline)
                TextField(t("title"), text: $saveTitle)
                Picker(t("location"), selection: $saveParent) { Text("—").tag(""); ForEach(controller.saveParents) { Text($0.title).tag($0.id) } }
                HStack {
                    Button(t("cancel")) { savingTurn = nil }
                    Spacer()
                    Button(t("save")) {
                        if let id = savingTurn { Task { await controller.saveAsNote(turnID: id, parentID: saveParent, title: saveTitle); savingTurn = nil } }
                    }.disabled(saveParent.isEmpty || saveTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }.padding(24).frame(width: 380)
        }
    }
    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            ViewThatFits(in: .horizontal) {
                HStack { quickActions }
                VStack(alignment: .leading, spacing: 6) { quickActions }
            }
            if let selection = controller.selection, !selection.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                Text(t("selectedExcerpt") + ": " + String(selection.text.prefix(160))).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                Button(t("explain")) { Task { await controller.ask(t("explainPrompt"), intent: .explain, language: language, selection: selection) } }
            }
            TextEditor(text: $controller.draft).font(.body).frame(minHeight: 70, maxHeight: 120)
                .padding(6).overlay(RoundedRectangle(cornerRadius: 8).stroke(Color.secondary.opacity(0.25)))
                .accessibilityLabel(t("question"))
            HStack {
                Text(t("historyHelp")).font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button(t("send")) { Task { await controller.ask(controller.draft, language: language) } }.keyboardShortcut(.return, modifiers: .command)
                    .disabled(controller.draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }.disabled(controller.busy || controller.readOnly || controller.unsaved || controller.conversation == nil || controller.sourceScopeError != nil)
    }
    private func sourceOptionView(_ option: AssistantSourceOption) -> some View {
        let scope = controller.scope(for: option)
        let details = controller.sourceDetails[option.id]
        return VStack(alignment: .leading, spacing: 6) {
            Toggle(option.title + " · " + t(option.kind.rawValue), isOn: Binding(get: { controller.selectedSourceIDs.contains(option.id) }, set: { controller.selectSource(option.id, included: $0) }))
            if controller.selectedSourceIDs.contains(option.id) {
                if option.kind == .transcript {
                    if let start = details?.firstMS, let end = details?.lastMS { Text(t("availableTranscript") + " " + timestamp(start) + "–" + timestamp(end)).font(.caption2).foregroundStyle(.secondary) }
                    else { Text(t(controller.loadingSourceDetails ? "loadingSources" : "noConfirmedTranscript")).font(.caption2).foregroundStyle(.secondary) }
                    HStack {
                        TextField(t("rangeStart"), text: Binding(get: { controller.scope(for: option).startTime }, set: { controller.setTranscriptRange(option, start: $0, end: controller.scope(for: option).endTime) }))
                        Text("–")
                        TextField(t("rangeEnd"), text: Binding(get: { controller.scope(for: option).endTime }, set: { controller.setTranscriptRange(option, start: controller.scope(for: option).startTime, end: $0) }))
                    }.textFieldStyle(.roundedBorder)
                    Text(t("transcriptRangeHelp")).font(.caption2).foregroundStyle(.secondary)
                    if (try? scope.transcriptRange()) == nil { Text(t("invalidTranscriptRange")).font(.caption).foregroundStyle(.orange) }
                } else if option.kind == .note {
                    Picker(t("savedNoteVersion"), selection: Binding(get: { controller.scope(for: option).version ?? 0 }, set: { controller.selectNoteVersion(option, version: $0 == 0 ? nil : $0) })) {
                        Text(t("currentSavedVersion")).tag(0)
                        ForEach(details?.versions ?? []) { version in
                            Text(t("version") + " \(version.version) · " + version.savedAt.formatted(date: .numeric, time: .shortened) + " · " + version.sourceHash.prefix(8)).tag(version.version)
                        }
                        if let version = scope.version, details?.versions.contains(where: { $0.version == version }) != true {
                            Text(t("version") + " \(version) · " + t("sourceVersionUnavailable")).tag(version)
                        }
                    }
                    if let hash = scope.sourceHash { Text(hash).font(.caption2.monospaced()).lineLimit(1).truncationMode(.middle).textSelection(.enabled) }
                    if let version = scope.version, let details, details.versions.contains(where: { $0.version == version && $0.sourceHash == scope.sourceHash }) == false { Text(t("sourceVersionUnavailable")).font(.caption).foregroundStyle(.orange) }
                    if details?.versions.isEmpty != false { Text(t(controller.loadingSourceDetails ? "loadingSources" : "noSavedVersions")).font(.caption2).foregroundStyle(.secondary) }
                }
                if let error = details?.error { Text(t(error)).font(.caption2).foregroundStyle(.orange) }
            }
        }.padding(.vertical, 3)
    }
    @ViewBuilder private var quickActions: some View {
        Button(t("notes")) { Task { await controller.ask(t("notesPrompt"), intent: .notes, language: language) } }
        Button(t("summary")) { Task { await controller.ask(t("summaryPrompt"), intent: .summary, language: language) } }
        Button(t("latestQuestion")) { Task { await controller.ask(t("latestQuestionPrompt"), intent: .latestQuestion, language: language) } }
    }
    private func legacySummaryView(_ summary: CloudSummary) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(summary.createdAt, style: .date).font(.caption)
                Spacer()
                Text(t(summary.status == "running" ? "interrupted" : summary.status)).font(.caption).foregroundStyle(.secondary)
            }
            ForEach(summary.claims) { claim in
                Text(claim.text).textSelection(.enabled)
                ForEach(Array(claim.referenceIDs.enumerated()), id: \.offset) { _, referenceID in
                    if let source = summary.source(for: referenceID) {
                        Button(legacySourceLabel(source)) { controller.openLegacyReference(summaryID: summary.id, sourceID: source.id) }.font(.caption)
                    } else {
                        Text(t("invalidCitations") + " " + referenceID).font(.caption).foregroundStyle(.orange).textSelection(.enabled)
                    }
                }
            }
            if let error = summary.errorCode { Text(t(error)).font(.caption).foregroundStyle(.orange) }
            if summary.invalidReferenceCount > 0 { Text(t("invalidCitations") + " (\(summary.invalidReferenceCount))").font(.caption).foregroundStyle(.orange) }
            DisclosureGroup(t("snapshot") + " · \(summary.snapshot.sources.count) " + t("sourceUnits")) {
                Text("SHA-256 " + summary.snapshot.hash).font(.caption2.monospaced()).textSelection(.enabled)
                Text(summary.snapshot.createdAt, style: .date).font(.caption)
                ForEach(summary.snapshot.sources) { source in
                    Button(legacySourceLabel(source)) { controller.openLegacyReference(summaryID: summary.id, sourceID: source.id) }.font(.caption)
                }
                if !summary.chunks.isEmpty {
                    Text("\(summary.completedChunkIDs.count)/\(summary.chunks.count) " + t("processedChunks")).font(.caption)
                    ForEach(summary.chunks) { chunk in
                        Text(chunk.id + " · " + t(chunk.status)).font(.caption2)
                        ForEach(Array(chunk.spans.enumerated()), id: \.offset) { _, span in
                            Text(span.sourceID + " · " + t("sourceCharacters") + " \(span.startCharacter)…\(span.startCharacter + span.characterCount)").font(.caption2).textSelection(.enabled)
                        }
                    }
                }
                if !summary.missingChunkIDs.isEmpty { Text(t("missingChunks") + ": " + summary.missingChunkIDs.joined(separator: ", ")).font(.caption).foregroundStyle(.orange) }
                if !summary.snapshot.excluded.isEmpty {
                    Text(t("excludedScope")).font(.caption.weight(.semibold))
                    ForEach(Array(summary.snapshot.excluded.enumerated()), id: \.offset) { _, excluded in Text(t(excluded)).font(.caption).foregroundStyle(.secondary) }
                }
            }
            Button(t("copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(summary.markdown, forType: .string) }.font(.caption)
            Divider()
        }.padding(.vertical, 8)
    }
    private func legacySourceLabel(_ source: SummarySource) -> String {
        var label = "[" + source.id + "] · " + t(source.kind == .note ? "legacyMarkdown" : source.kind.rawValue)
        if let page = source.page { label += " · " + t("page") + " \(page)" }
        if let start = source.startMS { label += " · " + timestamp(start); if let end = source.endMS { label += "–" + timestamp(end) } }
        return label
    }
    private func turnView(_ turn: AssistantTurn) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(turn.question).font(.body.weight(.semibold)).textSelection(.enabled)
            if let snapshot = controller.snapshots[turn.snapshotID] {
                snapshotView(snapshot, turn: turn)
                ForEach(Array(turn.runs.enumerated()), id: \.element.id) { index, run in
                    if index == turn.runs.count - 1 { runView(run, snapshot: snapshot) }
                    else { DisclosureGroup(t("previousAttempt") + " \(index + 1)") { runView(run, snapshot: snapshot) } }
                }
            } else { Text(t("sourceUnavailable")).foregroundStyle(.orange) }
            HStack {
                Button { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(controller.resultText(turn.id), forType: .string) } label: { Image(systemName: "doc.on.doc") }.help(t("copy")).disabled(controller.resultText(turn.id).isEmpty)
                Menu(t("save")) {
                    Button(t("saveAsNote")) { savingTurn = turn.id; saveParent = controller.saveParents.first?.id ?? ""; saveTitle = String(turn.question.prefix(60)).replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-") }
                    Menu(t("appendToNote")) {
                        ForEach(controller.notes) { note in Button(note.title) { Task { do { try await controller.append(turnID: turn.id, noteID: note.id) } catch { controller.error = error.localizedDescription } } } }
                    }
                }.disabled(controller.resultText(turn.id).isEmpty || controller.busy || controller.readOnly || controller.unsaved)
                Spacer()
                Button(t("retry")) { Task { await controller.retry(turn.id) } }.disabled(controller.busy || controller.readOnly || controller.unsaved)
            }
            Divider()
        }
    }
    private func snapshotView(_ snapshot: AssistantSnapshot, turn: AssistantTurn) -> some View {
        DisclosureGroup(t("snapshot") + " · \(snapshot.sources.count) " + t("sourceUnits")) {
            VStack(alignment: .leading, spacing: 8) {
                Text(snapshot.capturedAt, style: .date).font(.caption)
                if let cutoff = snapshot.cutoffMS { Text(t(snapshot.classroomEnded ? "coverageEnded" : "coverageLive") + " " + timestamp(cutoff)).font(.caption) }
                Text("SHA-256 " + snapshot.hash).font(.caption2.monospaced()).textSelection(.enabled)
                ForEach(snapshot.requestedScopes ?? []) { scope in
                    requestedScopeView(scope, snapshot: snapshot)
                }
                ForEach(snapshot.sources) { source in sourceView(source) }
                if let coverage = snapshot.pdfCoverage, !coverage.isEmpty {
                    DisclosureGroup(t("pdfCoverage")) { ForEach(coverage) { page in pdfCoverageView(page) } }
                }
                if !snapshot.exclusions.isEmpty {
                    Text(t("excludedScope")).font(.caption.weight(.semibold))
                    ForEach(Array(snapshot.exclusions.enumerated()), id: \.offset) { _, value in Text(t(value)).font(.caption).foregroundStyle(.secondary) }
                }
            }.padding(.vertical, 8)
        }.font(.caption)
    }
    private func requestedScopeView(_ scope: AssistantSourceScope, snapshot: AssistantSnapshot) -> some View {
        let title = snapshot.sources.first(where: { $0.documentID == scope.documentID })?.title ?? scope.documentID
        let start = scope.startTime.isEmpty ? t("unbounded") : scope.startTime
        let end = scope.endTime.isEmpty ? t("unbounded") : scope.endTime
        let rangeLabel = title + " · " + t("requestedRange") + " " + start + "–" + end
        return VStack(alignment: .leading, spacing: 4) {
            if scope.kind == .transcript {
                Text(rangeLabel).font(.caption)
                Text(t("wholeSegmentRange")).font(.caption2).foregroundStyle(.secondary)
            } else if let version = scope.version { Text(title + " · " + t("savedNoteVersion") + " \(version)").font(.caption) }
        }
    }
    private func sourceView(_ source: AssistantSource) -> some View {
        DisclosureGroup {
            Text(source.text).font(.callout).textSelection(.enabled)
            Text(t("version") + " \(source.version) · " + source.sourceHash).font(.caption2.monospaced()).textSelection(.enabled)
            if let ocr = source.ocr { ocrProvenanceView(ocr) }
            Button(t("openSource")) { controller.open(source) }
        } label: {
            Text(sourceLabel(source))
        }
    }
    private func ocrProvenanceView(_ value: AssistantOCRProvenance) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(t("localOCR") + " · " + value.engine + " · " + value.language).font(.caption)
            Text(t("ocrConfidence") + String(format: " %.0f%%", value.confidence * 100)).font(.caption)
            Text(String(format: "bbox %.1f, %.1f, %.1f, %.1f · page %.1f × %.1f pt", value.bounds.minX, value.bounds.minY, value.bounds.width, value.bounds.height, value.pageWidth, value.pageHeight)).font(.caption2.monospaced()).textSelection(.enabled)
            Text(t("ocrHelp")).font(.caption2).foregroundStyle(.secondary)
        }
    }
    private func pdfCoverageView(_ page: AssistantPDFPageCoverage) -> some View {
        let title = page.title + " · " + t("page") + " \(page.page) · " + t(page.missing ? "noExtractableText" : "textExtracted")
        let counts = t("nativeCharacters") + " \(page.nativeCharacters) · OCR \(page.ocrCharacters) · " + t("excludedOCRRegions") + " \(page.rejectedRegions)"
        let confidence = page.minimumConfidence.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
        let engine = page.engine + " · " + page.language + " · " + t("ocrConfidence") + " " + confidence
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption)
            Text(counts).font(.caption2)
            Text(engine).font(.caption2)
            Text("SHA-256 " + page.sourceHash).font(.caption2.monospaced()).textSelection(.enabled)
            ForEach(Array(page.warnings.enumerated()), id: \.offset) { _, warning in Text(t(warning)).font(.caption2).foregroundStyle(.secondary) }
            if let failure = page.failureCode { Text(ConversionText.t(failure, language)).font(.caption2).foregroundStyle(.orange) }
        }.padding(.vertical, 4)
    }
    private func runView(_ run: AssistantRun, snapshot: AssistantSnapshot) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            runHeader(run)
            if !run.text.isEmpty { Text(run.text).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading) }
            if let error = run.errorCode { Text(t(error)).font(.caption).foregroundStyle(.orange) }
            if !run.invalidCitations.isEmpty { Text(t("invalidCitations") + ": " + run.invalidCitations.joined(separator: ", ")).font(.caption).foregroundStyle(.orange) }
            if !run.chunks.isEmpty {
                Text("\(run.chunks.filter { $0.status == "completed" }.count)/\(run.chunks.count) " + t("processedChunks")).font(.caption2).foregroundStyle(.secondary)
                if run.chunks.count > 1 || run.state != "completed" {
                    DisclosureGroup(t("partialAnalyses")) {
                        ForEach(run.chunks) { chunk in
                            VStack(alignment: .leading) { Text(chunk.id + " · " + t(chunk.status)).font(.caption); if !chunk.text.isEmpty { Text(chunk.text).textSelection(.enabled) } }.padding(.vertical, 5)
                        }
                    }
                }
            }
            citationButtons(run, snapshot: snapshot)
        }
    }
    private func sourceLabel(_ source: AssistantSource) -> String {
        var label = "[\(source.id)] " + source.title
        if let page = source.page { label += " · " + t("page") + " \(page)" }
        if let start = source.startMS { label += " · " + timestamp(start); if let end = source.endMS { label += "–" + timestamp(end) } }
        if source.ocr != nil { label += " · OCR" }
        return label
    }
    private func runHeader(_ run: AssistantRun) -> some View {
        HStack {
            Text(t(run.state)).font(.caption).foregroundStyle(.secondary)
            Spacer()
            if let request = run.dispatches.last {
                Text(request.configuration.provider.rawValue + " · " + request.preset.model).font(.caption2).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
        }
    }
    private func citationButtons(_ run: AssistantRun, snapshot: AssistantSnapshot) -> some View {
        let cited = Set(AssistantCitation.identifiers(in: run.text))
        return ForEach(snapshot.sources.filter { cited.contains($0.id) }) { source in
            Button(sourceLabel(source)) { controller.open(source) }.font(.caption).lineLimit(2)
        }
    }
    private func timestamp(_ ms: Int64) -> String { let s = max(0, ms) / 1000; return String(format: "%02lld:%02lld:%02lld", s / 3600, s / 60 % 60, s % 60) }
}

enum AssistantText {
    static let rows: [String: [String]] = [
        "ocrLanguage": ["本地 OCR 识别语言", "本機 OCR 辨識語言", "Local OCR language", "端末内 OCR の言語"],
        "ocrHelp": ["所选课件在本机识别扫描文字，只发送提取文本，不上传页图像。请核对 OCR；图像、公式和图表含义未分析。", "所選教材在本機辨識掃描文字，只傳送擷取文字，不上傳頁面影像。請核對 OCR；影像、公式及圖表含義未分析。", "Scan text is recognized locally for selected documents. Only extracted text is sent; page images are not uploaded. Review OCR; image, formula and diagram meaning is not analyzed.", "選択した教材の画像内文字を端末内で認識します。抽出文字だけを送信し、ページ画像は送信しません。OCR を確認してください。画像・数式・図表の意味は未分析です。"],
        "localOCR": ["本地 OCR 提取文字，需核对识别", "本機 OCR 擷取文字，需核對辨識", "Local OCR text; verify recognition", "端末内 OCR の文字・認識結果を確認"],
        "ocrConfidence": ["OCR 置信度", "OCR 可信度", "OCR confidence", "OCR 信頼度"],
        "pdfCoverage": ["课件逐页文字覆盖", "教材逐頁文字涵蓋", "Document text coverage by page", "教材のページ別文字対象範囲"],
        "textExtracted": ["已提取可用文字", "已擷取可用文字", "Usable text extracted", "使用可能な文字を抽出済み"],
        "nativeCharacters": ["原生文本字符", "原生文字字元", "Native text characters", "元のテキスト文字数"],
        "excludedOCRRegions": ["未纳入的 OCR 区域", "未納入的 OCR 區域", "Excluded OCR regions", "除外した OCR 領域"],
        "ocrLowConfidenceExcluded": ["低置信 OCR 区域未纳入 AI 来源", "低可信 OCR 區域未納入 AI 來源", "Low-confidence OCR regions excluded from AI sources", "信頼度の低い OCR 領域は AI 資料から除外"],
        "ocrLowConfidence": ["低置信 OCR 区域未纳入 AI 来源", "低可信 OCR 區域未納入 AI 來源", "Low-confidence OCR regions excluded from AI sources", "信頼度の低い OCR 領域は AI 資料から除外"],
        "ocrImageContextNotAnalyzed": ["仅提取图像内可靠文字；背景及图像含义未分析", "僅擷取影像內可靠文字；背景及影像含義未分析", "Only reliable image text extracted; background and image meaning not analyzed", "画像内の信頼できる文字だけを抽出し、背景や画像の意味は未分析"],
        "ocrLanguageUnavailable": ["本机 OCR 不支持所选语言", "本機 OCR 不支援所選語言", "Local OCR does not support the selected language", "端末内 OCR は選択した言語に未対応"],
        "localOCRFailed": ["本地 OCR 未完成；只保留实际可用的原生文字", "本機 OCR 未完成；僅保留實際可用的原生文字", "Local OCR did not complete; only available native text is retained", "端末内 OCR が未完了のため、利用できる元の文字だけを保持"],
        "formulasPreserved": ["公式保留在原页，不声称已分析其含义", "公式保留於原頁，不聲稱已分析其含義", "Formulas remain on the source page; their meaning is not claimed to be analyzed", "数式は元のページに保持し、意味を分析したとはみなしません"],
        "refreshSourceVersions": ["刷新可用时间与版本", "重新整理可用時間與版本", "Refresh times and versions", "時刻と版を更新"],
        "loadingSources": ["读取已保存来源…", "讀取已儲存來源…", "Reading saved sources…", "保存済み資料を読込中…"],
        "availableTranscript": ["已保存转写时段", "已儲存轉寫時段", "Saved transcript times", "保存済み文字起こしの時刻"],
        "rangeStart": ["起点（可留空）", "起點（可留空）", "Start (optional)", "開始（任意）"],
        "rangeEnd": ["终点（可留空）", "終點（可留空）", "End (optional)", "終了（任意）"],
        "transcriptRangeHelp": ["输入秒数或 HH:MM:SS；空白表示不限。选取与范围重叠的完整确认片段，保留原始时间。", "輸入秒數或 HH:MM:SS；空白表示不限。選取與範圍重疊的完整確認片段，保留原始時間。", "Enter seconds or HH:MM:SS; leave blank for no bound. Includes complete confirmed segments overlapping the range, with original times.", "秒数または HH:MM:SS で入力し、無制限なら空欄にします。範囲に重なる確定済み区間を元の時刻のまま使用します。"],
        "invalidTranscriptRange": ["时间格式无效，或终点不晚于起点；未发送请求。", "時間格式無效，或終點不晚於起點；未傳送要求。", "Invalid time, or end is not after start. No request was sent.", "時刻が無効、または終了が開始より後ではありません。送信していません。"],
        "savedNoteVersion": ["笔记保存版本", "筆記儲存版本", "Saved note version", "保存済みノートの版"],
        "currentSavedVersion": ["当前已保存版本（默认）", "目前已儲存版本（預設）", "Current saved version (default)", "現在の保存済み版（既定）"],
        "noSavedVersions": ["暂无可读取的保存版本", "暫無可讀取的儲存版本", "No readable saved versions", "読込可能な保存済み版がありません"],
        "sourceVersionUnavailable": ["所选保存版本缺失或已改变，请刷新后重新选择；未发送请求。", "所選儲存版本遺失或已變更，請重新整理後選取；未傳送要求。", "The selected saved version is missing or changed. Refresh and choose again; no request was sent.", "選択した保存済み版が見つからないか変更されています。更新して再選択してください。送信していません。"],
        "requestedRange": ["所选时间范围", "所選時間範圍", "Requested time range", "選択した時刻範囲"],
        "wholeSegmentRange": ["下列引用显示实际纳入的完整片段及原始起止时间。", "下列引用顯示實際納入的完整片段及原始起止時間。", "Citations below show the complete included segments and their original times.", "以下の引用に、実際に含めた区間全体と元の開始・終了時刻を示します。"],
        "unbounded": ["不限", "不限", "Unbounded", "無制限"],
        "legacySummaries": ["历史总结", "歷史摘要", "Historical summaries", "過去の要約"],
        "legacySummariesHelp": ["迁移前保存的总结与引用，仅供查阅；不会重新发送请求。", "移轉前儲存的摘要與引用，僅供查閱；不會重新傳送要求。", "Summaries and citations saved before migration, kept for reference. No requests are replayed.", "移行前に保存した要約と引用を閲覧できます。要求は再送信しません。"],
        "legacyFixedSource": ["历史引用原文", "歷史引用原文", "Original historical citation", "過去の引用原文"],
        "legacySourceHelp": ["这是当时保存的完整来源片段。旧 Markdown 引用保留原版本，不映射到转换后的笔记块；当前原件移除后仍可查阅。", "這是當時儲存的完整來源片段。舊 Markdown 引用保留原版本，不映射至轉換後的筆記區塊；目前原件移除後仍可查閱。", "This is the complete source excerpt saved at the time. Legacy Markdown citations keep their original version and do not map to converted blocks. This excerpt remains readable if the current file is removed.", "当時保存した資料の抜粋全体です。旧 Markdown の引用は元の版を保持し、変換後のブロックには対応付けません。現在のファイルが削除されても閲覧できます。"],
        "legacyMarkdown": ["原 Markdown 笔记", "原 Markdown 筆記", "Original Markdown note", "元の Markdown ノート"],
        "sourceCharacters": ["来源字符范围", "來源字元範圍", "Source character range", "資料の文字範囲"],
        "missingChunks": ["未完成分段", "未完成分段", "Incomplete chunks", "未完了の分割処理"],
        "retrySave": ["重试保存", "重試儲存", "Retry saving", "保存を再試行"],
        "waiting": ["尚未处理", "尚未處理", "Waiting", "未処理"],
        "noConfirmedTranscript": ["没有已确认的转写", "沒有已確認的轉寫", "No confirmed transcript", "確定済み文字起こしがありません"],
        "imageNotAnalyzed": ["未分析笔记图像", "未分析筆記影像", "Note image not analyzed", "ノート画像は未分析"],
        "noExtractableText": ["没有可提取的正文", "沒有可擷取的正文", "No extractable text", "抽出可能な本文がありません"],
        "nonTextAnnotation": ["未分析非文字标注", "未分析非文字標註", "Non-text annotation not analyzed", "非テキスト注釈は未分析"],
        "imagesFormulasDiagramsNotAnalyzed": ["图像、公式及图表未做视觉语义分析", "影像、公式及圖表未作視覺語意分析", "Images, formulas and diagrams have not been visually analyzed", "画像・数式・図表の視覚的意味は未分析"],
        "conversionRequired": ["此来源需要先完成本地课件转换", "此來源需要先完成本機教材轉換", "This source requires local document conversion", "この資料はローカルの教材変換が必要です"],
        "assistant": ["学习助手", "學習助理", "Study assistant", "学習アシスタント"],
        "sources": ["使用来源", "使用來源", "Sources to use", "使用する資料"],
        "sourceScopeHelp": ["只使用勾选的资料；未勾选的笔记和其他课程不会上传。", "只使用勾選的資料；未勾選的筆記和其他課程不會上傳。", "Only checked sources are used. Unselected notes and other courses are not uploaded.", "チェックした資料だけを使用します。未選択のノートや他のコースは送信しません。"],
        "chooseContext": ["先打开课件、笔记或课堂。", "先開啟教材、筆記或課堂。", "Open a document, note or classroom first.", "教材・ノート・授業を開いてください。"],
        "question": ["输入问题", "輸入問題", "Your question", "質問を入力"],
        "send": ["发送", "傳送", "Send", "送信"],
        "notes": ["生成笔记", "產生筆記", "Create notes", "ノートを作成"],
        "summary": ["结合资料总结", "結合資料摘要", "Summarize sources", "資料をまとめる"],
        "latestQuestion": ["老师刚问了什么", "老師剛問了甚麼", "Latest teacher question", "先生の直前の質問"],
        "explain": ["解释选区", "解釋選取內容", "Explain selection", "選択箇所を解説"],
        "notesPrompt": ["请根据选定的课件与截至当前的转写生成学习笔记，保留关键概念与来源，明确未覆盖的内容。", "請根據選定教材與截至目前的轉寫產生學習筆記，保留重要概念與來源，明確未涵蓋內容。", "Create study notes from the selected materials and transcript so far. Preserve key concepts and citations, and state excluded scope.", "選択した教材と現時点までの文字起こしから学習ノートを作成し、重要概念・出典・未対応範囲を明示してください。"],
        "summaryPrompt": ["请结合选定课件、转写、笔记和标注总结；若课堂尚未结束，只说明目前实际覆盖的部分。", "請結合選定教材、轉寫、筆記及標註摘要；課堂未結束時只說明目前實際涵蓋的部分。", "Summarize the selected documents, transcript, notes and annotations. For an ongoing class, state actual coverage so far.", "選択した教材・文字起こし・ノート・注釈をまとめてください。授業中の場合は現時点の対象範囲だけを示してください。"],
        "latestQuestionPrompt": ["根据最近的确认转写，老师刚刚问了什么？仅引用明确问题；如果没有足够证据，请直接说明。", "根據最近確認的轉寫，老師剛剛問了甚麼？只引用明確問題；證據不足時請直接說明。", "What did the teacher most recently ask in the confirmed transcript? Cite an explicit question; say when evidence is insufficient.", "直近の確定済み文字起こしで先生が何を質問したか、明示的な質問だけを引用してください。証拠が不十分ならそう述べてください。"],
        "explainPrompt": ["请解释最后一个来源片段中的选中文字，结合选定上下文，区分资料内容与补充常识。", "請解釋最後一個來源片段中選取的文字，結合所選上下文，區分資料內容與補充常識。", "Explain the selected text in the last source excerpt using the selected context. Distinguish source evidence from general knowledge.", "最後の資料抜粋の選択テキストを、選択した文脈を使って説明し、資料の根拠と一般知識を区別してください。"],
        "historyHelp": ["追问使用最近六轮已完成回答；每次固定来源版本。", "追問使用最近六輪已完成回答；每次固定來源版本。", "Follow-ups use the latest six completed replies; sources are fixed per request.", "直近6件の完了回答を会話の文脈として使用し、各要求で資料の版を固定します。"],
        "selectedExcerpt": ["已选内容", "已選內容", "Selected excerpt", "選択した抜粋"],
        "snapshot": ["来源快照", "來源快照", "Source snapshot", "資料のスナップショット"],
        "sourceUnits": ["来源片段", "來源片段", "source excerpts", "資料の抜粋"],
        "coverageLive": ["课堂尚在进行，转写覆盖至", "課堂仍在進行，轉寫涵蓋至", "Class in progress; transcript covered through", "授業中・文字起こしの対象時刻"],
        "coverageEnded": ["已结束课堂，所选转写覆盖至", "已結束課堂，所選轉寫涵蓋至", "Ended class; selected transcript covered through", "終了した授業・選択した文字起こしの対象時刻"],
        "excludedScope": ["未分析范围", "未分析範圍", "Excluded scope", "分析対象外"],
        "openSource": ["打开来源版本", "開啟來源版本", "Open source version", "資料の版を開く"],
        "sourceUnavailable": ["来源不可用或没有可用正文；保留快照供核查。", "來源不可用或沒有可用正文；保留快照供核查。", "Source unavailable or has no usable text; any saved snapshot remains available.", "資料が利用できないか有効な本文がありません。保存済みスナップショットは保持されます。"],
        "selectionChanged": ["选区对应的来源已改变，请重新选取。", "選取範圍對應的來源已變更，請重新選取。", "The selected source changed. Select the text again.", "選択した資料が変更されました。再選択してください。"],
        "selectFewerSources": ["所选正文超过一百万字符，请缩小本次范围；未发送请求。", "所選正文超過一百萬字元，請縮小本次範圍；未傳送請求。", "Selected text exceeds one million characters. Narrow this request; nothing was sent.", "選択した本文が100万文字を超えています。範囲を狭めてください。送信はしていません。"],
        "assistantUnsaved": ["仍有内容未保存，请先重试保存。", "仍有內容未儲存，請先重試儲存。", "Some content is unsaved. Retry saving first.", "未保存の内容があります。保存を再試行してください。"],
        "invalidCitations": ["回答包含无效来源编号，不能据此跳转或声称引用有效。", "回答含無效來源編號，不能據此跳轉或聲稱引用有效。", "The reply contains invalid source IDs; those citations cannot be opened or treated as valid.", "回答に無効な資料IDが含まれます。その引用を開いたり有効な根拠と見なしたりできません。"],
        "missingCitations": ["回答没有提供来源编号，请核查资料快照。", "回答未提供來源編號，請核查資料快照。", "The reply supplied no citation IDs. Check the source snapshot.", "回答に引用IDがありません。資料のスナップショットを確認してください。"],
        "providerChanged": ["服务已切换；已完成部分已保留，可用新服务重试。", "服務已切換；完成部分已保留，可用新服務重試。", "The provider changed. Completed portions are retained; retry with the new service.", "サービスが変更されました。完了部分は保持されています。新しいサービスで再試行できます。"],
        "assistantReductionTooLarge": ["中间结果仍过长，部分结果已保留；请缩小来源后重试。", "中間結果仍過長，部分結果已保留；請縮小來源後重試。", "Intermediate results remain too large. Partial results are saved; narrow the sources and retry.", "中間結果が長すぎます。部分結果は保存されています。資料を絞って再試行してください。"],
        "partialAnalyses": ["分段分析与部分结果", "分段分析與部分結果", "Chunk analyses and partial results", "分割分析と部分結果"],
        "processedChunks": ["段已完成", "段已完成", "chunks completed", "分割処理が完了"],
        "previousAttempt": ["前次结果", "前次結果", "Previous attempt", "前回の結果"],
        "saveAsNote": ["保存为新笔记", "儲存為新筆記", "Save as a new note", "新しいノートに保存"],
        "appendToNote": ["明确追加到笔记", "明確追加至筆記", "Append to a chosen note", "選択したノートに追記"],
        "chooseBlockNote": ["请选择应用块笔记追加；文本文件可复制结果后编辑。", "請選擇應用程式區塊筆記追加；文字檔案可複製結果後編輯。", "Choose an app block note to append. For text files, copy the reply and edit the file.", "追記先にはアプリのブロックノートを選択してください。テキストファイルには回答をコピーして編集できます。"],
        "pdf": ["课件正文", "教材正文", "Document text", "教材の本文"],
        "transcript": ["确认转写", "確認轉寫", "Confirmed transcript", "確定済み文字起こし"],
        "note": ["块笔记", "區塊筆記", "Block note", "ブロックノート"],
        "annotation": ["文本标注", "文字標註", "Text annotations", "テキスト注釈"],
        "speakerNotes": ["演讲者备注（默认不选）", "講者備註（預設不選）", "Speaker notes (optional)", "発表者ノート（任意）"],
        "speakerNotesNotSelected": ["未选择演讲者备注", "未選擇講者備註", "Speaker notes not selected", "発表者ノートは未選択"],
        "noSpeakerNotes": ["没有可提取的演讲者备注", "沒有可擷取的講者備註", "No extractable speaker notes", "抽出可能な発表者ノートはありません"],
        "fixedSourceHelp": ["这是生成时保存的固定来源片段。当前文件或转写可能已更改；原片段及时间保留在此。", "這是產生時儲存的固定來源片段。目前檔案或文字轉寫可能已變更；原片段及時間保留於此。", "This is the fixed excerpt saved for the reply. The current document or transcript may have changed; the original excerpt and time remain here.", "回答の生成時に保存した資料の抜粋です。現在の資料や文字起こしが変わっても、元の抜粋と時刻をここに保持します。"],
        "openCurrentSource": ["另外打开当前来源", "另外開啟目前來源", "Open the current source separately", "現在の資料を別に開く"],
        "text": ["文本资料", "文字資料", "Text document", "テキスト資料"],
        "preparing": ["准备来源", "準備來源", "Preparing sources", "資料を準備中"],
        "synthesizing": ["合并已完成的分析", "合併已完成的分析", "Combining completed analyses", "完了した分析を統合中"],
        "partial": ["部分结果已保存", "部分結果已儲存", "Partial results saved", "部分結果を保存済み"],
        "needsReview": ["引用需核查", "引用需核查", "Citations need review", "引用の確認が必要"],
        "interrupted": ["任务中断，已有结果保留", "任務中斷，已有結果保留", "Interrupted; existing results retained", "中断・既存の結果は保持済み"],
        "title": ["标题", "標題", "Title", "タイトル"],
        "location": ["保存位置", "儲存位置", "Save location", "保存先"],
        "version": ["版本", "版本", "Version", "版"],
        "page": ["页", "頁", "Page", "ページ"]
    ]
    static func text(_ key: String, language: String) -> String {
        if let values = rows[key] { return values[["zh-Hans": 0, "zh-Hant": 1, "en": 2, "ja": 3][language] ?? 2] }
        let warningKeys = ["sourceUnavailable", "noConfirmedTranscript", "imageNotAnalyzed", "noExtractableText", "nonTextAnnotation", "imagesFormulasDiagramsNotAnalyzed", "conversionRequired", "speakerNotesNotSelected", "noSpeakerNotes", "localOCRFailed", "ocrLowConfidenceExcluded"]
        for code in warningKeys where key.contains(": ") && key.contains(code) { return key.replacingOccurrences(of: code, with: text(code, language: language)) }
        let common = Localizer.string(key, language: language)
        return common == key ? StatusLocalizer.detail(key, language: language) : common
    }
}
