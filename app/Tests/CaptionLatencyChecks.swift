import AppKit
import Foundation

/// Measures production CoreText layout and the ensuing native AppKit draw in a
/// process-owned visible window. This is presentation latency after a text event,
/// not microphone/cloud/ASR latency or a physical-display photon measurement.
@main @MainActor enum CaptionLatencyChecks {
    final class Sample {
        let count: Int
        var layoutMS: [Double] = [], eventToDrawMS: [Double] = []
        var pending: (index: Int, start: Double)?
        var events: [[String: Any]] = []
        init(_ count: Int) { self.count = count }
    }
    static func main() {
        NSApplication.shared.setActivationPolicy(.accessory)
        Task { do { try await run(); exit(0) } catch { print("FAIL: \(error.localizedDescription)"); exit(1) } }
        NSApplication.shared.run()
    }
    static func percentile(_ values: [Double], _ fraction: Double) -> Double {
        let sorted = values.sorted(); return sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(ceil(Double(sorted.count) * fraction)) - 1)]
    }
    static func run() async throws {
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: CGRect(x: 40, y: 80, width: 1200, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "ULecture native caption timing · synthetic text"
        let surface = NSView(frame: CGRect(x: 0, y: 0, width: 1200, height: 700)); surface.wantsLayer = true; surface.layer?.backgroundColor = NSColor.black.cgColor
        var views: [CaptionLinesView] = [], buffers: [CaptionTrackBuffer] = [], samples: [Sample] = []
        let phrases = ["Learning connects classroom materials, understanding and lasting notes. ", "课堂资料、听课理解与学习记录连接起来。长句按真实窗口宽度自然换行。", "授業の資料を読みながら、大切な内容を理解してノートに残します。", "Unicode 👩🏽‍💻 e\u{301} 中文、日本語 — punctuation: (read, understand, remember). "]
        for (index, count) in [1, 2, 4, 8].enumerated() {
            let view = CaptionLinesView(frame: CGRect(x: 24 + (index % 2) * 600, y: 24 + (index / 2) * 340, width: 552, height: 300))
            surface.addSubview(view); views.append(view)
            let sample = Sample(count); samples.append(sample)
            view.onMeasuredLayout = { duration in if sample.pending != nil { sample.layoutMS.append(duration) } }
            view.onNativeDraw = { [weak view] in
                guard let event = sample.pending, let view else { return }
                let elapsed = (ProcessInfo.processInfo.systemUptime - event.start) * 1000
                sample.eventToDrawMS.append(elapsed)
                sample.events.append(["event": event.index, "eventToNativeDrawMS": elapsed, "visibleRows": view.visibleLines.map(\.identity), "cachedLines": view.visualLines.count])
                sample.pending = nil
            }
            var buffer = CaptionTrackBuffer()
            for id in 0..<256 { buffer.upsert(CaptionFragment(id: "warm-\(id)", revision: 1, order: Int64(id), text: String(repeating: phrases[id % 4], count: 3))) }
            buffers.append(buffer); view.configure(buffer: buffer, fontSize: 24, count: count, color: .white, opacity: 1)
        }
        window.contentView = surface; window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps: true)
        try await Task.sleep(nanoseconds: 500_000_000)
        let start = ProcessInfo.processInfo.systemUptime
        for event in 0..<80 {
            // Four independent caption tracks receive the same logical event in
            // one main-actor turn; odd events revise the preceding provisional.
            for index in views.indices {
                let sample = samples[index]
                sample.pending = (event, ProcessInfo.processInfo.systemUptime)
                let phrase = phrases[(event / 2 + index) % phrases.count]
                buffers[index].upsert(CaptionFragment(id: "event-\(event / 2)", revision: event % 2 + 1, order: 1000 + Int64(event / 2), text: String(repeating: phrase, count: event % 2 == 0 ? 2 : 3), state: event % 2 == 0 ? .provisional : .confirmed))
                views[index].configure(buffer: buffers[index], fontSize: 24, count: sample.count, color: .white, opacity: 1)
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 1
            while samples.contains(where: { $0.pending != nil }), ProcessInfo.processInfo.systemUptime < deadline { try await Task.sleep(nanoseconds: 2_000_000) }
            if samples.contains(where: { $0.pending != nil }) { throw NSError(domain: "CaptionTiming", code: 1, userInfo: [NSLocalizedDescriptionKey: "Native window did not draw an admitted event"]) }
            try await Task.sleep(nanoseconds: 30_000_000)
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - start
        let rows: [[String: Any]] = samples.map { sample in
            ["visualLineCount": sample.count, "events": sample.events, "samples": sample.eventToDrawMS.count,
             "eventToNativeDrawP95MS": percentile(sample.eventToDrawMS, 0.95), "eventToNativeDrawMaxMS": (sample.eventToDrawMS.max() ?? 0) as Double,
             "layoutSamples": sample.layoutMS.count, "mainThreadLayoutP95MS": percentile(sample.layoutMS, 0.95), "mainThreadLayoutMaxMS": (sample.layoutMS.max() ?? 0) as Double,
             "budgetPassed": percentile(sample.eventToDrawMS, 0.95) <= 100 && percentile(sample.layoutMS, 0.95) <= 8]
        }
        let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds)!
        surface.cacheDisplay(in: surface.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: out.appendingPathComponent("native-final.png"))
        let passed = rows.allSatisfy { $0["budgetPassed"] as? Bool == true }
        let report: [String: Any] = ["passed": passed, "regions": rows, "wallSeconds": elapsed,
            "concurrentWork": ProcessInfo.processInfo.environment["CAPTION_MEASUREMENT_CONTEXT"] ?? "Not recorded", "system": ProcessInfo.processInfo.operatingSystemVersionString, "cpuCount": ProcessInfo.processInfo.processorCount, "physicalMemoryBytes": ProcessInfo.processInfo.physicalMemory,
            "provenance": "Production CaptionLinesView in a visible native NSWindow; exact relayout and actual CTLineDraw instrumentation compiled only with CAPTION_TESTING. 80 events per independent 1/2/4/8-row region, prewarmed bounded 256-fragment tail; alternating provisional/final revisions; native run-loop rendering, no forced display in timing loop. Excludes ASR/network and physical screen latency.",
            "budget": ["eventToNativeDrawP95MS": 100, "mainThreadLayoutP95MS": 8]]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("results.json"))
        window.close()
        if !passed { throw NSError(domain: "CaptionTiming", code: 2, userInfo: [NSLocalizedDescriptionKey: "Caption presentation budget exceeded; inspect measured results"]) }
        print("PASS: 320 native caption events meet presentation and main-thread layout p95 budgets")
    }
}
