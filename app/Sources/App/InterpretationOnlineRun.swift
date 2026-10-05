import Foundation
import Combine

/// One application history session, potentially containing several provider
/// connections. Only an explicit start/resume may read credentials.
@MainActor final class InterpretationOnlineRun: ObservableObject {
    enum State: String { case idle, connecting, running, reconnecting, pausing, paused, finishing, ended, failed }
    let capture: AudioCaptureSession
    let settings: InterpretationServiceSettings
    @Published private(set) var state: State = .idle
    @Published private(set) var captions: [InterpretationCaptionRecord] = []
    @Published private(set) var usage: [InterpretationUsageRecord] = []
    @Published private(set) var runtime: InterpretationRuntimeRecord?
    @Published private(set) var errorCode: String?
    @Published private(set) var playbackSkipped = false
    @Published private(set) var tailMayBeIncomplete = false
    @Published var speechEnabled = true { didSet { player.enabled = speechEnabled } }
    @Published var volume: Double = 0.8 { didSet { player.volume = Float(volume) } }
    var onCaptionsChanged: (() -> Void)?
    var onCaptionUpdated: ((InterpretationCaptionRecord) -> Void)?
    var onUsageChanged: (() -> Void)?
    private let library: LibraryStore
    private let player: InterpretationAudioPlaying
    private let factory: @MainActor (InterpretationProvider) -> InterpretationSession
    private let retryDelay: (Int) -> TimeInterval
    private var session: InterpretationSession?
    private var authorization: InterpretationAuthorization?
    private var pump: InterpretationAudioPump?
    private var token = UUID()
    private var connectionStarted: Date?
    private var recordingDirectory: URL?
    private var currentUsage: InterpretationUsageRecord?
    private var openCaptions: [String: String] = [:]
    private var seenEvents = Set<String>()
    private var seenEventOrder: [String] = []
    private var lastSequence: UInt64 = 0
    private var captionSequence: UInt64 = 0
    private var dirtyCaptions: [String: InterpretationCaptionRecord] = [:]
    private var dirtyRuntime = false, dirtyUsage = false
    private var saveTask: Task<Void, Never>?
    private var persistenceTask: Task<Void, Error>?
    private var recoveryTask: Task<Void, Never>?
    private var expiryTask: Task<Void, Never>?
    private var finishTask: Task<Void, Never>?
    private var stopTask: Task<Void, Never>?
    private var endRequested = false
    private var recoveryID: UUID?
    private var queuedRecovery: (failure: InterpretationFailure, planned: Bool)?
    private var attempts: [Date] = []
    private var requestedExpiry: Date?
    private var lastUsagePublished = Date.distantPast
    private var subscriptions = Set<AnyCancellable>()
    var hasUnsavedContent: Bool { persistenceTask != nil || dirtyRuntime || dirtyUsage || !dirtyCaptions.isEmpty }
    var isActive: Bool { [.connecting, .running, .reconnecting, .pausing, .finishing].contains(state) || capture.draining }
    var sourceCaption: String { captions.last(where: { $0.track == "source" })?.text ?? "" }
    var targetCaption: String { captions.last(where: { $0.track == "translation" })?.text ?? "" }

    init(library: LibraryStore, capture: AudioCaptureSession, settings: InterpretationServiceSettings,
         factory: @escaping @MainActor (InterpretationProvider) -> InterpretationSession = { InterpretationSessionFactory.make(provider: $0) },
         player: InterpretationAudioPlaying? = nil,
         retryDelay: @escaping (Int) -> TimeInterval = { pow(2.0, Double($0)) * Double.random(in: 0.8...1.2) }) {
        self.library = library; self.capture = capture; self.settings = settings; self.factory = factory
        self.player = player ?? InterpretationAudioPlayer()
        self.retryDelay = retryDelay
        self.player.onPlayed = { [weak self] seconds in
            guard let self, self.state == .running else { return }
            self.currentUsage?.playedSeconds += seconds; self.markUsageChanged()
        }
        self.player.onSkipped = { [weak self] _ in if self?.playbackSkipped == false { self?.playbackSkipped = true } }
        capture.onDrain = { [weak self] in await self?.drainConnection() }
    }

    func load(sessionID: String) async throws {
        guard !isActive, !hasUnsavedContent else { throw LibraryError.message("sessionSaveFailed") }
        cancelWork(); session?.abort(); session = nil; authorization = nil; player.stop()
        let library = self.library
        let snapshot = try await Task.detached { (try library.interpretationRuntime(sessionID: sessionID), try library.interpretationCaptions(sessionID: sessionID), try library.interpretationUsage(sessionID: sessionID)) }.value
        runtime = snapshot.0; captions = snapshot.1; usage = snapshot.2
        captionSequence = captions.map(\.sequence).max() ?? 0
        currentUsage = nil; openCaptions.removeAll(); seenEvents.removeAll(); seenEventOrder.removeAll()
        errorCode = nil; playbackSkipped = false
        tailMayBeIncomplete = runtime?.closeComplete == false
        // Historical running states are facts, never instructions to connect.
        state = runtime?.state == "ended" ? .ended : runtime?.startedAt == nil ? .idle : .paused
    }

    func start(sessionID: String, mode: InterpretationMode, sourceLanguage: String, targetLanguage: String,
               offset: Double, recordingDirectory: URL?) async {
        guard !isActive, !hasUnsavedContent, state != .ended, let provider = mode.provider else { return }
        self.recordingDirectory = recordingDirectory
        errorCode = nil; playbackSkipped = false; tailMayBeIncomplete = false
        attempts.removeAll(); token = UUID()
        var value = runtime ?? InterpretationRuntimeRecord(sessionID: sessionID)
        value.mode = mode.rawValue; value.provider = provider.rawValue
        value.modelID = settings.profile(for: provider).modelID
        value.sourceLanguage = sourceLanguage; value.subtitleLanguage = targetLanguage
        value.targetLanguage = provider == .google ? targetLanguage : "zh"
        value.startedAt = value.startedAt ?? Date(); value.closeComplete = nil
        runtime = value
        setState(.connecting)
        let startToken = token
        do {
            try await flush()
            try await capture.preflight(sessionID: sessionID, elapsedOffset: offset)
            guard token == startToken, state == .connecting else { throw CancellationError() }
            authorization = try settings.authorize(provider: provider, targetLanguageCode: value.targetLanguage)
            try await connectPrepared(token: startToken)
        } catch {
            guard token == startToken else { return }
            // A user pause/end may cancel setup while preserving the token for
            // draining. That cancellation is not a new connection failure.
            guard ![.pausing, .finishing, .ended, .failed].contains(state) else { return }
            if error is CancellationError, state == .paused { authorization = nil; return }
            closeAdmission(); session?.abort(); session = nil
            await capture.pause(reason: "online-start-failed")
            guard token == startToken, ![.pausing, .finishing, .ended, .failed].contains(state) else { return }
            authorization = nil
            fail(error is AudioFailure ? "online.captureFailed" : InterpretationFailure.fromTransport(error).localizedDescription)
        }
    }

    private func connectPrepared(token expected: UUID) async throws {
        guard let authorization, var value = runtime, token == expected else { throw CancellationError() }
        guard value.generation >= 0, value.generation < Int.max, captionSequence < UInt64(Int64.max) else { throw InterpretationFailure.invalidConfiguration }
        value.generation += 1; value.modelID = authorization.configuration.modelID; runtime = value
        dirtyRuntime = true
        currentUsage = InterpretationUsageRecord(sessionID: value.sessionID, generation: value.generation, provider: value.provider, modelID: value.modelID)
        dirtyUsage = true; lastSequence = 0; seenEvents.removeAll(); seenEventOrder.removeAll(); openCaptions.removeAll()
        requestedExpiry = nil; connectionStarted = Date()
        let active = factory(authorization.configuration.provider)
        session = active
        active.onEvent = { [weak self] event in self?.receive(event, token: expected) }
        try await authorization.start(active)
        guard token == expected, [.connecting, .reconnecting].contains(state), capture.phase == .starting else {
            active.abort(); throw CancellationError()
        }
        if let expiry = requestedExpiry, expiry.timeIntervalSinceNow <= 10 {
            active.abort(); throw InterpretationFailure.sessionExpired
        }
        player.begin(generation: expected); player.enabled = speechEnabled; player.volume = Float(volume)
        let audioPump = InterpretationAudioPump(provider: authorization.configuration.provider, send: { [weak self, weak active] bytes in
            guard let self, let active, self.token == expected, [.running, .finishing].contains(self.state) else { throw CancellationError() }
            try await active.sendAudio(bytes)
            guard self.token == expected else { return }
            self.currentUsage?.uploadedSeconds += Double(bytes.count) / Double(authorization.configuration.provider.inputFormat.bytesPerSecond)
            self.markUsageChanged()
        }, failed: { [weak self] failure in
            guard let self, self.token == expected, self.state == .running else { return }
            self.handleFailure(failure)
        })
        pump = audioPump
        // Hardware callbacks are admitted only after the model acknowledges setup.
        setState(.running)
        try await capture.startPrepared(recordingDirectory: recordingDirectory, onFrame: { audioPump.append($0) })
        guard token == expected, capture.phase == .capturing else { active.abort(); throw CancellationError() }
        setState(.running); scheduleExpiry(); try await flush()
    }

    func capturePhaseChanged(_ phase: AudioPhase) {
        if phase == .paused, [.running, .connecting].contains(state) {
            // Sleep/device failures reach this synchronous path as well.
            closeAdmission(); expiryTask?.cancel()
            errorCode = "online.captureInterrupted"
            setState(.paused)
        }
    }

    func pause() async { await stop(ending: false) }
    func end() async { await stop(ending: true) }
    private func stop(ending: Bool) async {
        guard state != .ended else { return }
        guard errorCode != "online.storage" || !hasUnsavedContent else { return }
        if let stopTask {
            if ending { endRequested = true }
            await stopTask.value
            return
        }
        endRequested = ending
        if ending { capture.stopAdmission(preservingAdmittedFrames: true); player.stop() }
        else { closeAdmission() }
        guard errorCode != "online.storage" || !hasUnsavedContent else { return }
        recoveryTask?.cancel(); recoveryTask = nil; recoveryID = nil; expiryTask?.cancel()
        setState(ending ? .finishing : .pausing)
        let task = Task<Void, Never> { @MainActor [weak self] in
            guard let self else { return }; await self.performStop()
        }
        stopTask = task
        await task.value
        stopTask = nil
    }
    private func performStop() async {
        let ending = endRequested
        // Preserve the token until protocol drain completes so tail captions save.
        if ending { await capture.end() } else { await capture.pause(reason: "user-paused") }
        await drainConnection()
        token = UUID(); authorization = nil
        guard state != .failed else { return }
        if capture.requiresRestartAfterStopFailure { fail("online.captureFailed"); return }
        if endRequested && capture.phase != .ended { await capture.end() }
        setState(endRequested ? .ended : .paused)
        do { try await flush() } catch { storageFailed() }
    }

    private func closeAdmission() {
        let dropped = pump?.stop() ?? 0
        pump = nil; capture.stopAdmission(); player.stop()
        if dropped > 0, let runtime {
            let end = capture.currentOffset
            capture.onGap?(AudioGap(id: UUID().uuidString, sessionID: runtime.sessionID, epochID: capture.epochID,
                reason: "online-unsent-audio-discarded", start: max(0, end - dropped), end: end))
        }
    }
    private func cancelWork() { queuedRecovery = nil; saveTask?.cancel(); saveTask = nil; recoveryTask?.cancel(); recoveryTask = nil; expiryTask?.cancel(); expiryTask = nil }

    private func drainConnection() async {
        if let finishTask { await finishTask.value; return }
        guard let active = session else {
            if currentUsage?.status == "running" { finishUsage(complete: false) }
            do { try await flush() } catch { storageFailed() }
            return
        }
        let closingToken = token
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            var inputDrained = true
            if self.state == .finishing, let audioPump = self.pump {
                inputDrained = await audioPump.finish()
                if self.pump === audioPump { self.pump = nil }
            }
            let result = await active.finish()
            guard self.token == closingToken else { active.abort(); return }
            active.onEvent = nil; active.abort(); self.session = nil
            self.tailMayBeIncomplete = result.tailMayBeIncomplete || !inputDrained
            self.runtime?.closeComplete = !self.tailMayBeIncomplete; self.dirtyRuntime = true
            self.completeOpenCaptions(basis: self.tailMayBeIncomplete ? "interrupted" : "sessionClosed")
            self.finishUsage(complete: !self.tailMayBeIncomplete)
            do { try await self.flush() } catch { self.storageFailed() }
        }
        finishTask = task
        await task.value
        finishTask = nil
    }

    private func receive(_ event: InterpretationSessionEvent, token expected: UUID) {
        guard token == expected, session != nil, ![.idle, .ended, .failed].contains(state) else { return }
        if let id = event.eventID {
            guard seenEvents.insert(id).inserted else { return }
            seenEventOrder.append(id)
            if seenEventOrder.count > 8192 { seenEvents.remove(seenEventOrder.removeFirst()) }
        }
        guard event.sequence > lastSequence else { return }
        lastSequence = event.sequence
        switch event.payload {
        case .ready(_, let expires): requestedExpiry = expires
        case .transcript(let track, let text, let isFinal, let language):
            acceptText(text, track: track.rawValue, isFinal: isFinal, language: language, event: event)
        case .audio(let bytes, let format):
            currentUsage?.generatedSeconds += Double(bytes.count) / Double(format.bytesPerSecond)
            markUsageChanged()
            guard state == .running else { return }
            do { try player.enqueue(bytes, sampleRate: format.sampleRate, channels: format.channels, generation: expected) }
            catch { failAndStop("interpretation.invalidAudio") }
        case .usage(let reported):
            let observation = InterpretationUsageObservation(sequence: event.sequence, eventID: event.eventID,
                observedAt: event.receivedAt, inputTokens: reported.inputTokens, outputTokens: reported.outputTokens,
                totalTokens: reported.totalTokens, isCumulative: reported.isCumulative)
            if var value = currentUsage {
                value.observationCount = (value.observationCount ?? 0) + 1
                value.observations = Array(((value.observations ?? []) + [observation]).suffix(128))
                currentUsage = value
            }
            // Only an explicitly cumulative contract can replace totals. Google's
            // current translation usage semantics remain unverified.
            if reported.isCumulative == true {
                currentUsage?.inputTokens = reported.inputTokens; currentUsage?.outputTokens = reported.outputTokens
                currentUsage?.measurementSource = "providerReported"
            }
            markUsageChanged()
        case .interrupted:
            completeOpenCaptions(basis: "interrupted"); scheduleSave()
            player.stop(); if state == .running { player.begin(generation: expected) }
        case .connectionWillClose(let seconds):
            if state == .running { scheduleRotation(after: max(0, (seconds ?? 1) - 1)) }
        case .closed:
            if state == .running { handleFailure(.connectionLost) }
        case .failure(let failure):
            if state == .running { handleFailure(failure) }
        }
    }

    private func acceptText(_ delta: String, track: String, isFinal: Bool?, language: String?, event: InterpretationSessionEvent) {
        guard let runtime else { return }
        if delta.isEmpty {
            guard isFinal == true, let id = openCaptions[track], let index = captions.firstIndex(where: { $0.id == id }) else { return }
            captions[index].isFinal = true; captions[index].completionBasis = "provider"; captions[index].revision += 1
            captions[index].providerEventReference = event.eventID; captions[index].providerElapsedMS = event.elapsedMS.map(Int64.init)
            dirtyCaptions[id] = captions[index]; openCaptions[track] = nil
            onCaptionUpdated?(captions[index]); onCaptionsChanged?(); scheduleSave(); return
        }
        let receivedMS = max(0, Int64(capture.currentOffset * 1000))
        var row: InterpretationCaptionRecord
        if let id = openCaptions[track], let existing = captions.first(where: { $0.id == id }) {
            row = existing; row.originalText = (row.originalText ?? row.text) + delta; row.revision += 1
        } else {
            // The presentation order uses a signed timeline. Reject exhausted
            // recovered counters before incrementing, including within a run.
            guard captionSequence < UInt64(Int64.max) else { handleFailure(.invalidConfiguration); return }
            row = InterpretationCaptionRecord(sessionID: runtime.sessionID, generation: runtime.generation, track: track,
                text: delta, language: language ?? (track == "translation" ? runtime.targetLanguage : runtime.sourceLanguage), receivedAtMS: receivedMS)
            row.originalText = delta; captionSequence += 1; row.sequence = captionSequence
            row.startMS = receivedMS; row.timingSource = "receiveTime"
            openCaptions[track] = row.id
        }
        let original = row.originalText ?? delta
        if track == "translation" {
            let transform = StringTransform(rawValue: runtime.subtitleLanguage == "zh-Hant" ? "Simplified-Traditional" : "Traditional-Simplified")
            row.text = original.applyingTransform(transform, reverse: false) ?? original
        } else { row.text = original }
        row.endMS = max(row.startMS ?? receivedMS, receivedMS + 1)
        row.providerEventReference = event.eventID
        row.providerElapsedMS = event.elapsedMS.map(Int64.init)
        if isFinal == true { row.isFinal = true; row.completionBasis = "provider"; openCaptions[track] = nil }
        else if row.text.count >= 320 { row.completionBasis = "localBoundary"; openCaptions[track] = nil }
        if let index = captions.firstIndex(where: { $0.id == row.id }) { captions[index] = row } else { captions.append(row) }
        dirtyCaptions[row.id] = row
        if dirtyCaptions.count > 256 { storageFailed(); return }
        onCaptionUpdated?(row); onCaptionsChanged?(); scheduleSave()
    }

    private func completeOpenCaptions(basis: String) {
        for id in openCaptions.values {
            guard let index = captions.firstIndex(where: { $0.id == id }) else { continue }
            captions[index].completionBasis = basis; captions[index].revision += 1
            dirtyCaptions[id] = captions[index]; onCaptionUpdated?(captions[index])
        }
        openCaptions.removeAll()
    }

    private func handleFailure(_ failure: InterpretationFailure) {
        guard state == .running else { return }
        if !failure.isRetryable { failAndStop(failure == .bufferOverflow ? "online.backpressure" : failure.localizedDescription); return }
        recover(failure: failure, planned: false)
    }

    private func recover(failure: InterpretationFailure, planned: Bool) {
        guard state == .running else { return }
        if recoveryTask != nil {
            // A just-connected socket can send GoAway/failure while the prior
            // recovery still awaits its durable checkpoint. Keep one follow-up
            // instead of silently dropping the event or creating parallel work.
            if queuedRecovery == nil || !planned { queuedRecovery = (failure, planned) }
            return
        }
        closeAdmission()
        guard state == .running else { return }
        expiryTask?.cancel(); setState(.reconnecting)
        let recoveryToken = token
        let workID = UUID(); recoveryID = workID
        recoveryTask = Task { @MainActor [weak self] in
            guard let self else { return }
            defer {
                if self.recoveryID == workID {
                    self.recoveryTask = nil; self.recoveryID = nil
                    let queued = self.queuedRecovery; self.queuedRecovery = nil
                    if let queued, self.state == .running { self.recover(failure: queued.failure, planned: queued.planned) }
                }
            }
            if !planned { self.session?.abort(); self.session = nil; self.completeOpenCaptions(basis: "interrupted") }
            await self.capture.pause(reason: planned ? "online-session-rotation" : "online-connection-gap")
            await self.drainConnection()
            guard self.token == recoveryToken, self.state == .reconnecting, !Task.isCancelled else { return }
            var last = failure
            for attempt in 0..<3 {
                self.attempts.removeAll { Date().timeIntervalSince($0) > 300 }
                // Planned rotations share the same rolling cap: repeated GoAway
                // or short-lived sessions must not create a billable reconnect loop.
                guard self.attempts.count < 3 else { break }
                self.attempts.append(Date())
                if !planned || attempt > 0 {
                    let delay = max(0, self.retryDelay(attempt))
                    do { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) } catch { return }
                }
                guard self.token == recoveryToken, self.state == .reconnecting, !Task.isCancelled, let value = self.runtime else { return }
                var attemptToken = recoveryToken
                do {
                    try await self.capture.preflight(sessionID: value.sessionID, elapsedOffset: self.capture.currentOffset)
                    // A distinct token prevents late events from previous sockets.
                    self.token = UUID(); let next = self.token
                    attemptToken = next
                    try await self.connectPrepared(token: next)
                    return
                } catch {
                    // A paused/replaced attempt must not abort a newer session
                    // when its delayed handshake or hardware error arrives.
                    guard self.token == attemptToken, self.state == .reconnecting, !Task.isCancelled else { return }
                    last = InterpretationFailure.fromTransport(error)
                    self.session?.abort(); self.session = nil; self.closeAdmission()
                    await self.capture.pause(reason: "online-reconnect-failed")
                    self.finishUsage(complete: false)
                    guard self.state == .reconnecting, !Task.isCancelled else { return }
                    self.token = recoveryToken
                    if !last.isRetryable { break }
                }
            }
            self.fail(last.localizedDescription); self.authorization = nil
        }
    }

    private func scheduleExpiry() {
        guard let expiry = requestedExpiry else { return }
        scheduleRotation(after: max(0, expiry.timeIntervalSinceNow - 10))
    }
    private func scheduleRotation(after seconds: Double) {
        expiryTask?.cancel(); let expected = token
        expiryTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(min(seconds, 86_400) * 1_000_000_000)) } catch { return }
            guard let self, self.token == expected, self.state == .running else { return }
            self.recover(failure: .sessionExpired, planned: true)
        }
    }

    private func setState(_ value: State) {
        if state != value { state = value }
        if runtime != nil { runtime?.state = value.rawValue; runtime?.updatedAt = Date(); dirtyRuntime = true }
        scheduleSave()
    }
    private func markUsageChanged() {
        guard currentUsage != nil else { return }
        currentUsage?.updatedAt = Date(); dirtyUsage = true
        if Date().timeIntervalSince(lastUsagePublished) >= 1 { publishUsage(); lastUsagePublished = Date() }
        scheduleSave()
    }
    private func publishUsage() {
        guard var value = currentUsage else { return }
        if let connectionStarted { value.connectionSeconds = max(value.connectionSeconds, Date().timeIntervalSince(connectionStarted)) }
        if let provider = InterpretationProvider(rawValue: value.provider), value.modelID == provider.defaultModelID {
            value.estimatedCostUSD = provider == .google ?
                (value.uploadedSeconds * 0.00525 + value.generatedSeconds * 0.0315) / 60 : value.uploadedSeconds * (0.034 + 0.017) / 60
        } else { value.estimatedCostUSD = nil }
        currentUsage = value
        if let index = usage.firstIndex(where: { $0.id == value.id }) { if usage[index] != value { usage[index] = value } }
        else { usage.append(value) }
    }
    private func finishUsage(complete: Bool) {
        guard currentUsage != nil else { return }
        currentUsage?.status = complete ? "completed" : "interrupted"
        currentUsage?.updatedAt = Date(); publishUsage(); dirtyUsage = true
        connectionStarted = nil
    }

    private func scheduleSave() {
        guard saveTask == nil else { return }
        saveTask = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: 250_000_000) } catch { return }
            guard let self else { return }; self.saveTask = nil
            do { try await self.flush() } catch { self.storageFailed() }
        }
    }
    func retrySave() async {
        do {
            try await flush()
            if errorCode == "online.storage" { errorCode = nil }
            if runtime?.state == "ended" { state = .ended }
        } catch { storageFailed() }
    }
    /// Only this task acknowledges durable receipts. Incoming revisions remain
    /// dirty while a snapshot is writing, and never get cleared by an older save.
    private func flush() async throws {
        saveTask?.cancel(); saveTask = nil
        while let active = persistenceTask { try await active.value }
        guard dirtyRuntime || dirtyUsage || !dirtyCaptions.isEmpty else { return }
        if dirtyUsage { publishUsage() }
        let savedRuntime = dirtyRuntime ? runtime : nil
        let savedUsage = dirtyUsage ? currentUsage : nil
        let savedCaptions = dirtyCaptions, library = self.library
        let work = Task { @MainActor [self] in
            do {
                try await Task.detached(priority: .utility) {
                    try library.withTransaction {
                        if let savedRuntime { try library.saveInterpretationRuntime(savedRuntime) }
                        for row in savedCaptions.values where !row.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { try library.saveInterpretationCaption(row) }
                        if let savedUsage { try library.saveInterpretationUsage(savedUsage) }
                    }
                }.value
                if runtime == savedRuntime { dirtyRuntime = false }
                if currentUsage == savedUsage { dirtyUsage = false }
                for (id, row) in savedCaptions where dirtyCaptions[id] == row { dirtyCaptions[id] = nil }
                persistenceTask = nil; onUsageChanged?()
            } catch { persistenceTask = nil; throw error }
        }
        persistenceTask = work
        try await work.value
        if dirtyRuntime || dirtyUsage || !dirtyCaptions.isEmpty { scheduleSave() }
    }
    func handlePersistenceFailure() { storageFailed() }
    private func storageFailed() {
        guard !(state == .failed && errorCode == "online.storage") else { return }
        // Set the barrier first: recording/gap persistence may synchronously
        // call this again while closing capture admission.
        errorCode = "online.storage"; state = .failed; token = UUID()
        if runtime?.state != "ended" { runtime?.state = "failed" }
        runtime?.errorCode = "storage"; runtime?.closeComplete = false; dirtyRuntime = true
        completeOpenCaptions(basis: "interrupted"); finishUsage(complete: false)
        closeAdmission(); recoveryTask?.cancel(); expiryTask?.cancel(); saveTask?.cancel(); saveTask = nil
        session?.onEvent = nil; session?.abort(); session = nil; authorization = nil
        capture.stopImmediately(reason: "storage-failure")
    }
    private func fail(_ code: String) {
        errorCode = code; setState(.failed); runtime?.errorCode = code; runtime?.closeComplete = false
        finishUsage(complete: false)
        Task { [weak self] in do { try await self?.flush() } catch { self?.storageFailed() } }
    }
    private func failAndStop(_ code: String) {
        closeAdmission()
        guard errorCode != "online.storage" else { return }
        expiryTask?.cancel(); session?.onEvent = nil; session?.abort(); session = nil
        authorization = nil; fail(code); capture.stopImmediately(reason: code)
    }
}
