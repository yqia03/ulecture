import AppKit
import SwiftUI
import AVFoundation
import Combine
import Vision

@main @MainActor enum TranscriptObservationChecks {
    static func arg(_ name: String) -> String? { CommandLine.arguments.firstIndex(of: name).flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil } }
    static func require(_ value: Bool, _ text: String) throws { if !value { throw NSError(domain: "ObservationCheck", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) } }
    static func nativeViews(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(nativeViews) }
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { do { try await run(); exit(0) } catch { print("FAIL: \(error.localizedDescription)"); exit(1) } }; NSApplication.shared.run()
    }
    static func capture(_ host: NSView, output: URL) throws -> (Data, [String]) {
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds)!
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = bitmap.representation(using: .png, properties: [:])!; try data.write(to: output)
        let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(cgImage: bitmap.cgImage!).perform([request])
        return (data, request.results?.compactMap { $0.topCandidates(1).first?.string } ?? [])
    }
    static func fixture(_ root: URL) throws -> WorkspaceItem {
        let library = try LibraryStore(rootURL: root.appendingPathComponent("Workspace")), catalog = WorkspaceCatalog(library: library)
        try library.configureTranscriptStorage(rootURL: root.appendingPathComponent("Transcripts"))
        let course = try catalog.createCourse(title: "Fictional observation fixture")
        return try catalog.create(kind: .classroom, title: "Mounted transcript observation", parentID: course.id)
    }
    static func run() async throws {
        let root = URL(fileURLWithPath: arg("--ui-test-workspace")!), output = URL(fileURLWithPath: arg("--observation-output")!)
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let session = try fixture(root)
        let model = AppModel(); model.workspaceRefreshTask?.cancel(); model.workspaceRefreshTask = nil
        model.preferences.language = "en"; model.preferences.dark = false; model.activeClassID = session.id
        try require(model.library?.isReadOnly == false, "Observation fixture must release its writer lease before AppModel opens")
        model.openItem(model.items.first { $0.id == session.id }!)
        let pane = TranscriptPane(classID: session.id, audio: model.audio).environmentObject(model).environmentObject(model.preferences).frame(width: 850, height: 720).background(Color.white).preferredColorScheme(.light)
        let host = NSHostingView(rootView: pane), window = NSWindow(contentRect: CGRect(x: 40, y: 40, width: 850, height: 720), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "ULecture mounted transcript observation"; window.isReleasedWhenClosed = false; window.contentView = host; window.makeKeyAndOrderFront(nil)
        let tap = try await model.audio.beginSyntheticCapture(sessionID: session.id, recordingDirectory: nil, onFrame: { _ in true })
        await model.drainSessionWork(); try await Task.sleep(nanoseconds: 250_000_000)
        // Expand the actual native disclosure action so the production meter is
        // rendered. No private SwiftUI state is changed by this check.
        let closed = try capture(host, output: output.appendingPathComponent("closed.png"))
        let recognize = VNRecognizeTextRequest(); recognize.recognitionLevel = .accurate; recognize.recognitionLanguages = ["en-US"]
        try VNImageRequestHandler(data: closed.0).perform([recognize])
        guard let label = recognize.results?.first(where: { $0.topCandidates(1).first?.string.contains("Audio source") == true }) else {
            throw NSError(domain: "ObservationCheck", code: 2, userInfo: [NSLocalizedDescriptionKey: "Native audio disclosure label not found: " + closed.1.joined(separator: ", ")])
        }
        let box = label.boundingBox
        let point = CGPoint(x: box.minX * host.bounds.width + 4,
                            y: (host.isFlipped ? 1 - box.midY : box.midY) * host.bounds.height)
        let location = host.convert(point, to: nil)
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: location, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: type == .leftMouseDown ? 1 : 0)!
            window.sendEvent(event)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        let before = try capture(host, output: output.appendingPathComponent("before.png"))
        try require(before.1.contains { $0.contains("Microphone") }, "Native disclosure click did not expand audio controls: " + before.1.joined(separator: ", "))
        let initialLevel = model.audio.level
        var publications = 0, audioPublications = 0, levelValues: [Double] = []
        let observation = model.objectWillChange.sink { publications += 1 }
        let audioObservation = model.audio.objectWillChange.sink { audioPublications += 1 }
        let levelObservation = model.audio.$level.sink { levelValues.append($0) }
        model.audio.setProvisionalForUIObservationChecks("Draft observation alpha")
        try await Task.sleep(nanoseconds: 150_000_000)
        let draft = try capture(host, output: output.appendingPathComponent("draft.png"))
        try require(draft.1.contains { $0.contains("Draft observation alpha") }, "Native pane did not render draft without a confirmed transcript")
        model.audio.setProvisionalForUIObservationChecks("Revised observation beta")
        try await Task.sleep(nanoseconds: 150_000_000)
        let revised = try capture(host, output: output.appendingPathComponent("revised.png"))
        try require(revised.1.contains { $0.contains("Revised observation beta") } && !revised.1.contains { $0.contains("Draft observation alpha") }, "Native pane did not replace live draft")
        let pcm = AVAudioPCMBuffer(pcmFormat: AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!, frameCapacity: 1600)!
        pcm.frameLength = 1600
        for i in 0..<1600 { pcm.floatChannelData![0][i] = 0.25 }
        tap(pcm); await model.audio.captureBarrierForChecks(); try await Task.sleep(nanoseconds: 500_000_000)
        let meter = try capture(host, output: output.appendingPathComponent("meter.png"))
        let finalLevel = model.audio.level
        let nativeProgress = nativeViews(host).compactMap { $0 as? NSProgressIndicator }.map { $0.doubleValue }
        try nativeViews(host).map { String(describing: type(of: $0)) }.joined(separator: "\n").write(to: output.appendingPathComponent("native-view-tree.txt"), atomically: true, encoding: .utf8)
        try JSONSerialization.data(withJSONObject: ["initialLevel": initialLevel, "finalLevel": finalLevel, "revisedText": revised.1, "meterText": meter.1, "AppModelPublications": publications, "audioPublications": audioPublications, "levelValues": levelValues, "nativeProgress": nativeProgress, "captureStatus": model.audio.status], options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("meter-observation.json"))
        try require(finalLevel > -20 && revised.0 != meter.0 && revised.1 == meter.1, "Production meter pixels did not update independently from captured PCM")
        model.audio.setProvisionalForUIObservationChecks(""); try await Task.sleep(nanoseconds: 150_000_000)
        let cleared = try capture(host, output: output.appendingPathComponent("cleared.png"))
        try require(!cleared.1.contains { $0.contains("observation beta") }, "Clearing draft left stale native text")
        try require(publications == 0, "Mounted pane depended on AppModel global refresh")
        observation.cancel(); audioObservation.cancel(); levelObservation.cancel()
        try require(await model.prepareForExit(), "Observation fixture failed to drain")
        window.close()
        let report: [String: Any] = ["passed": ["Native disclosure opens audio controls", "Draft appears without confirmation", "Draft revision replaces prior text", "Production PCM meter pixels change while text stays identical", "Draft clear removes stale text", "Zero AppModel publications during updates"], "AppModelPublications": publications, "initialLevel": initialLevel, "finalLevel": finalLevel, "confirmedTranscripts": 0, "actualHardware": false, "actualASR": false, "source": "Mounted production TranscriptPane, AUDIO_TESTING draft seam, native CaptureSink PCM callback; Vision OCR and pixel comparison of actual view frames; native disclosure clicked at OCR-observed label position"]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("results.json"))
        print("PASS: mounted native transcript draft/revision/clear and PCM meter update without AppModel publication")
    }
}
