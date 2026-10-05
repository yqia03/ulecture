import Foundation
import AVFoundation
import Combine

extension AppModel {
    func ensureCloud(_ id: String) {
        guard clouds[id] == nil, let library else { return }
        do {
            var state = try library.record(collection: "cloud-state", id: id, as: CloudState.self) ?? CloudState(classID: id)
            state.translationUserPaused = classRecords[id]?.translationUserPaused ?? state.translationUserPaused
            let controller = CloudController(state: state, configuration: cloudConfiguration, monitorNetwork: !library.isReadOnly)
            controller.onPersist = { [weak self, weak library] state in
                guard let library else { throw LibraryError.message("Library closed") }
                // A read-only display controller has no credentials, network monitor,
                // enqueues or enabled mutation controls. Its shutdown is not a write.
                if library.isReadOnly { return }
                do { try await SessionDiskExecutor.shared.run { try library.withTransaction {
                    try library.putRecord(collection: "cloud-state", id: id, ownerID: id, value: state)
                    if var record = try library.classroom(id: id) {
                        record.translationUserPaused = state.translationUserPaused
                        try library.saveClassroom(record)
                    }
                } } } catch { self?.storageFailed(error); throw error }
                self?.classRecords[id]?.translationUserPaused = state.translationUserPaused
                self?.usageRevision += 1
            }
            controller.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
            controller.speech.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }.store(in: &subscriptions)
            clouds[id] = controller
            guard !library.isReadOnly else { return }
            if cloudEnabledForRun { controller.credentialResolver = { [weak self] config in try self?.cloudService.credential(for: config) } }
            // A crash between transcript commit and queue creation is reconciled here.
            enqueueSessionWork { [weak self, weak controller] in
                guard let self, let controller else { return }
                do {
                    let rows = try await SessionDiskExecutor.shared.run { try library.transcripts(classroomID: id) }
                    for row in rows { try await controller.enqueueSavedSegment(self.cloudSegment(row), targetLanguage: self.classRecords[id]?.targetLanguage ?? "zh-Hans", historical: true) }
                } catch { self.report(error) }
            }
        } catch { report(error) }
    }
    func cloudSegment(_ row: TranscriptRecord) -> CloudSegment {
        CloudSegment(id: row.id, classID: row.classroomID, revision: row.revision, text: row.text, language: row.language, startMS: row.startMS, endMS: row.endMS, confirmedAt: row.confirmedAt)
    }
    func applyCloudConfiguration(_ config: CloudConfiguration) {
        let next = config
        cloudConfiguration = next
        if let data = try? JSONEncoder().encode(next) { preferences.defaults.set(data, forKey: "cloudConfiguration") }
        let targets = Array(clouds.values)
        enqueueSessionWork { [weak self] in
            guard let self else { return }; await self.serviceSettings.configure(next)
            for cloud in targets { await cloud.configure(next) }
        }
    }
    func saveCredential(_ secret: String) {
        do {
            try cloudService.saveCredential(secret)
            notice = t("saved")
        } catch { report(error) }
    }
    func enableCloud() {
        cloudEnabledForRun = true
        if library?.isReadOnly != true {
            let targets = Array(clouds.values)
            enqueueSessionWork { [weak self] in for cloud in targets { cloud.credentialResolver = { [weak self] config in try self?.cloudService.credential(for: config) }; await cloud.pump() } }
        }
    }
    func removeCredential() {
        do { try cloudService.removeCredential() }
        catch { report(error) }
    }
    func updateClass(_ id: String, change: @escaping (inout ClassroomRecord) -> Void) {
        guard library?.isReadOnly != true else { error = t("readOnly"); return }
        guard var record = classRecords[id] else { return }
        if activeClassID == id && [.capturing, .starting].contains(audio.phase) {
            enqueueSessionWork { [weak self] in await self?.clouds[id]?.setClassActive(false) }
            Task { await audio.pause(reason: "configuration-change"); await drainSessionWork(); updateClass(id, change: change) }
            return
        }
        change(&record); record.updatedAt = Date(); classRecords[id] = record; pendingClassRecords[id] = record
        enqueueSessionWork { [weak self] in await self?.saveClassCheckpoint(record) }
    }
    func startClass(_ id: String) {
        guard let library, var record = classRecords[id], record.state != "ended", !pendingEndIDs.contains(id), !busy else { return }
        guard workspaceCatalog == nil || transcriptStorageReady else { error = t("transcriptStorageUnavailable"); return }
        guard audio.phase != .capturing && audio.phase != .starting else { error = t("pause"); return }
        guard models.ready || models.resourcesAvailable else { route = "setup"; notice = t("prepare"); return }
        guard pendingTranscripts.isEmpty && pendingRecordings.isEmpty && pendingGaps.isEmpty else { notice = t("saveFailed"); return }
        guard flushDrafts() else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let offset = try await prepareClassAudio(id, in: library)
                record = try await SessionDiskExecutor.shared.run { try library.classroom(id: id) } ?? record
                let recordingDir = record.recordingEnabled ? recordingDirectory(id) : nil
                try await audio.start(sessionID: id, elapsedOffset: offset, recordingDirectory: recordingDir)
                clouds[id]?.credentialResolver = { [weak self] config in try self?.cloudService.credential(for: config) }
                await clouds[id]?.pump()
                await clouds[id]?.setClassActive(true)
            } catch {
                record = classRecords[id] ?? record
                record.state = "paused"; classRecords[id] = record
                do { try await SessionDiskExecutor.shared.run { try library.saveClassroom(record) } } catch { storageFailed(error) }
                report(error)
            }
        }
    }
    func prepareClassAudio(_ id: String, in library: LibraryStore) async throws -> Double {
        try await SessionDiskExecutor.shared.run { try library.checkWritable() }
        await drainSessionWork()
        await probe.pause(reason: "configuration-change")
        audio.stopPlayback()
        ensureCloud(id); await drainSessionWork()
        for cloud in clouds.values { await cloud.waitForPersistence() }
        guard !hasUnsavedContent else { throw LibraryError.message("sessionSaveFailed") }
        guard var record = try await SessionDiskExecutor.shared.run({ try library.classroom(id: id) }) else { throw LibraryError.message("Library unavailable") }
        // Capture the interrupted anchor before configure emits a paused phase.
        let offset = try await resumeOffset(record, in: library)
        activeClassID = id
        if audio.sessionID != id { audio.selectSession(ended: false) }
        var config = AudioConfiguration()
        config.source = record.inputSource == "system" ? .system : .microphone
        config.deviceID = record.inputDeviceID.flatMap(UInt32.init)
        config.language = record.mainLanguage; config.saveRecording = record.recordingEnabled
        await audio.configure(config)
        record = try await SessionDiskExecutor.shared.run { try library.classroom(id: id) } ?? record
        record.state = "preparing"; try await SessionDiskExecutor.shared.run { try library.saveClassroom(record) }; classRecords[id] = record
        return offset
    }
    // A process restart loses the monotonic clock origin. Retain the saved timeline
    // and label the wall-clock estimate explicitly; never invent captured audio.
    func resumeOffset(_ record: ClassroomRecord, in library: LibraryStore, now: Date = Date(), uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) async throws -> Double {
        var offset = Double(record.timelineMilliseconds) / 1000
        if record.state == "interrupted" && audio.sessionID != record.id {
            let end = record.timelineMilliseconds + Int64(max(0, now.timeIntervalSince(record.updatedAt)) * 1000)
            let gap = TimelineGap(classroomID: record.id, epochID: nil, startMS: record.timelineMilliseconds, endMS: end, reason: "recovered-interruption-wall-clock-estimate")
            try await SessionDiskExecutor.shared.run { try library.saveGap(gap) }
            gapsByClass[record.id, default: []].append(gap)
            offset = Double(end) / 1000
        } else if let paused = pauseAnchors[record.id] {
            offset += max(0, uptime - paused)
            // The audio controller owns same-session pause gaps. Switching classes
            // resets its clock, so persist that missing interval before rebinding.
            if audio.sessionID != record.id {
                let gap = TimelineGap(classroomID: record.id, epochID: nil, startMS: record.timelineMilliseconds, endMS: Int64(offset * 1000), reason: "paused-no-audio")
                try await SessionDiskExecutor.shared.run { try library.saveGap(gap) }
                gapsByClass[record.id, default: []].append(gap)
                pauseAnchors[record.id] = uptime
            }
        }
        return offset
    }
    func pauseClass() {
        clouds.values.forEach { $0.stopSpeech() }
        Task {
            for cloud in clouds.values { await cloud.setClassActive(false) }
            await audio.pause(reason: "user-paused"); await drainSessionWork()
            for cloud in clouds.values { await cloud.waitForPersistence() }
        }
    }
    func endClass(_ id: String) {
        guard library?.isReadOnly != true else { error = t("readOnly"); return }
        guard var record = classRecords[id] else { return }
        pendingEndIDs.insert(id)
        busy = true; clouds[id]?.stopSpeech()
        Task {
            defer { busy = false }
            await clouds[id]?.setClassActive(false)
            if activeClassID == id { await audio.end() }
            await drainSessionWork(); await clouds[id]?.waitForPersistence()
            if activeClassID == id && audio.phase != .ended {
                pendingEndIDs.remove(id); error = audio.status; return
            }
            record = classRecords[id] ?? record
            guard !hasUnsavedContent else { pendingEndIDs.insert(id); record.state = "paused"; classRecords[id] = record; error = t("saveFailed"); return }
            if activeClassID == id { record.timelineMilliseconds = max(record.timelineMilliseconds, Int64(audio.currentOffset * 1000)) }
            record.state = "ended"; record.updatedAt = Date()
            do { guard let library else { throw LibraryError.message("Library unavailable") }; try await SessionDiskExecutor.shared.run { try library.saveClassroom(record) }; classRecords[id] = record; pendingEndIDs.remove(id) } catch { storageFailed(error) }
        }
    }
    func audioPhaseChanged(_ phase: AudioPhase) {
        guard [.capturing, .paused, .ended].contains(phase) else { return }
        guard let id = activeClassID, var record = classRecords[id] else { return }
        if phase == .capturing { record.state = "capturing" }
        else if phase == .paused { record.state = "paused"; pauseAnchors[id] = ProcessInfo.processInfo.systemUptime }
        else if phase == .ended { if hasUnsavedContent { pendingEndIDs.insert(id) }; record.state = hasUnsavedContent ? "paused" : "ended" }
        record.timelineMilliseconds = max(record.timelineMilliseconds, Int64(audio.currentOffset * 1000)); record.updatedAt = Date()
        classRecords[id] = record // Runtime truth is visible even when its checkpoint fails.
        pendingClassRecords[id] = record
        enqueueSessionWork { [weak self] in
            guard let self else { return }
            if phase != .capturing { await self.clouds[id]?.setClassActive(false) }
            await self.saveClassCheckpoint(record)
        }
    }
    private func saveClassCheckpoint(_ record: ClassroomRecord) async {
        guard let library else { return }
        let id = record.id
        var checkpoint = record
        checkpoint.translationUserPaused = clouds[id]?.state.translationUserPaused ?? record.translationUserPaused
        do { try await SessionDiskExecutor.shared.run { try library.saveClassroom(checkpoint) }; if pendingClassRecords[id]?.updatedAt == record.updatedAt { pendingClassRecords[id] = nil } }
        catch { storageFailed(error) }
    }
    func acceptTranscript(_ value: AudioTranscript) {
        let row = TranscriptRecord(id: value.id, classroomID: value.sessionID, epochID: value.epochID, startMS: Int64(value.start * 1000), endMS: Int64(value.end * 1000), text: value.text, language: value.language, revision: value.revision, confirmedAt: value.confirmedAt)
        if let index = pendingTranscripts.firstIndex(where: { $0.id == row.id }) {
            if pendingTranscripts[index].revision < row.revision { pendingTranscripts[index] = row }
        } else { pendingTranscripts.append(row) }
        ensureCloud(row.classroomID)
        enqueueSessionWork { [weak self] in await self?.saveConfirmedTranscript(row) }
    }
    private func saveConfirmedTranscript(_ row: TranscriptRecord) async {
        do {
            guard let library else { throw LibraryError.message("Library unavailable") }
            try await SessionDiskExecutor.shared.run { try library.saveTranscript(row) }
            #if AUDIO_TESTING
            onTranscriptSavedForChecks?(row)
            #endif
            pendingTranscripts.removeAll { $0.id == row.id && $0.revision <= row.revision }
            if let index = transcriptRows[row.classroomID]?.firstIndex(where: { $0.id == row.id }) {
                if transcriptRows[row.classroomID]![index].revision < row.revision { transcriptRows[row.classroomID]![index] = row }
            } else { transcriptRows[row.classroomID, default: []].append(row) }
            do { try await clouds[row.classroomID]?.enqueueSavedSegment(cloudSegment(row), targetLanguage: classRecords[row.classroomID]?.targetLanguage ?? "zh-Hans") }
            catch { report(error) }
        } catch { storageFailed(error) }
    }
    func acceptGap(_ value: AudioGap) {
        if !pendingGaps.contains(where: { $0.id == value.id }) { pendingGaps.append(value) }
        enqueueSessionWork { [weak self] in await self?.saveGap(value) }
    }
    private func saveGap(_ value: AudioGap) async {
        do {
            guard let library else { throw LibraryError.message("Library unavailable") }
            let gap = TimelineGap(id: value.id, classroomID: value.sessionID, epochID: value.epochID, startMS: Int64(value.start * 1000), endMS: Int64(value.end * 1000), reason: value.reason)
            try await SessionDiskExecutor.shared.run { try library.saveGap(gap) }
            pendingGaps.removeAll { $0.id == value.id }
            if !gapsByClass[value.sessionID, default: []].contains(where: { $0.id == gap.id }) { gapsByClass[value.sessionID, default: []].append(gap) }
        } catch { storageFailed(error) }
    }
    func recordingDirectory(_ id: String) -> URL? {
        if let library, let store = library.transcriptStore, let session = try? library.item(id: id) {
            return try? store.directory(for: session).appendingPathComponent("recording-staging", isDirectory: true)
        }
        return library?.rootURL.appendingPathComponent("recording-staging/\(id)", isDirectory: true)
    }
    func recoverStagedRecordings() {
        guard let library, !library.isReadOnly else { return }
        for item in items where item.kind == .classroom {
            guard let directory = recordingDirectory(item.id), let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { continue }
            for file in files where file.pathExtension == "caf" {
                do {
                    guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw LibraryError.message("Recording staging link rejected") }
                    let fields = file.deletingPathExtension().lastPathComponent.split(separator: "_").map(String.init)
                    guard fields.count == 3, UUID(uuidString: fields[0]) != nil, let offset = Int64(fields[1]), offset >= 0, UUID(uuidString: fields[2]) != nil else { continue }
                    let audioFile = try AVAudioFile(forReading: file)
                    guard audioFile.length > 0, audioFile.fileFormat.sampleRate > 0 else { continue }
                    let start = Double(offset) / 1000, end = start + Double(audioFile.length) / audioFile.fileFormat.sampleRate
                    let value = AudioRecording(id: fields[2], sessionID: item.id, epochID: fields[0], filename: file.lastPathComponent, start: start, end: end, frames: audioFile.length, verified: true)
                    enqueueSessionWork { [weak self] in
                        guard let self else { return }; let saved = await self.acceptRecording(value)
                        self.notice = self.t("interrupted") + " · " + self.t(saved ? "saved" : "saveFailed") + " " + timeLabel(offset) + "–" + timeLabel(Int64(end * 1000))
                    }
                } catch { report(error) }
            }
        }
    }
    @discardableResult func acceptRecording(_ value: AudioRecording) async -> Bool {
        guard let library, let dir = recordingDirectory(value.sessionID) else { return false }
        let url = dir.appendingPathComponent(value.filename)
        do {
            try await SessionDiskExecutor.shared.run {
            let key = value.id
            if try library.record(collection: "recording-receipts", id: key, as: String.self) == nil {
                try library.withTransaction {
                    _ = try library.importRecording(from: url, classroomID: value.sessionID, epochID: value.epochID, startMS: Int64(value.start * 1000), endMS: Int64(value.end * 1000))
                    try library.putRecord(collection: "recording-receipts", id: key, ownerID: value.sessionID, value: "committed")
                }
            }
            try? FileManager.default.removeItem(at: url) // Only our staging copy, after managed commit.
            }
            pendingRecordings.removeAll { $0.id == value.id }
            recordingsByClass[value.sessionID] = try await SessionDiskExecutor.shared.run { try library.recordings(classroomID: value.sessionID) }
            return true
        } catch { if !pendingRecordings.contains(where: { $0.id == value.id }) { pendingRecordings.append(value) }; storageFailed(error); return false }
    }
    func retryUnsaved() { enqueueSessionWork { [weak self] in await self?.retryUnsavedNow() } }
    private func retryUnsavedNow() async {
        guard flushDrafts() else { return }
        do {
            guard let library else { return }; try await SessionDiskExecutor.shared.run { try library.checkWritable() }
            for (id, value) in pendingClassRecords {
                var record = value
                if let cloud = clouds[id] { record.translationUserPaused = cloud.state.translationUserPaused }
                try await SessionDiskExecutor.shared.run { try library.saveClassroom(record) }; classRecords[id] = record; pendingClassRecords[id] = nil
            }
            for row in pendingTranscripts { await saveConfirmedTranscript(row) }
            for gap in pendingGaps { await saveGap(gap) }
            for recording in pendingRecordings { _ = await acceptRecording(recording) }
            for (id, cloud) in clouds {
                await cloud.resumeAfterPersistenceRepair(); let rows = try await SessionDiskExecutor.shared.run { try library.transcripts(classroomID: id) }; transcriptRows[id] = rows
                for row in rows { try await cloud.enqueueSavedSegment(cloudSegment(row), targetLanguage: classRecords[id]?.targetLanguage ?? "zh-Hans", historical: true) }
            }
            if pendingClassRecords.isEmpty && pendingTranscripts.isEmpty && pendingRecordings.isEmpty && pendingGaps.isEmpty && !clouds.values.contains(where: { $0.lastError == .persistence }) {
                for id in Array(pendingEndIDs) {
                    guard var record = try await SessionDiskExecutor.shared.run({ try library.classroom(id: id) }) else { continue }
                    record.state = "ended"; record.updatedAt = Date()
                    if audio.sessionID == id { record.timelineMilliseconds = max(record.timelineMilliseconds, Int64(audio.currentOffset * 1000)) }
                    try await SessionDiskExecutor.shared.run { try library.saveClassroom(record) }; classRecords[id] = record; pendingEndIDs.remove(id)
                }
            }
            if !hasUnsavedFacts { notice = t("saved") }
        } catch { storageFailed(error) }
    }
    func classroomNote(_ id: String) -> WorkspaceItem? {
        let linked = projectDocumentIDs(for: id)
        let notes = items.filter { $0.kind == .note && $0.deletedAt == nil && linked.contains($0.id) }
        return notes.first { $0.id == classNoteIDs[id] } ?? notes.first
    }
    func reconcileTranslations(_ id: String) {
        guard let library, !library.isReadOnly else { return }
        ensureCloud(id)
        enqueueSessionWork { [weak self] in
            guard let self else { return }
            do { let rows = try await SessionDiskExecutor.shared.run { try library.transcripts(classroomID: id) }
                for row in rows { try await self.clouds[id]?.enqueueSavedSegment(self.cloudSegment(row), targetLanguage: self.classRecords[id]?.targetLanguage ?? "zh-Hans", historical: true) }
            } catch { self.report(error) }
        }
    }
    func classroomPDFs(_ id: String) -> [WorkspaceItem] { let linked = projectDocumentIDs(for: id); return items.filter { $0.kind == .pdf && $0.deletedAt == nil && linked.contains($0.id) } }
    func selectedPDF(_ id: String) -> WorkspaceItem? { classroomPDFs(id).first { $0.id == pdfSelection[id] } ?? classroomPDFs(id).first }
    func makeSummary(_ id: String, assetIDs: Set<String>, useTranscript: Bool, useNotes: Bool) {
        guard let library, !library.isReadOnly, flushDrafts() else { return }
        ensureCloud(id)
        do {
            let snapshot = try buildSummarySnapshot(id, assetIDs: assetIDs, useTranscript: useTranscript, useNotes: useNotes)
            clouds[id]?.credentialResolver = { [weak self] config in try self?.cloudService.credential(for: config) }
            let ended = classRecords[id]?.state == "ended"
            enqueueSessionWork { [weak self] in await self?.clouds[id]?.generateSummary(snapshot, classEnded: ended) }
        } catch { report(error) }
    }
    func buildSummarySnapshot(_ id: String, assetIDs: Set<String>, useTranscript: Bool, useNotes: Bool) throws -> SummarySnapshot {
        guard let library, let record = classRecords[id] else { throw LibraryError.message("Classroom not found") }
        var sources: [SummarySource] = [], excluded = [t("pdfHelp")]
        for pdf in classroomPDFs(id) {
            guard let asset = pdf.assetID, assetIDs.contains(asset) else { excluded.append(pdf.title); continue }
            for page in try library.pdfPages(assetID: asset) {
                if page.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { excluded.append("\(pdf.title) · \(t("page")) \(page.pageNumber)"); continue }
                sources.append(SummarySource(kind: .pdf, entityID: asset, version: page.version, text: page.text, page: page.pageNumber))
            }
        }
        if useTranscript { for row in try library.transcripts(classroomID: id) { sources.append(SummarySource(kind: .transcript, entityID: row.id, version: row.revision, text: row.text, startMS: row.startMS, endMS: row.endMS)) } }
        if useNotes {
            for note in visibleItems.filter({ $0.kind == .note && $0.classroomID == id }) {
                if let revision = try library.noteRevision(noteID: note.id), !revision.markdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { sources.append(SummarySource(kind: .note, entityID: note.id, version: revision.version, text: revision.markdown)) }
            }
        }
        return SummarySnapshot(classID: id, targetLanguage: record.targetLanguage, sources: sources, excluded: excluded)
    }
    func appendSummary(_ summary: CloudSummary, classID: String) {
        guard let note = classroomNote(classID) else { return }
        loadDraft(note.id); editNote(note.id, value: (drafts[note.id] ?? "") + "\n\n" + summary.markdown); _ = saveDraft(note.id)
        preferences.panel = "notes"
    }
    func summaryIsStale(_ summary: CloudSummary) -> Bool {
        guard let library else { return false }
        let materials = visibleItems.filter { $0.classroomID == summary.snapshot.classID }
        if materials.contains(where: { $0.createdAt > summary.snapshot.createdAt }) { return true }
        for note in materials where note.kind == .note {
            if let saved = try? library.noteRevision(noteID: note.id), saved.savedAt > summary.snapshot.createdAt { return true }
        }
        if let rows = try? library.transcripts(classroomID: summary.snapshot.classID), rows.contains(where: { $0.confirmedAt > summary.snapshot.createdAt }) { return true }
        for source in summary.snapshot.sources {
            switch source.kind {
            case .note:
                if !materials.contains(where: { $0.id == source.entityID }) { return true }
                if (try? library.noteRevision(noteID: source.entityID)?.version) != source.version { return true }
            case .pdf:
                if !visibleItems.contains(where: { $0.assetID == source.entityID }) { return true }
                if (try? library.pdfPages(assetID: source.entityID).first?.version) != source.version { return true }
            case .transcript:
                if (try? library.record(collection: "transcripts", id: source.entityID, as: TranscriptRecord.self)?.revision) != source.version { return true }
            }
        }
        return false
    }
}
