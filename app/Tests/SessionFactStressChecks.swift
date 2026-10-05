import Foundation
import AVFoundation
import Darwin

private struct StressMarker: Codable { var sessionID: String; var createdAt = Date() }
private struct StressIdentity: Codable { var sessionID: String; var count: Int; var transcriptHash: String; var timelineMS: Int64 }
private struct StressPoint: Codable { var count: Int; var wallSeconds: Double; var batchSeconds: Double; var rssBytes: UInt64; var persistedSessionRows: Int }
private final class StressCredentials: CloudCredentialStore {
    var reads = 0
    func save(_ value: String, reference: String) throws { throw CloudFailure.authentication }
    func read(reference: String) throws -> String? { reads += 1; return nil }
    func remove(reference: String) throws {}
}
private final class StressRequests: URLProtocol {
    static var count = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { Self.count += 1; client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)) }
    override func stopLoading() {}
}
private actor StressCaptureBackend: AudioCaptureBackend {
    var calls = 0
    func requestPermission(for source: AudioSource) async throws { calls += 1; throw CancellationError() }
    func prepare(requestID: UUID) async throws { calls += 1; throw CancellationError() }
    func start(requestID: UUID, configuration: AudioConfiguration, receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void, failed: @escaping @Sendable (String) -> Void) async throws { calls += 1; throw CancellationError() }
    func stop() async throws {}
    func microphoneHealth(configuration: AudioConfiguration) async -> String? { nil }
}

@main struct SessionFactStressChecks {
    static func rss() throws -> UInt64 {
        var info = mach_task_basic_info(), count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count) }
        }
        guard result == KERN_SUCCESS else { throw LibraryError.message("RSS measurement unavailable") }
        return info.resident_size
    }
    static func hash(_ rows: [TranscriptRecord]) throws -> String {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return cloudHash(String(decoding: try encoder.encode(rows.sorted { $0.startMS == $1.startMS ? $0.id < $1.id : $0.startMS < $1.startMS }), as: UTF8.self))
    }
    @MainActor static func main() async throws {
        let out = URL(fileURLWithPath: CommandLine.arguments[1]), mode = CommandLine.arguments[2]
        let library = try LibraryStore(rootURL: out.appendingPathComponent("catalog"))
        try library.configureTranscriptStorage(rootURL: out.appendingPathComponent("independent-transcripts"))
        let started = ProcessInfo.processInfo.systemUptime, initialRSS = try rss()
        func check(_ value: Bool, _ message: String) throws { guard value else { throw LibraryError.message(message) } }
        if mode == "reopen" {
            let expected = try JSONDecoder().decode(StressIdentity.self, from: Data(contentsOf: out.appendingPathComponent("identity.json")))
            let session = try library.item(id: expected.sessionID)!, rows = try library.transcripts(classroomID: session.id)
            let independent = try library.transcriptStore!.records(for: session)!.filter { $0.collection == "transcripts" }.map { try JSONDecoder().decode(TranscriptRecord.self, from: Data($0.json.utf8)) }
            try check(rows.count == expected.count && (try hash(rows)) == expected.transcriptHash && (try hash(independent)) == expected.transcriptHash, "Fresh process transcript count/hash changed")
            try check(try library.classroom(id: session.id)?.timelineMilliseconds == expected.timelineMS, "Fresh process tail timeline changed")
            let queue = try library.record(collection: "cloud-state", id: session.id, as: CloudState.self)!
            try check(queue.jobs.count == expected.count && queue.translationUserPaused, "Fresh process pending queue or pause intent changed")
            try JSONSerialization.data(withJSONObject: ["pid": ProcessInfo.processInfo.processIdentifier, "count": rows.count, "catalogHash": expected.transcriptHash, "sessionHash": try hash(independent), "rssBytes": try rss(), "wallSeconds": ProcessInfo.processInfo.systemUptime - started, "actualAudio": false, "providerRequests": 0], options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("reopen.json"))
            print("PASS: fresh process preserved all \(rows.count) facts and independent session hash"); return
        }
        let session = try library.createStandaloneSession(title: "Synthetic three-hour fact timeline")
        try library.putRecord(collection: "interpretation-sessions", id: session.id, ownerID: session.id, value: StressMarker(sessionID: session.id))
        let epoch = UUID().uuidString, baseDate = Date(timeIntervalSince1970: 1_800_000_000), total = 1800, batchSize = 64
        var points: [StressPoint] = []
        let writeStarted = ProcessInfo.processInfo.systemUptime
        for start in stride(from: 0, to: total, by: batchSize) {
            let end = min(start + batchSize, total), batchStarted = ProcessInfo.processInfo.systemUptime
            let point = try await Task.detached { () -> StressPoint in
                try library.withTransaction {
                    for index in start..<end {
                        let text = "Synthetic persisted fact \(index). Working memory and retrieval evidence. 日本語の固定テキスト。中文固定文本。 " + String(repeating: "Bounded test source. ", count: 8)
                        try library.saveTranscript(TranscriptRecord(id: UUID().uuidString, classroomID: session.id, epochID: epoch, startMS: Int64(index * 6000), endMS: Int64((index + 1) * 6000), text: text, language: index % 2 == 0 ? "en" : "ja", confirmedAt: baseDate.addingTimeInterval(Double(index * 6))))
                    }
                }
                let count = try library.transcriptStore!.records(for: session)!.filter { $0.collection == "transcripts" }.count
                guard count == end else { throw LibraryError.message("Batch did not reach independent session storage") }
                return StressPoint(count: end, wallSeconds: ProcessInfo.processInfo.systemUptime - writeStarted, batchSeconds: ProcessInfo.processInfo.systemUptime - batchStarted, rssBytes: try rss(), persistedSessionRows: count)
            }.value
            points.append(point)
        }
        let writeSeconds = ProcessInfo.processInfo.systemUptime - writeStarted
        let rows = try library.transcripts(classroomID: session.id), digest = try hash(rows)
        var state = CloudState(classID: session.id); state.translationUserPaused = true
        state.jobs = rows.map { CloudTranslationJob(segment: CloudSegment(id: $0.id, classID: $0.classroomID, revision: $0.revision, text: $0.text, language: $0.language, startMS: $0.startMS, endMS: $0.endMS, confirmedAt: $0.confirmedAt), targetLanguage: "zh-Hans", status: .waitingConfiguration, historical: true) }
        try library.withTransaction {
            try library.putRecord(collection: "cloud-state", id: session.id, ownerID: session.id, value: state)
            var record = try library.classroom(id: session.id)!; record.state = "ended"; record.translationUserPaused = true; try library.saveClassroom(record)
        }
        let suite = "local.ulecture.fact-stress." + UUID().uuidString, defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = StressCredentials(), config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StressRequests.self]
        let urlSession = URLSession(configuration: config)
        let settings = CloudServiceSettings(credentials: credentials, session: urlSession, defaults: defaults)
        let models = ModelManager(cacheDirectory: out.appendingPathComponent("unused-model-cache")), backend = StressCaptureBackend()
        let controller = InterpretationController(library: library, models: models, settings: settings, backend: backend, coordinator: CaptureSessionCoordinator(), defaults: defaults, cloudSession: urlSession)
        await controller.selectSession(session.id)
        try check(controller.transcripts.count == total && controller.cloud?.state.jobs.count == total, "Controller did not load complete saved class")
        var captionDurations: [Double] = [], captionRSS: [UInt64] = []
        for index in 0..<240 {
            let begin = ProcessInfo.processInfo.systemUptime
            controller.refreshCaptions(provisional: "Synthetic provisional \(index)")
            captionDurations.append(ProcessInfo.processInfo.systemUptime - begin)
            if index % 24 == 0 { captionRSS.append(try rss()) }
        }
        try check(controller.subtitles.sourceText == "Synthetic provisional 239" && controller.subtitles.translatedText.isEmpty, "Caption snapshot is stale or manufactured a translation")
        let queueSegment = state.jobs[0].segment
        var full = CloudState(classID: session.id); full.translationUserPaused = true
        full.jobs = (0..<CloudController.maxPendingJobs).map { index in
            var segment = queueSegment; segment.id = "queue-limit-\(index)"
            return CloudTranslationJob(segment: segment, targetLanguage: "zh-Hans", historical: true)
        }
        let bounded = CloudController(state: full, session: urlSession, credentials: credentials, monitorNetwork: false)
        var excess = queueSegment; excess.id = "excess"
        var rejected = false
        do { try await bounded.enqueueSavedSegment(excess, targetLanguage: "zh-Hans") } catch CloudFailure.queueFull { rejected = true }
        try check(rejected && bounded.state.jobs.count == CloudController.maxPendingJobs, "Translation queue limit did not reject excess work")
        let backendCalls = await backend.calls
        try check(backendCalls == 0 && credentials.reads == 0 && StressRequests.count == 0 && !controller.subtitles.isVisible && !models.ready, "Stress check unexpectedly crossed a hardware/key/provider/model/UI boundary")
        try check(await controller.prepareForExit(), "Stress controller did not preserve successful shutdown")
        let independent = try library.transcriptStore!.records(for: session)!.filter { $0.collection == "transcripts" }.map { try JSONDecoder().decode(TranscriptRecord.self, from: Data($0.json.utf8)) }
        try check(try hash(independent) == digest && independent.count == total, "Tail session storage differs from catalog")
        let timeline = try library.classroom(id: session.id)!.timelineMilliseconds
        try check(timeline == 10_800_000, "Synthetic timeline does not cover exactly three hours")
        try JSONEncoder().encode(StressIdentity(sessionID: session.id, count: total, transcriptHash: digest, timelineMS: timeline)).write(to: out.appendingPathComponent("identity.json"))
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(points).write(to: out.appendingPathComponent("rss-batches.json"))
        let sorted = captionDurations.sorted(), captionSum = captionDurations.reduce(0, +)
        let report: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "transcriptCount": total, "batchSize": batchSize, "batchCount": points.count, "tailBatchCount": total % batchSize,
            "simulatedTimelineSeconds": 10800, "writeWallSeconds": writeSeconds, "timelineToWriteWallRatio": 10800 / writeSeconds, "totalWallSeconds": ProcessInfo.processInfo.systemUptime - started,
            "initialRSSBytes": initialRSS, "peakObservedRSSBytes": max(points.map(\.rssBytes).max() ?? 0, captionRSS.max() ?? 0), "captionRSSBytes": captionRSS,
            "captionRefreshCount": captionDurations.count, "captionRefreshMeanMS": captionSum / Double(captionDurations.count) * 1000, "captionRefreshP95MS": sorted[Int(Double(sorted.count - 1) * 0.95)] * 1000, "captionRefreshMaxMS": (sorted.last ?? 0) * 1000,
            "pendingJobs": total, "maxPendingJobs": CloudController.maxPendingJobs, "extraJobRejected": rejected, "catalogTranscriptHash": digest, "independentTranscriptHash": try hash(independent),
            "actualHardwareCalls": backendCalls, "credentialReads": credentials.reads, "providerRequests": StressRequests.count, "modelLoaded": models.ready, "playedSound": false,
            "boundary": "1800 synthetic persisted text facts on a three-hour logical timeline, accelerated batched writes and 240 actual caption refreshes; NOT a three-hour real-time, ASR, network, audio or whole-product acceptance"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("stress.json"))
        print("PASS: \(total) synthetic facts, \(points.count) durable batches, \(writeSeconds)s write wall; simulated timeline only")
    }
}
