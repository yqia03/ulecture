import SwiftUI
import Combine

struct TranscriptPane: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var prefs: AppPreferences
    let classID: String
    @ObservedObject var audio: AudioController
    @State private var showControls = false
    @State private var showSpeechControls = false
    @State private var followLatest = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var record: ClassroomRecord { model.classRecords[classID] ?? ClassroomRecord(id: classID) }
    var cloud: CloudController? { model.clouds[classID] }
    var running: Bool { model.activeClassID == classID && [.capturing, .starting].contains(audio.phase) }
    var body: some View {
        VStack(spacing: 0) {
            DisclosureGroup(model.t("source"), isExpanded: $showControls) { controls }.padding(.horizontal, 14).padding(.top, 10).padding(.bottom, 6)
            if let cloud {
                DisclosureGroup(isExpanded: $showSpeechControls) { speechControls(cloud) } label: {
                    Text(model.t("speech") + " · " + model.detail(cloud.speech.status)).font(.caption)
                }.padding(.horizontal, 14).padding(.bottom, 8)
                if cloud.speech.enabled || audio.playbackPosition != nil {
                    Button(model.t("stopSound")) { cloud.stopSpeech(); audio.stopPlayback() }.font(.caption).fixedSize().padding(.bottom, 8)
                }
                queueHeader(cloud).padding(.horizontal, 14).padding(.bottom, 10)
            }
            Divider()
            ScrollViewReader { scroll in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 20) {
                        if (model.transcriptRows[classID] ?? []).isEmpty { Text(model.t("noTranscript")).foregroundStyle(.secondary).padding(.top, 30) }
                        ForEach(model.transcriptRows[classID] ?? []) { row in
                            segment(row).padding(8).overlay(RoundedRectangle(cornerRadius: 6).stroke(model.transcriptFocusIDs[classID] == row.id ? Color.accentColor : Color.clear)).id(row.id)
                        }
                        if model.activeClassID == classID && !audio.provisional.isEmpty {
                            VStack(alignment: .leading, spacing: 5) { Text(model.t("provisional")).font(.caption); Text(audio.provisional).font(.system(size: prefs.captionSize)).italic() }.foregroundStyle(.secondary)
                        }
                        Color.clear.frame(height: 1).id("latest")
                    }.padding(16)
                }
                .background(ScrollIntentMonitor { followLatest = false })
                .onChange(of: model.transcriptRows[classID]?.last?.id) { _, _ in if followLatest { withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { scroll.scrollTo("latest", anchor: .bottom) } } }
                .onChange(of: model.transcriptFocusIDs[classID]) { _, id in if let id { followLatest = false; scroll.scrollTo(id, anchor: .center) } }
                .onAppear { if let id = model.transcriptFocusIDs[classID] { followLatest = false; scroll.scrollTo(id, anchor: .center) } }
                HStack {
                    Slider(value: $prefs.captionSize, in: 13...30).frame(width: 100).accessibilityLabel(model.t("subtitleSize"))
                    Spacer(); Button(model.t("latest")) { followLatest = true; withAnimation(reduceMotion ? nil : .easeOut(duration: 0.16)) { scroll.scrollTo("latest", anchor: .bottom) } }.font(.caption).fixedSize()
                }.padding(10)
            }
        }
        .onAppear { model.ensureCloud(classID); audio.refreshDevices() }
    }
    func queueHeader(_ cloud: CloudController) -> some View {
        let counts = CloudQueueOverview(jobs: cloud.state.jobs)
        let status = cloud.queueStatus == "idle" ? (cloud.state.jobs.contains { $0.status == .retryWaiting } ? "retryWaiting" : (counts.needsAttention > 0 ? "needsAttention" : (counts.pending > 0 ? "queued" : "idle"))) : cloud.queueStatus
        return VStack(alignment: .leading, spacing: 7) {
            Text(cloud.configuration.provider.displayName + " · " + model.cloudStatus(status)).font(.caption.weight(.medium))
            Text("\(model.t("completed")): \(counts.completed) · \(model.t("pendingTranslation")): \(counts.pending) · \(model.t("needsAttention")): \(counts.needsAttention)").font(.caption)
            Text("\(model.t("currentQueue")): \(counts.currentPending) · \(model.t("historicalQueue")): \(counts.historicalPending)").font(.caption).foregroundStyle(.secondary)
            if counts.historicalPending > 0 { Text(model.t("historyPriorityHelp")).font(.caption2).foregroundStyle(.secondary) }
            if counts.historicalRunning > 0 { Text(model.t("historyTranslating") + " · \(counts.historicalRunning)").font(.caption2) }
            ViewThatFits(in: .horizontal) {
                HStack { queueActions(cloud) }
                VStack(alignment: .leading, spacing: 6) { queueActions(cloud) }
            }.controlSize(.small)
            if let code = cloud.queueErrorCode { Text(model.cloudStatus(code)).font(.caption).foregroundStyle(.secondary) }
            if let courseID = model.items.first(where: { $0.id == classID })?.courseID {
                ClassroomTerminologyView(cloud: cloud, terminology: model.textTranslation, classID: classID, courseID: courseID)
            }
            CloudUsageView(usage: cloud.state.usage)
        }
    }
    @ViewBuilder func queueActions(_ cloud: CloudController) -> some View {
        Button(model.t(cloud.state.translationUserPaused ? "resumeTranslation" : "pauseTranslation")) { model.enqueueSessionWork { await cloud.setUserPaused(!cloud.state.translationUserPaused) } }.fixedSize().disabled(model.library?.isReadOnly == true)
        Button(model.t("checkServiceSettings")) { model.route = "settings" }.fixedSize()
    }
    var controls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(model.t("source"), selection: classBinding(\.inputSource)) { Text(model.t("microphone")).tag("microphone"); Text(model.t("systemAudio")).tag("system") }
            if record.inputSource == "microphone" {
                Picker(model.t("device"), selection: Binding(get: { record.inputDeviceID ?? "" }, set: { v in model.updateClass(classID) { $0.inputDeviceID = v.isEmpty ? nil : v } })) {
                    Text("— " + model.t("device") + " —").tag("")
                    ForEach(audio.devices) { device in Text(device.name).tag(String(device.id)) }
                }
                Button(model.t("refresh")) { audio.refreshDevices() }.controlSize(.small).fixedSize()
            }
            Picker(model.t("mainLanguage"), selection: classBinding(\.mainLanguage)) { Text("English").tag("en"); Text("日本語").tag("ja") }
            Picker(model.t("targetLanguage"), selection: classBinding(\.targetLanguage)) { Text("简体中文").tag("zh-Hans"); Text("繁體中文").tag("zh-Hant") }
            Toggle(model.t("recording"), isOn: Binding(get: { record.recordingEnabled }, set: { value in model.updateClass(classID) { $0.recordingEnabled = value } }))
            Text(model.t("recordingHelp")).font(.caption2).foregroundStyle(.secondary)
            if running { Text(model.t("pause") + " → " + model.t("settings")).font(.caption) }
            if model.activeClassID == classID {
                ProgressView(value: max(0, min(1, (audio.level + 80) / 80))).accessibilityLabel(model.t("source"))
                Text(model.detail(audio.status)).font(.caption).textSelection(.enabled)
            }
            if let recordings = model.recordingsByClass[classID], !recordings.isEmpty {
                DisclosureGroup(model.t("savedRecordings") + " · \(recordings.count)") {
                    ForEach(recordings) { recording in
                        HStack {
                            Text(timeLabel(recording.startMS) + " – " + timeLabel(recording.endMS)).font(.caption.monospacedDigit())
                            Spacer()
                            Button(model.t("play")) {
                                do { if let url = try model.library?.attachmentURL(assetID: recording.assetID) { try audio.playRecording(url: url) } }
                                catch { model.report(error) }
                            }.controlSize(.mini).fixedSize().disabled(running)
                        }
                    }
                }
            }
            if let gaps = model.gapsByClass[classID], !gaps.isEmpty {
                DisclosureGroup(model.t("gaps") + " · \(gaps.count)") {
                    ForEach(gaps) { gap in Text(timeLabel(gap.startMS) + " – " + timeLabel(gap.endMS ?? gap.startMS) + " · " + model.detail(gap.reason)).font(.caption2).textSelection(.enabled) }
                }
            }
        }.padding(.top, 12)
            .disabled(model.busy)
    }
    func speechControls(_ cloud: CloudController) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle(model.t("speech"), isOn: Binding(get: { cloud.speech.enabled }, set: { value in if value { cloud.speech.enable() } else { cloud.stopSpeech() } })).disabled(!running)
            if !cloud.speech.voices.isEmpty {
                Picker(model.t("speech"), selection: Binding(get: { cloud.speech.selectedVoiceID ?? "" }, set: { cloud.speech.selectedVoiceID = $0 })) { ForEach(cloud.speech.voices) { Text($0.name + " · " + $0.language).tag($0.id) } }
            }
            Text(model.t("speechHelp")).font(.caption2).foregroundStyle(.secondary)
            if cloud.speech.skippedCount > 0 { Text(model.t("speechSkipped") + " (\(cloud.speech.skippedCount))").font(.caption2).foregroundStyle(.secondary) }
            Button(model.t("refreshVoices")) { cloud.speech.refreshVoices() }.font(.caption).fixedSize()
            if let position = audio.playbackPosition {
                VStack(alignment: .leading, spacing: 6) {
                    Text(model.t("recordingOffset") + " · " + timeLabel(Int64(position * 1000))).font(.caption.monospacedDigit())
                    Button(model.t(audio.playbackPaused ? "resume" : "pause")) {
                        if audio.playbackPaused { do { try audio.resumePlayback() } catch { model.report(error) } }
                        else { audio.pausePlayback() }
                    }.controlSize(.small).fixedSize()
                }
            }
        }.padding(.top, 10).disabled(model.busy)
    }
    func classBinding(_ key: WritableKeyPath<ClassroomRecord, String>) -> Binding<String> {
        Binding(get: { record[keyPath: key] }, set: { value in model.updateClass(classID) { $0[keyPath: key] = value } })
    }
    func segment(_ row: TranscriptRecord) -> some View {
        let job = cloud?.state.jobs.last { $0.segment.id == row.id && $0.segment.revision == row.revision }
        let recording = model.recordingsByClass[classID]?.first { $0.startMS <= row.startMS && $0.endMS > row.startMS }
        return VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(timeLabel(row.startMS) + " – " + timeLabel(row.endMS)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                Spacer()
                if let recording {
                    Button(model.t("play")) {
                        do { if let url = try model.library?.attachmentURL(assetID: recording.assetID) { try audio.playRecording(url: url, from: Double(row.startMS - recording.startMS) / 1000) } }
                        catch { model.report(error) }
                    }.controlSize(.mini).fixedSize()
                } else { Text(model.t("noRecording")).font(.caption2).foregroundStyle(.tertiary) }
            }
            Text(row.text).font(.system(size: prefs.captionSize)).textSelection(.enabled)
            if let translated = job?.translation { Text(translated.text).font(.system(size: prefs.captionSize)).foregroundStyle(.secondary).textSelection(.enabled) }
            if let job {
                HStack {
                    Text(model.cloudStatus(job.status.rawValue)).font(.caption)
                    if job.historical { Text(model.t("historicalQueue")).font(.caption2).foregroundStyle(.secondary) }
                }
                if let code = job.errorCode { Text(model.cloudStatus(code)).font(.caption).foregroundStyle(.secondary) }
                if job.status != .completed && job.attempts > 0 { Text("\(model.t("attempts")): \(job.attempts) / \(CloudController.maxAttempts)").font(.caption2) }
                if job.status == .retryWaiting, let next = job.nextAttemptAt { Text(model.t("nextRetry") + " · " + next.formatted(date: .omitted, time: .standard)).font(.caption2) }
                if job.status == .needsAttention {
                    Text(model.t("retryService") + " · " + (cloud?.configuration.provider.displayName ?? "")).font(.caption2)
                    ViewThatFits(in: .horizontal) {
                        HStack { retryActions(job) }
                        VStack(alignment: .leading, spacing: 6) { retryActions(job) }
                    }.controlSize(.mini)
                    Text(model.t("sentMayCharge")).font(.caption2).foregroundStyle(.secondary)
                }
                if !job.dispatches.isEmpty {
                    DisclosureGroup(model.t("requestHistory")) {
                        ForEach(job.dispatches) { dispatch in
                            Text(dispatch.sentAt.formatted() + " · " + dispatch.configuration.provider.displayName + " · " + dispatch.preset.model).font(.caption2).textSelection(.enabled)
                        }
                    }.font(.caption2)
                }
            } else {
                Text(model.t("notQueued")).font(.caption).foregroundStyle(.secondary)
                Button(model.t("reconcileTranslations")) { model.reconcileTranslations(classID) }.font(.caption).fixedSize().disabled(model.library?.isReadOnly == true)
            }
        }
    }
    @ViewBuilder func retryActions(_ job: CloudTranslationJob) -> some View {
        Button(model.t("retry")) { model.enqueueSessionWork { await cloud?.retry(jobID: job.id) } }.fixedSize().disabled(model.library?.isReadOnly == true || job.errorCode == "persistence")
        Button(model.t("checkServiceSettings")) { model.route = "settings" }.fixedSize()
    }
}

func timeLabel(_ milliseconds: Int64) -> String {
    let seconds = max(0, milliseconds / 1000)
    return String(format: "%02lld:%02lld:%02lld", seconds / 3600, (seconds / 60) % 60, seconds % 60)
}

struct SummaryPane: View {
    @EnvironmentObject var model: AppModel
    let classID: String
    @State private var selectedAssets = Set<String>()
    @State private var useTranscript = true
    @State private var useNotes = true
    @State private var showSources = true
    var cloud: CloudController? { model.clouds[classID] }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Text(model.t("summary")).font(.title2.weight(.semibold))
                Text(model.t("summaryHelp")).font(.callout).foregroundStyle(.secondary)
                DisclosureGroup(model.t("selectedMaterials"), isExpanded: $showSources) {
                    VStack(alignment: .leading) {
                        ForEach(model.classroomPDFs(classID)) { pdf in
                            if let asset = pdf.assetID { Toggle(pdf.title, isOn: Binding(get: { selectedAssets.contains(asset) }, set: { if $0 { selectedAssets.insert(asset) } else { selectedAssets.remove(asset) } })) }
                        }
                        Toggle(model.t("transcript"), isOn: $useTranscript)
                        Toggle(model.t("allClassNotes"), isOn: $useNotes)
                        SummaryMaterialsView(classID: classID, assetIDs: selectedAssets, useTranscript: useTranscript, useNotes: useNotes)
                    }.padding(.top, 8)
                }
                Text(model.cloudConfiguration.provider.displayName).font(.caption)
                if cloud?.credentialUnlocked != true {
                    Text(model.t("missingCredential")).font(.caption).foregroundStyle(.secondary)
                    Button(model.t("checkServiceSettings")) { model.route = "settings" }.font(.caption)
                }
                if cloud?.summaryRunning == true { ProgressView(); Button(model.t("cancel")) { model.enqueueSessionWork { await cloud?.cancelSummary() } } }
                else {
                    Button(model.t("generateSummary")) { model.makeSummary(classID, assetIDs: selectedAssets, useTranscript: useTranscript, useNotes: useNotes) }
                        .disabled(model.classRecords[classID]?.state != "ended" || model.library?.isReadOnly == true)
                }
                if let error = cloud?.summaryError { Text(model.detail(error.localizedDescription)).foregroundStyle(.secondary).font(.callout) }
                ForEach((cloud?.state.summaries ?? []).reversed()) { summary in
                    Divider()
                    Text(model.t("aiLabel")).font(.headline)
                    Text(summary.createdAt.formatted() + " · " + model.cloudStatus(summary.status)).font(.caption).foregroundStyle(.secondary)
                    Text(summary.dispatch.configuration.provider.displayName + " · " + summary.dispatch.preset.model).font(.caption2).foregroundStyle(.secondary)
                    if model.summaryIsStale(summary) { Text(model.t("summaryStale")).font(.caption).foregroundStyle(.secondary) }
                    if let code = summary.errorCode { Text(model.cloudStatus(code)).font(.caption).foregroundStyle(.secondary) }
                    Text("\(model.t("processedChunks")): \(summary.completedChunkIDs.count) / \(summary.chunks.count)").font(.caption)
                    if !summary.missingChunkIDs.isEmpty { Text(model.t("summaryPartial")).font(.caption).foregroundStyle(.secondary) }
                    DisclosureGroup(model.t("allCoverage")) {
                        LazyVStack(alignment: .leading, spacing: 8) {
                            ForEach(SummaryPresentation.coverage(summary)) { coverage in
                                VStack(alignment: .leading, spacing: 3) {
                                    Button(sourceLabel(coverage.source)) { openSource(coverage.source) }.buttonStyle(.link).disabled(!coverage.source.isValid)
                                    Text("\(coverage.processedCharacters) / \(coverage.totalCharacters) " + model.t("characters") + " · " + model.t(coverage.isComplete ? "completed" : "partial")).foregroundStyle(.secondary)
                                }.font(.caption)
                            }
                        }.padding(.top, 6)
                    }
                    if !summary.snapshot.sources.contains(where: { $0.kind == .pdf }) { Text(model.t("noPDFForSummary")).font(.caption).foregroundStyle(.secondary) }
                    if !summary.snapshot.excluded.isEmpty { Text(summary.snapshot.excluded.joined(separator: "\n")).font(.caption2).foregroundStyle(.secondary) }
                    if !summary.missingChunkIDs.isEmpty || summary.invalidReferenceCount > 0 {
                        Text("\(model.t("missingChunks")): \(summary.missingChunkIDs.count) · \(model.t("invalidReferences")): \(summary.invalidReferenceCount)").font(.caption).foregroundStyle(.secondary)
                        DisclosureGroup(model.t("missingChunks")) {
                            ForEach(summary.chunks.filter { summary.missingChunkIDs.contains($0.id) }) { chunk in
                                ForEach(Array(chunk.spans.enumerated()), id: \.offset) { _, span in
                                    if let source = summary.source(for: span.sourceID) { Text(sourceLabel(source) + " · " + model.t("characters") + " \(span.startCharacter + 1)–\(span.startCharacter + span.characterCount) · " + model.cloudStatus(chunk.status)).font(.caption) }
                                }
                            }
                        }
                    }
                    ForEach(summary.claims) { claim in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(claim.text).textSelection(.enabled)
                            if claim.referenceIDs.isEmpty { Text(model.t("noVerifiableReference")).font(.caption).foregroundStyle(.secondary) }
                            ForEach(claim.referenceIDs, id: \.self) { reference in
                                if let source = summary.source(for: reference) {
                                    Button(sourceLabel(source)) { openSource(source) }.buttonStyle(.link).font(.caption)
                                } else { Text(model.t("noVerifiableReference")).font(.caption).foregroundStyle(.secondary) }
                            }
                        }
                    }
                    ViewThatFits(in: .horizontal) {
                        HStack { summaryActions(summary) }
                        VStack(alignment: .leading, spacing: 6) { summaryActions(summary) }
                    }
                    if ["partial", "failed", "cancelled", "interrupted"].contains(summary.status) {
                        Text(model.t("retrySnapshotHelp") + " · " + model.cloudConfiguration.provider.displayName).font(.caption2).foregroundStyle(.secondary)
                        Button(model.t("retrySnapshot")) { model.enqueueSessionWork { await cloud?.generateSummary(summary.snapshot, classEnded: model.classRecords[classID]?.state == "ended") } }
                            .disabled(cloud?.summaryRunning == true || model.library?.isReadOnly == true || cloud?.credentialUnlocked != true)
                    }
                }
                if let cloud { CloudUsageView(usage: cloud.state.usage) }
            }.padding(20)
        }.onAppear { model.ensureCloud(classID); selectedAssets = Set(model.classroomPDFs(classID).compactMap(\.assetID)) }
    }
    @ViewBuilder func summaryActions(_ summary: CloudSummary) -> some View {
        Button(model.t("copy")) { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(summary.markdown, forType: .string) }.fixedSize()
        Button(model.t("appendNotes")) { model.appendSummary(summary, classID: classID) }.fixedSize().disabled(summary.claims.isEmpty || model.library?.isReadOnly == true)
    }
    func sourceLabel(_ source: SummarySource) -> String {
        switch source.kind {
        case .pdf: return (model.items.first { $0.assetID == source.entityID }?.title ?? "PDF") + " · \(model.t("page")) \(source.page ?? 1)"
        case .transcript: return timeLabel(source.startMS ?? 0) + " – " + timeLabel(source.endMS ?? 0)
        case .note: return (model.items.first { $0.id == source.entityID }?.title ?? model.t("notes")) + " · " + model.t("noteSnapshot") + " v\(source.version)"
        }
    }
    func openSource(_ source: SummarySource) {
        if source.kind == .pdf, let item = model.visibleItems.first(where: { $0.assetID == source.entityID }) {
            model.pdfPages[item.id] = source.page ?? 1; model.pdfSelection[classID] = item.id; model.preferences.panel = "pdf"
        } else if source.kind == .transcript,
                  let row = (model.transcriptRows[classID] ?? []).first(where: { $0.id == source.entityID }),
                  SummaryPresentation.matchesCurrentTranscript(source, model.cloudSegment(row)) {
            model.transcriptFocusIDs[classID] = row.id; model.preferences.panel = "transcript"
        } else {
            if source.kind != .note { model.notice = model.t("sourceSnapshotOnly") }
            model.sourcePreview = source
        }
    }
}

struct ScrollIntentMonitor: NSViewRepresentable {
    let onScroll: () -> Void
    func makeNSView(context: Context) -> View { let view = View(); view.onScroll = onScroll; return view }
    func updateNSView(_ view: View, context: Context) { view.onScroll = onScroll }
    final class View: NSView {
        var onScroll: (() -> Void)?; var monitor: Any?
        override init(frame frameRect: NSRect) {
            super.init(frame: frameRect)
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                if let self, event.window === self.window, self.bounds.contains(self.convert(event.locationInWindow, from: nil)), abs(event.scrollingDeltaY) > 0 { self.onScroll?() }
                return event
            }
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
        deinit { if let monitor { NSEvent.removeMonitor(monitor) } }
    }
}
