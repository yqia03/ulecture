import AppKit
import SwiftUI
import PDFKit
import CoreText
import AVFoundation
import Combine
import CryptoKit
import Darwin
import Vision
import QuartzCore

// A process-owned real RootView, production editors/ASR/recording/persistence,
// and an in-memory HTTP fixture. No device capture, real credentials or cloud.
private final class PerformanceCredentials: CloudCredentialStore {
    func save(_ value: String, reference: String) throws {}
    func read(reference: String) throws -> String? { "fictional-performance-key" }
    func remove(reference: String) throws {}
}
private final class PerformanceHTTP: URLProtocol {
    static let lock = NSLock(); static var count = 0
    static var pendingFailures = 0, failureIDs: [String] = [], recoveredIDs = Set<String>()
    static func armFailure() { lock.lock(); pendingFailures += 1; lock.unlock() }
    static func faultSnapshot() -> [String: Any] { lock.lock(); defer { lock.unlock() }; return ["pending": pendingFailures, "failedSegmentIDs": failureIDs, "retriedSuccessfully": Array(recoveredIDs).sorted()] }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            var bytes = request.httpBody ?? Data()
            if bytes.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }; var buffer = [UInt8](repeating: 0, count: 8192)
                while stream.hasBytesAvailable { let n = stream.read(&buffer, maxLength: buffer.count); if n <= 0 { break }; bytes.append(contentsOf: buffer.prefix(n)) }
            }
            let body = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
            let contents = body["contents"] as! [[String: Any]], parts = contents[0]["parts"] as! [[String: Any]]
            let source = try JSONSerialization.jsonObject(with: Data((parts[0]["text"] as! String).utf8)) as! [String: Any]
            let value: [String: Any] = ["id": source["id"]!, "text": "虚构课程回放：学习者把课堂资料、听课理解和学习记录联系起来。"]
            let text = String(decoding: try JSONSerialization.data(withJSONObject: value), as: UTF8.self)
            let data = try JSONSerialization.data(withJSONObject: ["candidates": [["finishReason": "STOP", "content": ["parts": [["text": text]]]]], "usageMetadata": ["promptTokenCount": 20, "candidatesTokenCount": 10]])
            Self.lock.lock(); Self.count += 1
            let segmentID = source["id"] as! String, fail = Self.pendingFailures > 0
            if fail { Self.pendingFailures -= 1; Self.failureIDs.append(segmentID) }
            else if Self.failureIDs.contains(segmentID) { Self.recoveredIDs.insert(segmentID) }
            Self.lock.unlock()
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { [self] in
                client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: fail ? 503 : 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json", "Retry-After": "1"])!, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: fail ? Data("{\"error\":{\"message\":\"Fictional recoverable outage\"}}".utf8) : data); client?.urlProtocolDidFinishLoading(self)
            }
        } catch { client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() {}
}
/// A synthetic device clock on its own queue: UI stalls do not stop audio delivery.
private final class PerformanceAudioFeeder: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.ulecture.performance-device", qos: .userInitiated)
    private let lock = NSLock()
    private var timer: DispatchSourceTimer?, frameCount = 0, lateCallbacks = 0
    func start(samples: [Float], receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void) {
        let timer = DispatchSource.makeTimerSource(queue: queue); self.timer = timer
        var cursor = 0, expected = ProcessInfo.processInfo.systemUptime
        timer.schedule(deadline: .now(), repeating: .milliseconds(100), leeway: .milliseconds(2))
        timer.setEventHandler { [self] in
            let time = ProcessInfo.processInfo.systemUptime
            if time - expected > 0.5 { lock.lock(); lateCallbacks += 1; lock.unlock() }
            expected = time + 0.1
            let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1600)!; buffer.frameLength = 1600
            for index in 0..<1600 { buffer.floatChannelData![0][index] = cursor < samples.count ? samples[cursor] : 0; cursor += 1; if cursor >= samples.count + 32000 { cursor = 0 } }
            receive(buffer); lock.lock(); frameCount += 1600; lock.unlock()
        }; timer.resume()
    }
    func stop() async { timer?.cancel(); timer = nil; await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
    func snapshot() -> (frames: Int, late: Int) { lock.lock(); defer { lock.unlock() }; return (frameCount, lateCallbacks) }
}
@MainActor private final class PerformanceScrollFrames: NSObject {
    let scroll: NSScrollView
    private var link: CADisplayLink?, completion: CheckedContinuation<Void, Never>?
    private var previous = 0.0, index = 0
    init(scroll: NSScrollView) { self.scroll = scroll }
    func run() async {
        await withCheckedContinuation { continuation in
            completion = continuation
            link = PerformanceChecks.window.displayLink(target: self, selector: #selector(frame(_:)))
            link?.add(to: .main, forMode: .common)
        }
    }
    @objc private func frame(_ link: CADisplayLink) {
        let time = PerformanceChecks.now()
        if previous > 0 { PerformanceChecks.metrics["noteDisplayLinkFrameInterval", default: Metric()].add(time - previous) }
        previous = time
        let clip = scroll.contentView, maximum = max(0, (scroll.documentView?.bounds.height ?? 0) - clip.bounds.height)
        clip.scroll(to: NSPoint(x: 0, y: min(maximum, CGFloat(index) * 100))); scroll.reflectScrolledClipView(clip)
        PerformanceChecks.draw(); PerformanceChecks.mark("noteDisplayLinkScrollLayout", time)
        index += 1
        if index >= 121 { link.invalidate(); self.link = nil; completion?.resume(); completion = nil }
    }
}
struct PerformanceFixture: Codable { var course: String; var classroom: String; var note: String; var pdf: String }
struct PerformanceIdentity: Codable { var classroom: String; var count: Int; var hash: String; var recordings: Int; var seconds: Double; var textHashes: [String: String]? = nil; var recordedFrames: Int64? = nil }
struct Metric {
    var count = 0, total = 0.0, maximum = 0.0
    var histogram = [Int](repeating: 0, count: 60002)
    mutating func add(_ seconds: Double) { let ms = max(0, seconds * 1000); count += 1; total += ms; maximum = max(maximum, ms); histogram[min(60001, Int(ms))] += 1 }
    var json: [String: Any] {
        var sum = 0, p95 = 0; for (index, value) in histogram.enumerated() { sum += value; if sum >= Int(ceil(Double(count) * 0.95)) { p95 = index; break } }
        return ["count": count, "meanMS": total / Double(max(1, count)), "p95UpperMS": p95 + 1, "maxMS": maximum, "histogramOverflow": histogram[60001]]
    }
}

@main @MainActor enum PerformanceChecks {
    static var metrics: [String: Metric] = [:], failures: [String] = [], subscriptions = Set<AnyCancellable>()
    static var confirmed = 0, gaps = 0, recordings = 0, provisional = 0, publications = 0
    static var recordedFrames: Int64 = 0
    static var stoppingForCompletion = false, plannedPauseInProgress = false, unexpectedGaps = 0
    static var pauseEvents: [[String: Any]] = [], epochs = Set<String>(), plannedPausedSeconds = 0.0
    static var retryWaitingObserved = Set<String>(), lastConfirmedEndByEpoch: [String: Double] = [:]
    static var pendingReceiptTimes: [String: Double] = [:]
    static var lastSource = "", lastTranslation = "", sampleFrames = 0
    static var out: URL!, model: AppModel!, host: NSHostingView<RootView>!, window: NSWindow!, captions: SubtitlePanelController!
    static var processEntry = 0.0
    static var stage = "start"
    static func checkpoint(_ text: String) { stage = text; print("STAGE " + text); fflush(stdout) }
    static var full: Bool { arg("--dataset") == "full" }; static var pages: Int { full ? 300 : 40 }
    static var fixture: PerformanceFixture!, csv: FileHandle!, started = 0.0
    static func now() -> Double { ProcessInfo.processInfo.systemUptime }
    static var queuedSessionOperations: Int {
        #if PERFORMANCE_CURRENT
        return model?.pendingSessionOperations ?? 0
        #else
        return 0
        #endif
    }
    static func arg(_ name: String) -> String? { CommandLine.arguments.firstIndex(of: name).flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil } }
    static func mark(_ name: String, _ begin: Double) { metrics[name, default: Metric()].add(now() - begin) }
    static func require(_ value: Bool, _ text: String) throws { if !value { throw NSError(domain: "PerformanceChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) } }
    static func json(_ value: Any, _ filename: String) throws { try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent(filename), options: .atomic) }
    static func rss() -> UInt64 { var info = mach_task_basic_info(), n = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / 4); let result = withUnsafeMutablePointer(to: &info) { $0.withMemoryRebound(to: integer_t.self, capacity: Int(n)) { task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &n) } }; return result == KERN_SUCCESS ? info.resident_size : 0 }
    static func cpu() -> Double { var use = rusage(); getrusage(RUSAGE_SELF, &use); return Double(use.ru_utime.tv_sec + use.ru_stime.tv_sec) + Double(use.ru_utime.tv_usec + use.ru_stime.tv_usec) / 1e6 }
    static func hash(_ rows: [TranscriptRecord]) throws -> String { let e = JSONEncoder(); e.outputFormatting = [.sortedKeys]; return SHA256.hash(data: try e.encode(rows.sorted { $0.id < $1.id })).map { String(format: "%02x", $0) }.joined() }
    #if PERFORMANCE_CURRENT
    static func textHashes(_ library: LibraryStore, id: String) throws -> [String: String] {
        guard let store = library.transcriptStore, let item = try library.item(id: id) else { throw DocumentFailure.invalidFormat }
        var result: [String: String] = [:]
        for kind in TranscriptTextKind.allCases {
            let data = try Data(contentsOf: store.fileURL(for: item, kind: kind))
            try require(String(data: data, encoding: .utf8) != nil, "TXT was not UTF-8")
            result[kind.filename] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
        let source = try String(contentsOf: store.fileURL(for: item, kind: .source), encoding: .utf8)
        let bilingual = try String(contentsOf: store.fileURL(for: item, kind: .bilingual), encoding: .utf8)
        try require(!source.contains("虚构课程回放") && bilingual.contains("虚构课程回放"), "Source-only/bilingual projection mixed tracks")
        return result
    }
    #endif
    static func main() {
        processEntry = ProcessInfo.processInfo.systemUptime
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { do { try await run()
            #if !PERFORMANCE_CURRENT
            if arg("--audio") != nil && !CommandLine.arguments.contains("--baseline-normal-exit") {
                print("BASELINE_BENCHMARK_ONLY: known ggml static-destructor failure bypassed after durable reports; normal exit is NOT validated"); fflush(stdout); _exit(0)
            }
            #endif
            exit(0)
        } catch {
            print("FAIL: \(error.localizedDescription)")
            if out != nil { try? json(["error": error.localizedDescription, "wallSeconds": started == 0 ? 0 : now() - started, "failures": failures, "stage": stage, "metrics": metrics.mapValues(\.json)], "failure.json") }
            #if PERFORMANCE_CURRENT
            if model != nil { await model.audio.pause(reason: "performance-check-failed"); await model.drainSessionWork(); for cloud in model.clouds.values { await cloud.shutdown() }; _ = await model.models.unload() }
            #endif
            exit(1)
        } }
        NSApplication.shared.run()
    }
    static func pdf(_ url: URL) throws {
        var rect = CGRect(x: 0, y: 0, width: 612, height: 792)
        let context = CGContext(url as CFURL, mediaBox: &rect, nil)!
        for page in 1...pages {
            context.beginPDFPage(nil); context.setFillColor(NSColor.white.cgColor); context.fill(rect)
            for line in 0..<24 { context.textPosition = CGPoint(x: 35, y: 740 - 27 * line); CTLineDraw(CTLineCreateWithAttributedString(NSAttributedString(string: "Fictional lecture \(page).\(line): Working memory · 中文 · 日本語", attributes: [.font: NSFont.systemFont(ofSize: 14)])), context) }
            if CommandLine.arguments.contains("--production-workload") {
                // A deterministic mixed text/vector/raster PDF, without private media.
                context.setFillColor(NSColor.systemGray.cgColor); context.fillEllipse(in: CGRect(x: 45, y: 25, width: 70, height: 55))
                let raster = CGContext(data: nil, width: 128, height: 64, bitsPerComponent: 8, bytesPerRow: 512, space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
                for stripe in 0..<8 { raster.setFillColor(NSColor(calibratedWhite: CGFloat(stripe) / 8, alpha: 1).cgColor); raster.fill(CGRect(x: stripe * 16, y: 0, width: 16, height: 64)) }
                context.draw(raster.makeImage()!, in: CGRect(x: 150, y: 25, width: 128, height: 64))
            }
            context.endPDFPage()
        }; context.closePDF()
    }
    static func prepare(_ root: URL) throws -> PerformanceFixture {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let library = try LibraryStore(rootURL: root.appendingPathComponent("Workspace")), catalog = WorkspaceCatalog(library: library)
        try library.configureTranscriptStorage(rootURL: root.appendingPathComponent("Transcripts"))
        let course = try catalog.createCourse(title: "Fictional learning laboratory"), classroom = try catalog.create(kind: .classroom, title: "Sustained fictional audio replay", parentID: course.id)
        let note = try catalog.create(kind: .note, title: "Fictional study notes", parentID: course.id)
        let source = root.appendingPathComponent("Lecture.pdf"); try pdf(source)
        let item = try catalog.importDocument(from: source, parentID: course.id)
        if CommandLine.arguments.contains("--production-workload") {
            let annotations = PDFAnnotationStore(documentID: item.id, sourceURL: try catalog.documentURL(id: item.id), sidecarURL: try catalog.metadataDirectory(documentID: item.id))
            var archive = try annotations.load().annotations
            archive.annotations = (0..<(full ? 500 : 1000)).map { index in
                let x = CGFloat(30 + (index % 10) * 40), y = CGFloat(120 + (index % 15) * 30)
                return StoredPDFAnnotation(kind: .rectangle, page: (index % pages) + 1, bounds: CGRect(x: x, y: y, width: 20, height: 10))
            }
            _ = try annotations.save(archive)
        }
        let store = BlockNoteStore(packageURL: try catalog.documentURL(id: note.id), noteID: note.id)
        var noteDocument = try store.create(title: note.title)
        noteDocument.blocks = (0..<(full ? 1000 : 80)).map { NoteBlock(kind: .paragraph, text: "Fictional study paragraph \($0). " + String(repeating: "Learning connects evidence with earlier knowledge. ", count: 4)) }; _ = try store.save(noteDocument)
        for index in 0..<60 { _ = try catalog.create(kind: .folder, title: "Fictional section \(index)", parentID: course.id) }
        if full {
            var courses = [course]
            for index in 1..<100 { courses.append(try catalog.createCourse(title: "Fictional course \(index)")) }
            for index in 0..<998 {
                let source = root.appendingPathComponent("Material-\(index).txt")
                try Data("Fictional lesson \(index): retrieval practice and contextual learning.".utf8).write(to: source)
                _ = try catalog.importDocument(from: source, parentID: courses[index % courses.count].id)
            }
            for index in 0..<20 {
                let session = try catalog.create(kind: .classroom, title: "Fictional three-hour history \(index)", parentID: courses[index].id)
                try library.withTransaction {
                    for rowIndex in 0..<1800 {
                        let row = TranscriptRecord(id: UUID().uuidString, classroomID: session.id, epochID: "fixture-epoch-\(index)", startMS: Int64(rowIndex * 6000), endMS: Int64((rowIndex + 1) * 6000), text: "Fictional learning history \(rowIndex). Retrieval practice connects ideas. 中文与日本語の例。", language: "en", revision: 1, confirmedAt: Date(timeIntervalSince1970: Double(rowIndex * 6)))
                        try library.putRecord(collection: "transcripts", id: row.id, ownerID: session.id, value: row)
                    }
                }
            }
        }
        try catalog.link(documentID: note.id, sessionID: classroom.id); try catalog.link(documentID: item.id, sessionID: classroom.id)
        return PerformanceFixture(course: course.id, classroom: classroom.id, note: note.id, pdf: item.id)
    }
    static func draw() { host.layoutSubtreeIfNeeded(); host.displayIfNeeded() }
    static func textViews(_ view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(textViews) }
    static func pdfViews(_ view: NSView) -> [PDFView] { (view as? PDFView).map { [$0] } ?? view.subviews.flatMap(pdfViews) }
    static func scrollViews(_ view: NSView) -> [NSScrollView] { (view as? NSScrollView).map { [$0] + $0.subviews.flatMap(scrollViews) } ?? view.subviews.flatMap(scrollViews) }
    static func capture(_ name: String) throws { draw(); guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }; host.cacheDisplay(in: host.bounds, to: bitmap); try bitmap.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent(name + ".png")) }
    static func navigate(_ id: String) async throws {
        guard let item = model.items.first(where: { $0.id == id }) else { throw DocumentFailure.invalidFormat }
        let begin = now(); model.openItem(item); mark("navigationAction", begin)
        await Task.yield(); let layout = now(); draw(); mark("navigationLayout", layout); mark("navigationFirstFrame", begin)
    }
    static func noteInput(_ count: Int) async throws {
        try await navigate(fixture.note); try await Task.sleep(nanoseconds: 150_000_000)
        let url = try model.workspaceCatalog!.documentURL(id: fixture.note)
        let deadline = now() + 30
        while DocumentEditingSessions.noteEditor(at: url)?.document == nil {
            try require(now() < deadline, "Actual note editor was not mounted"); try await Task.sleep(nanoseconds: 25_000_000); draw()
        }
        guard let editor = DocumentEditingSessions.noteEditor(at: url), let id = editor.document?.blocks.first?.id else { throw DocumentFailure.invalidFormat }
        editor.undo.groupsByEvent = false
        while textViews(host).first(where: { $0.identifier?.rawValue == "block-" + id }) == nil {
            try require(now() < deadline, "Actual NSTextView was not mounted"); try await Task.sleep(nanoseconds: 25_000_000); draw()
        }
        let native = textViews(host).first(where: { $0.identifier?.rawValue == "block-" + id })!
        window.makeFirstResponder(native)
        for index in 0..<count { let begin = now(); editor.undo.beginUndoGrouping(); native.insertText(" \(index)", replacementRange: NSRange(location: (native.string as NSString).length, length: 0)); editor.undo.endUndoGrouping(); draw(); mark("noteInputAndLayout", begin); if index % 10 == 0 { await Task.yield() } }
        let begin = now(); try require(await editor.flush(), "Note flush failed"); mark("noteFlush", begin)
    }
    static func noteScroll() async throws {
        let candidates = scrollViews(host).filter { ($0.documentView?.bounds.height ?? 0) > 4000 && $0.bounds.width > 300 }
        guard let scroll = candidates.first else { throw NSError(domain: "PerformanceChecks", code: 2, userInfo: [NSLocalizedDescriptionKey: "Mounted note scroll view missing"]) }
        for index in 0..<120 {
            let begin = now(), clip = scroll.contentView
            let maximum = max(0, (scroll.documentView?.bounds.height ?? 0) - clip.bounds.height)
            clip.scroll(to: NSPoint(x: 0, y: min(maximum, CGFloat(index) * 120))); scroll.reflectScrolledClipView(clip); draw()
            mark("noteScrollLayout", begin)
            // This is native scroll/layout submission time, not a compositor FPS claim.
            try await Task.sleep(nanoseconds: 16_000_000)
        }
    }
    static func expansionScenarios() async throws {
        model.sidebarVisible = true; try await navigate(fixture.course); draw()
        try await Task.sleep(nanoseconds: 250_000_000)
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: bitmap.cgImage!).perform([request])
        let matches = (request.results ?? []).filter { $0.boundingBox.minX < 0.2 && ($0.topCandidates(1).first?.string ?? "").hasPrefix("Fictional") }
        guard let label = matches.max(by: { $0.boundingBox.midY < $1.boundingBox.midY }) else { throw NSError(domain: "PerformanceChecks", code: 3, userInfo: [NSLocalizedDescriptionKey: "Visible fictional course row missing"]) }
        let point = host.convert(NSPoint(x: 20, y: (host.isFlipped ? 1 - label.boundingBox.midY : label.boundingBox.midY) * host.bounds.height), to: nil)
        let sidebar = scrollViews(host).first { $0.bounds.width >= 200 && $0.bounds.width <= 245 && ($0.documentView?.bounds.height ?? 0) > 1000 }
        let originalHeight = sidebar?.documentView?.bounds.height
        try capture("expand-before")
        for index in 0..<50 {
            let begin = now()
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: now(), windowNumber: window.windowNumber, context: nil, eventNumber: index + 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
                window.sendEvent(event)
            }
            await Task.yield(); draw(); mark("treeExpandFirstFrame", begin)
            try await Task.sleep(nanoseconds: 180_000_000); draw()
            if index == 0 {
                try capture("expand-after")
                try require(originalHeight != nil && sidebar?.documentView?.bounds.height != originalHeight, "Course expansion click did not change native content height")
            }
        }
    }
    static func shortScenarios() async throws {
        checkpoint("short scenarios")
        for _ in 0..<13 {
            for id in [fixture.course, fixture.classroom, fixture.note, fixture.pdf] { try await navigate(id) }
        }
        try await navigate(fixture.classroom)
        for _ in 0..<50 {
            let begin = now(); model.sidebarVisible.toggle(); draw(); mark("sidebarToggle", begin)
            let panel = now(); model.preferences.panel = model.preferences.panel == "transcript" ? "notes" : "transcript"; draw(); mark("panelSwitch", panel)
            await Task.yield()
        }
        try await expansionScenarios()
        model.sidebarVisible = true
        try await noteInput(120)
        try await noteScroll()
        try await navigate(fixture.pdf)
        let deadline = now() + 15
        while pdfViews(host).first?.document?.pageCount != pages { try require(now() < deadline, "PDF failed to open"); try await Task.sleep(nanoseconds: 20_000_000) }
        guard let view = pdfViews(host).first, let document = view.document else { throw DocumentFailure.invalidFormat }
        for i in 0..<80 { let begin = now(); view.go(to: document.page(at: i % pages)!); view.scaleFactor = i % 2 == 0 ? 0.9 : 1.1; draw(); mark("pdfPageAndScale", begin) }
        // Direct production PDF selection path: compare repeated selection while 1000
        // saved annotations stay unchanged. This catches needless full reconstruction.
        if let reader = view as? AnnotationPDFView, let editor = reader.editor, var archive = editor.archive {
            archive.annotations = (0..<(full ? 500 : 1000)).map { index in
                let bounds = CGRect(x: CGFloat(20 + (index % 10) * 40), y: CGFloat(40 + (index % 15) * 35), width: 20, height: 10)
                return StoredPDFAnnotation(kind: .rectangle, page: (index % pages) + 1, bounds: bounds)
            }
            editor.archive = archive; reader.render(archive)
            for i in 0..<50 { editor.selectedID = archive.annotations[i].id; let begin = now(); reader.render(archive); mark("pdfAnnotationSelection", begin) }
            editor.archive?.annotations = []; if let clean = editor.archive { reader.render(clean) }
        }
        try await navigate(fixture.classroom); model.preferences.panel = "transcript"
        try capture("short-rootview")
    }
    static func cloud() async throws -> CloudController {
        let configuration = URLSessionConfiguration.ephemeral; configuration.protocolClasses = [PerformanceHTTP.self]
        let cloud = CloudController(state: CloudState(classID: fixture.classroom), session: URLSession(configuration: configuration), credentials: PerformanceCredentials(), monitorNetwork: false)
        #if PERFORMANCE_CURRENT
        let library = model.library!, classID = fixture.classroom
        cloud.onPersist = { state in let begin = now(); for job in state.jobs where job.status == .retryWaiting { retryWaitingObserved.insert(job.segment.id) }; try await SessionDiskExecutor.shared.run { try library.withTransaction {
            try library.putRecord(collection: "cloud-state", id: classID, ownerID: classID, value: state)
            if var record = try library.classroom(id: classID) { record.translationUserPaused = state.translationUserPaused; try library.saveClassroom(record) }
        } }; mark("translationDurableReceipt", begin) }
        cloud.onSavedTranslation = { value in
            lastTranslation = value.text
            if let row = model.transcriptRows[fixture.classroom]?.first(where: { $0.id == value.segmentID && $0.revision == value.sourceRevision }) {
                captions.updateFragment(CaptionFragment(id: row.id, revision: value.sourceRevision, order: row.startMS, text: value.text, sourceRevision: row.revision), translation: true)
            }
        }
        #else
        cloud.onPersist = { state in let begin = now(); try model.library!.putRecord(collection: "cloud-state", id: fixture.classroom, ownerID: fixture.classroom, value: state); mark("translationDurableReceipt", begin) }
        cloud.onSavedTranslation = { value in lastTranslation = value.text; captions.display(source: lastSource, translation: lastTranslation) }
        #endif
        cloud.objectWillChange.sink { model.objectWillChange.send() }.store(in: &subscriptions)
        model.clouds[fixture.classroom] = cloud
        #if PERFORMANCE_CURRENT
        await cloud.setClassActive(true); try await cloud.saveCredential("fictional-performance-key"); await cloud.setUserPaused(false)
        #else
        cloud.setClassActive(true); try cloud.saveCredential("fictional-performance-key"); cloud.setUserPaused(false)
        #endif
        return cloud
    }
    static func run() async throws {
        guard let output = arg("--output"), let rootPath = arg("--ui-test-workspace"), let project = arg("--project") else { throw DocumentFailure.invalidFormat }
        out = URL(fileURLWithPath: output); try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let root = URL(fileURLWithPath: rootPath)
        let duration = Double(arg("--seconds") ?? "60") ?? 60
        if arg("--mode") == "reopen" {
            let identity = try JSONDecoder().decode(PerformanceIdentity.self, from: Data(contentsOf: out.appendingPathComponent("identity.json")))
            let library = try LibraryStore(rootURL: root.appendingPathComponent("Workspace")); try library.configureTranscriptStorage(rootURL: root.appendingPathComponent("Transcripts"))
            let rows = try library.transcripts(classroomID: identity.classroom), recordings = try library.recordings(classroomID: identity.classroom)
            try require(rows.count == identity.count && (try hash(rows)) == identity.hash && recordings.count == identity.recordings, "Fresh-process count/hash mismatch")
            if let expectedFrames = identity.recordedFrames {
                let frames = try recordings.reduce(Int64(0)) { total, recording in total + (try AVAudioFile(forReading: library.attachmentURL(assetID: recording.assetID))).length }
                try require(frames == expectedFrames, "Fresh-process recording coverage mismatch")
            }
            #if PERFORMANCE_CURRENT
            try require(try textHashes(library, id: identity.classroom) == identity.textHashes, "Reopened TXT pair hash mismatch")
            #endif
            try json(["count": rows.count, "hash": try hash(rows), "recordings": recordings.count, "passed": true], "reopen.json"); return
        }
        checkpoint("prepare fixture")
        let fixtureURL = root.appendingPathComponent("performance-fixture.json")
        if FileManager.default.fileExists(atPath: fixtureURL.path) { fixture = try JSONDecoder().decode(PerformanceFixture.self, from: Data(contentsOf: fixtureURL)) }
        else { fixture = try prepare(root); try JSONEncoder().encode(fixture).write(to: fixtureURL) }
        checkpoint("app initialization")
        AppPreferences.shared.defaults.removePersistentDomain(forName: "local.uway.classroom.internal.uitest")
        let initStart = now(); model = AppModel(); mark("appModelInitialization", initStart)
        try require(model.library != nil && model.isTestMode, "Workspace isolation failed")
        if !CommandLine.arguments.contains("--production-workload") {
            model.workspaceRefreshTask?.cancel(); model.workspaceRefreshTask = nil; model.projectRefreshTask?.cancel(); model.projectRefreshTask = nil
        }
        model.legacyLibraryURL = nil; model.preferences.language = "en"; model.preferences.dark = false; model.preferences.hideSetup = true
        model.classNoteIDs[fixture.classroom] = fixture.note; model.pdfSelection[fixture.classroom] = fixture.pdf
        model.route = "workspace"
        window = NSWindow(contentRect: CGRect(x: 20, y: 20, width: 1280, height: 850), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "ULecture isolated performance replay"; window.isReleasedWhenClosed = false
        host = NSHostingView(rootView: RootView(model: model)); window.contentView = host; window.orderFront(nil); draw(); mark("appModelToFirstDraw", initStart)
        let interaction = now(); model.sidebarVisible.toggle(); draw(); model.sidebarVisible.toggle(); draw(); mark("firstSidebarInteraction", interaction); mark("processEntryToInteractive", processEntry)
        if arg("--mode") == "startup" {
            try json(["metrics": metrics.mapValues(\.json), "dataset": full ? "full" : "smoke", "processLaunch": "fresh process; operating-system filesystem caches not purged"], arg("--startup-output") ?? "startup.json")
            window.close(); window.contentView = nil; host = nil; model = nil; return
        }
        if arg("--mode") == "scroll" {
            model.sidebarVisible = true; try await noteInput(0)
            guard let scroll = scrollViews(host).first(where: { ($0.documentView?.bounds.height ?? 0) > 4000 && $0.bounds.width > 300 }) else { throw DocumentFailure.invalidFormat }
            await PerformanceScrollFrames(scroll: scroll).run()
            try json(["metrics": metrics.mapValues(\.json), "boundary": "Visible native note scrolling on NSWindow CADisplayLink. Frame interval is application display-link/update cadence; physical display presentation is not measured."], "scroll-frames.json")
            try require(await model.prepareForExit(), "Native frame check exit failed"); window.close(); window.contentView = nil; host = nil; model = nil; return
        }
        if arg("--mode") == "pdf" {
            let firstOpen = now(); try await navigate(fixture.pdf)
            let deadline = now() + 30
            while pdfViews(host).first?.document?.pageCount != pages { try require(now() < deadline, "PDF failed to load"); try await Task.sleep(nanoseconds: 5_000_000); draw() }
            draw(); mark("pdfFirstOpenToNativeDocument", firstOpen)
            let reader = pdfViews(host).first as! AnnotationPDFView, document = reader.document!, editor = reader.editor!, archive = editor.archive!
            try require(archive.annotations.count == 500, "Sustained PDF fixture must retain 500 annotations")
            for index in 0..<80 { let begin = now(); reader.go(to: document.page(at: index % pages)!); reader.scaleFactor = index % 2 == 0 ? 0.9 : 1.1; await Task.yield(); draw(); mark("pdfPageScaleFirstFrame", begin) }
            for index in 0..<50 { let begin = now(); editor.selectedID = archive.annotations[index].id; reader.render(archive); await Task.yield(); draw(); mark("pdfSelectionFirstFrame", begin) }
            try json(["metrics": metrics.mapValues(\.json), "pages": pages, "annotations": archive.annotations.count, "fixture": "Synthetic mixed text/vector/raster PDF; loaded-page first frame includes event-loop yield and native host draw."], "pdf-mixed.json")
            try require(await model.prepareForExit(), "Native PDF check exit failed"); window.close(); window.contentView = nil; host = nil; model = nil; return
        }
        captions = SubtitlePanelController(defaults: UserDefaults(suiteName: "local.ulecture.performance-captions")!)
        captions.update { $0.sourceLines = 4; $0.translationLines = 4; $0.alwaysOnTop = false }; captions.show()
        model.objectWillChange.sink { publications += 1 }.store(in: &subscriptions)
        checkpoint("window ready")
        if !CommandLine.arguments.contains("--long-only") { try await shortScenarios(); checkpoint("short scenarios done") }
        guard let fixtureAudio = arg("--audio") else { try json(["metrics": metrics.mapValues(\.json), "boundary": "Native UI and editor benchmark only; no audio supplied"], "short.json"); captions.hide(); window.close(); return }
        try json(["metrics": metrics.mapValues(\.json), "dataset": full ? "full" : "smoke"], "short.json")
        let samples = try AudioPCMConverter.readFile(URL(fileURLWithPath: fixtureAudio)); try require(samples.count >= 16000, "Audio fixture too short")
        let modelURL = URL(fileURLWithPath: project).appendingPathComponent("app/Resources/Models")
        model.models.bundledDirectoryForChecks = modelURL
        if CommandLine.arguments.contains("--production-workload") { let discovery = now(); await model.models.restoreAtLaunch(); mark("offlineResourceDiscovery", discovery) }
        let engineStart = now(); await model.models.prepareBundledOrCached(); try require(model.models.engine != nil, "Local ASR model did not load"); mark("localModelLoad", engineStart)
        #if PERFORMANCE_CURRENT
        await model.drainSessionWork()
        #endif
        let translation = try await cloud()
        let recordingDir = model.recordingDirectory(fixture.classroom)!
        let previousConfirmed = model.audio.onConfirmed, previousGap = model.audio.onGap, previousRecording = model.audio.onRecording
        #if PERFORMANCE_CURRENT
        model.onTranscriptSavedForChecks = { row in if let begin = pendingReceiptTimes.removeValue(forKey: row.id) { mark("transcriptDurableReceipt", begin) } }
        #endif
        model.audio.onConfirmed = { value in
            let row = AudioTranscript(id: value.id, sessionID: fixture.classroom, epochID: value.epochID, language: value.language, text: value.text, sequence: value.sequence, revision: value.revision, start: value.start, end: value.end, confirmedAt: value.confirmedAt)
            confirmed += 1; lastSource = row.text; let begin = now()
            epochs.insert(row.epochID)
            if row.end < (lastConfirmedEndByEpoch[row.epochID] ?? 0) { failures.append("Confirmed timeline moved backwards within epoch") }
            lastConfirmedEndByEpoch[row.epochID] = row.end
            #if PERFORMANCE_CURRENT
            pendingReceiptTimes[row.id] = begin
            #endif
            previousConfirmed?(row); mark("transcriptCallback", begin)
            #if PERFORMANCE_CURRENT
            if let provisionalID = value.replacesProvisionalID { captions.removeFragment(provisionalID) }
            captions.updateFragment(CaptionFragment(id: row.id, revision: row.revision, order: Int64(row.start * 1000), text: row.text))
            #else
            mark("transcriptDurableReceipt", begin)
            captions.display(source: lastSource, translation: lastTranslation)
            #endif
        }
        model.audio.onGap = { value in
            gaps += 1
            let expected = (stoppingForCompletion && value.reason == "performance-replay-finished") || (plannedPauseInProgress && ["performance-planned-pause", "paused-no-audio"].contains(value.reason))
            if !expected { unexpectedGaps += 1; failures.append("Unexpected audio gap: " + value.reason) }
            previousGap?(AudioGap(id: value.id, sessionID: fixture.classroom, epochID: value.epochID, reason: value.reason, start: value.start, end: value.end))
        }
        model.audio.onRecording = { value in recordings += 1; recordedFrames += value.frames; let begin = now(); previousRecording?(AudioRecording(id: value.id, sessionID: fixture.classroom, epochID: value.epochID, filename: value.filename, start: value.start, end: value.end, frames: value.frames, verified: value.verified)); mark("recordingCallback", begin) }
        #if PERFORMANCE_CURRENT
        model.audio.$captionProvisional.dropFirst().sink { value in
            provisional += 1
            if let value { captions.updateFragment(CaptionFragment(id: value.id, revision: value.revision, order: Int64(value.start * 1000), text: value.text, state: .provisional)) }
        }.store(in: &subscriptions)
        #else
        model.audio.$provisional.dropFirst().sink { text in provisional += 1; if !text.isEmpty { captions.display(source: text, translation: lastTranslation) } }.store(in: &subscriptions)
        #endif
        model.activeClassID = fixture.classroom
        if let barrier = arg("--start-barrier") {
            try json(["state": "ready", "utc": ISO8601DateFormatter().string(from: Date()), "pid": Int(getpid())], "ready.json")
            while !FileManager.default.fileExists(atPath: barrier) { try await Task.sleep(nanoseconds: 50_000_000) }
        }
        let callback = try await model.audio.beginSilentReplayForCheck(samples: [], recordingDirectory: recordingDir)
        let trace = out.appendingPathComponent("samples.csv"); FileManager.default.createFile(atPath: trace.path, contents: Data("wallSeconds,cpuSeconds,rssBytes,confirmed,translations,recordings,provisional,mainPublications,audioFrames,gaps\n".utf8)); csv = try FileHandle(forWritingTo: trace); try csv.seekToEnd()
        started = now(); let cpuStart = cpu(); var nextUI = started + 5, nextPoint = started, phase = 0
        let pauseInterval = duration < 600 ? 20.0 : 900.0, faultInterval = duration < 600 ? 15.0 : 1800.0
        var nextPause = started + pauseInterval, nextFault = started + faultInterval
        try json(["utc": ISO8601DateFormatter().string(from: Date()), "uptime": started, "requestedSeconds": duration, "pid": Int(getpid()), "productionWorkload": CommandLine.arguments.contains("--production-workload")], "started.json")
        let feeder = PerformanceAudioFeeder(); feeder.start(samples: samples, receive: callback)
        let heartbeat = Task { var next = now() + 0.016; while !Task.isCancelled { let delay = next - now(); if delay > 0 { try? await Task.sleep(nanoseconds: UInt64(delay * 1e9)) }; if Task.isCancelled { return }; metrics["mainHeartbeatDelay", default: Metric()].add(max(0, now() - next)); next = now() + 0.016 } }
        print("REPLAY_STARTED seconds=\(duration) pid=\(getpid())"); fflush(stdout)
        while now() - started < duration {
            if FileManager.default.fileExists(atPath: out.appendingPathComponent("stop-request").path) {
                failures.append("External stop requested; retain evidence and drain; run is incomplete")
                break
            }
            let time = now()
            sampleFrames = feeder.snapshot().frames
            if model.audio.phase != .capturing || unexpectedGaps > 0 {
                failures.append("Unexpected capture stop/gap: phase=\(model.audio.phase.rawValue), status=\(model.audio.status), gaps=\(gaps)")
                break
            }
            if time - started > 35 && Int64(sampleFrames) - recordedFrames > 30 * 16000 {
                failures.append("Recording producer has not covered the last 30 seconds of admitted input")
                break
            }
            #if PERFORMANCE_CURRENT
            if time >= nextPause && time + 8 < started + duration {
                let pauseBegin = now(), beforeFrames = feeder.snapshot().frames, oldEpoch = model.audio.epochID, oldOffset = model.audio.currentOffset
                plannedPauseInProgress = true
                await feeder.stop(); await model.audio.captureBarrierForChecks()
                await model.audio.pause(reason: "performance-planned-pause"); await model.drainSessionWork()
                try require(model.audio.phase == .paused && !model.audio.draining && !model.hasUnsavedFacts, "Planned pause did not drain durable facts")
                try require(recordedFrames == Int64(feeder.snapshot().frames), "Planned pause recording frame coverage mismatch")
                try await Task.sleep(nanoseconds: 2_000_000_000)
                let resumeOffset = model.audio.currentOffset
                let resumed = try await model.audio.beginSilentReplayForCheck(samples: [], recordingDirectory: recordingDir)
                await translation.setClassActive(true); await model.drainSessionWork()
                try require(model.audio.epochID != oldEpoch && model.audio.phase == .capturing && resumeOffset >= oldOffset, "Resume did not preserve timeline/new epoch")
                feeder.start(samples: samples, receive: resumed)
                let pauseSeconds = now() - pauseBegin; plannedPausedSeconds += pauseSeconds
                pauseEvents.append(["wallSeconds": pauseBegin - started, "durationSeconds": pauseSeconds, "beforeFrames": beforeFrames, "resumedFrames": feeder.snapshot().frames, "oldEpoch": oldEpoch, "newEpoch": model.audio.epochID, "oldOffset": oldOffset, "resumeOffset": resumeOffset])
                plannedPauseInProgress = false; nextPause += pauseInterval
                try json(["events": pauseEvents, "plannedPausedSeconds": plannedPausedSeconds], "pause-resume.json")
            }
            if time >= nextFault && time + 8 < started + duration { PerformanceHTTP.armFailure(); nextFault += faultInterval }
            #endif
            if time >= nextUI {
                phase += 1
                if phase % 12 == 0 { try await noteInput(5) }
                else if phase % 3 == 0 { try await navigate(fixture.pdf); if let view = pdfViews(host).first, let doc = view.document { let begin = now(); view.go(to: doc.page(at: phase % doc.pageCount)!); draw(); mark("pdfDuringReplay", begin) } }
                else { try await navigate(phase % 2 == 0 ? fixture.classroom : fixture.course) }
                nextUI = now() + 5
            }
            if time >= nextPoint {
                let wall = now() - started, completed = translation.state.jobs.filter { $0.status == .completed }.count
                try csv.write(contentsOf: Data("\(wall),\(cpu() - cpuStart),\(rss()),\(confirmed),\(completed),\(recordings),\(provisional),\(publications),\(sampleFrames),\(gaps)\n".utf8))
                try csv.synchronize()
                try json(["state": "running", "wallSeconds": wall, "requiredSeconds": duration, "rssBytes": rss(), "confirmed": confirmed, "recordings": recordings, "recordedFrames": recordedFrames, "inputFrames": sampleFrames, "capturePhase": model.audio.phase.rawValue, "plannedPausedSeconds": plannedPausedSeconds, "pauseResumeCount": pauseEvents.count, "pendingSourceReceipts": pendingReceiptTimes.count, "queuedSessionOperations": queuedSessionOperations, "httpFaults": PerformanceHTTP.faultSnapshot(), "failures": Array(failures.suffix(20)), "metrics": metrics.mapValues(\.json)], "progress.json")
                nextPoint = time + 10
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        await feeder.stop(); sampleFrames = feeder.snapshot().frames
        if feeder.snapshot().late > 0 { failures.append("Synthetic device clock delayed over 500ms") }
        stoppingForCompletion = true
        await model.audio.pause(reason: "performance-replay-finished")
        #if PERFORMANCE_CURRENT
        await model.drainSessionWork()
        #endif
        let cloudDeadline = now() + 30
        while translation.state.jobs.contains(where: { $0.status != .completed && $0.status != .obsolete }) && now() < cloudDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        #if PERFORMANCE_CURRENT
        await model.drainSessionWork(); await translation.setUserPaused(true); await translation.setClassActive(false)
        #else
        translation.setUserPaused(true); translation.setClassActive(false)
        #endif
        heartbeat.cancel(); try csv.close()
        try require(await DocumentEditingSessions.flushAll(), "Final document flush failed")
        let rows = try model.library!.transcripts(classroomID: fixture.classroom), savedRecordings = try model.library!.recordings(classroomID: fixture.classroom)
        let diskFrames = try savedRecordings.reduce(Int64(0)) { total, recording in total + (try AVAudioFile(forReading: model.library!.attachmentURL(assetID: recording.assetID))).length }
        try json(["inputFrames": sampleFrames, "recordingCallbackFrames": recordedFrames, "savedAudioFrames": diskFrames, "capturedWallSeconds": now() - started, "requestedSeconds": duration, "phaseAfterDrain": model.audio.phase.rawValue, "statusAfterDrain": model.audio.status, "gaps": gaps, "expectedPauseResumeCount": pauseEvents.count, "plannedPausedSeconds": plannedPausedSeconds, "effectiveAudioSeconds": Double(sampleFrames) / 16000, "failures": failures], "capture-coverage.json")
        try require(recordedFrames == Int64(sampleFrames) && diskFrames == recordedFrames && now() - started >= duration && unexpectedGaps == 0, "Sustained capture/recording coverage did not match input or stopped early")
        #if PERFORMANCE_CURRENT
        let faultSnapshot = PerformanceHTTP.faultSnapshot(), failedIDs = faultSnapshot["failedSegmentIDs"] as! [String], recoveredIDs = faultSnapshot["retriedSuccessfully"] as! [String]
        try json(["http": faultSnapshot, "retryWaitingObserved": Array(retryWaitingObserved).sorted(), "epochs": Array(epochs).sorted(), "pauseResumeCount": pauseEvents.count], "recovery-events.json")
        try require(!pauseEvents.isEmpty && epochs.count > 1, "Periodic pause/resume did not execute")
        try require(!failedIDs.isEmpty && Set(failedIDs).isSubset(of: Set(recoveredIDs)) && Set(failedIDs).isSubset(of: retryWaitingObserved), "Recoverable HTTP503 did not traverse retry and complete")
        try require(Double(sampleFrames) / 16000 >= duration - plannedPausedSeconds - 2, "Effective capture duration excludes unexplained empty wall-clock time")
        #endif
        try require(confirmed > 0 && rows.count == confirmed && savedRecordings.count == recordings, "ASR/recording count mismatch or no confirmed speech")
        try require(!model.hasUnsavedFacts && failures.isEmpty, "Replay reported failure or unsaved data")
        try require(translation.state.jobs.filter { $0.status == .completed }.count == confirmed, "Mock translations did not complete")
        model.endClass(fixture.classroom)
        let endDeadline = now() + 30
        while model.busy && now() < endDeadline { try await Task.sleep(nanoseconds: 20_000_000) }
        try require(model.classRecords[fixture.classroom]?.state == "ended" && !model.hasUnsavedFacts, "Normal classroom end did not commit")
        var identity = PerformanceIdentity(classroom: fixture.classroom, count: rows.count, hash: try hash(rows), recordings: savedRecordings.count, seconds: now() - started)
        identity.recordedFrames = recordedFrames
        #if PERFORMANCE_CURRENT
        identity.textHashes = try textHashes(model.library!, id: fixture.classroom)
        #endif
        try JSONEncoder().encode(identity).write(to: out.appendingPathComponent("identity.json"))
        try await navigate(fixture.classroom); model.preferences.panel = "transcript"; draw(); try capture("final-rootview")
        try json(["passed": true, "wallSeconds": now() - started, "requestedSeconds": duration, "audioTimelineSeconds": Double(sampleFrames) / 16000, "plannedPausedSeconds": plannedPausedSeconds, "pauseResumeCount": pauseEvents.count, "httpFaults": PerformanceHTTP.faultSnapshot(), "metrics": metrics.mapValues(\.json), "confirmed": confirmed, "recordings": recordings, "gaps": gaps, "transcriptHash": identity.hash, "rssBytes": rss(), "cpuSeconds": cpu() - cpuStart, "fakeProviderRequests": PerformanceHTTP.count, "realProviderRequests": 0, "physicalCapture": false, "boundary": "Wall-clock paced fictional file PCM, production local whisper ASR/VAD/recording/session persistence, URLProtocol translation, visible process-owned native RootView/editor actions. Not microphone, hardware system audio or real provider acceptance."], "results.json")
        captions.hide()
        try require(await model.prepareForExit(), "Production prepareForExit did not finish")
        window.close(); window.contentView = nil; host = nil; subscriptions.removeAll(); model = nil
        await Task.yield()
        print("PASS: wall-clock \(identity.seconds)s, \(confirmed) confirmed ASR rows, \(recordings) recordings, fresh-process reopen required")
    }
}
