import AppKit
import Foundation
import CoreText

@main struct SubtitleRollingChecks {
    struct Failure: Error { let reason: String }
    static func require(_ yes: @autoclosure () -> Bool, _ reason: String) throws { if !yes() { throw Failure(reason: reason) } }
    @MainActor static func main() async throws {
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        let app = NSApplication.shared; app.setActivationPolicy(.accessory)
        var passed: [String] = []
        let view = CaptionLinesView(frame: CGRect(x: 0, y: 0, width: 500, height: 160))
        for count in [1, 2, 4, 8] {
            var buffer = CaptionTrackBuffer()
            view.configure(buffer: buffer, fontSize: 24, count: count, color: .white, opacity: 1)
            for index in 0..<(count + 3) {
                buffer.upsert(CaptionFragment(id: "row-\(index)", revision: 1, order: Int64(index), text: "Line \(index)"))
                view.configure(buffer: buffer, fontSize: 24, count: count, color: .white, opacity: 1)
                try require(view.visibleLines.map(\.fragmentID) == (max(0, index - count + 1)...index).map { "row-\($0)" }, "\(count)-line rolling window lost context")
            }
            passed.append("\(count) visual lines advance one at a time")
        }
        let long = "A long sentence keeps its natural line breaks while the reader follows the lecture. 中文标点：你好，世界！日本語の長い文章も自然に折り返します。 👩🏽‍💻 e\u{301} "
        let font = NSFont.systemFont(ofSize: 24, weight: .medium)
        let fragments = [CaptionFragment(id: "long", revision: 1, order: 1, text: long)]
        let narrow = CaptionLayout.lines(fragments, width: 200, font: font)
        let wide = CaptionLayout.lines(fragments, width: 500, font: font)
        try require(narrow.count > wide.count && wide.count > 1, "visual line count must follow native width")
        try require(narrow.map(\.text).joined() == long, "native wrapping lost Unicode content")
        var buffer = CaptionTrackBuffer()
        buffer.upsert(CaptionFragment(id: "draft", revision: 1, order: 1, text: "Draft one", state: .provisional))
        buffer.upsert(CaptionFragment(id: "draft", revision: 2, order: 1, text: "Draft revised", state: .provisional))
        try require(buffer.fragments.count == 1 && buffer.fragments[0].text == "Draft revised", "stream revision appended instead of replacing")
        buffer.upsert(CaptionFragment(id: "draft", revision: 1, order: 1, text: "stale"))
        try require(buffer.fragments[0].text == "Draft revised", "older revision replaced new text")
        buffer.remove("draft"); buffer.upsert(CaptionFragment(id: "final", revision: 1, order: 1, text: "Confirmed"))
        try require(buffer.fragments.count == 1 && buffer.fragments[0].state == .confirmed, "confirmation duplicated provisional")
        for index in 2..<3000 { buffer.upsert(CaptionFragment(id: "tail-\(index)", revision: 1, order: Int64(index), text: long)) }
        try require(buffer.fragments.count <= 256 && buffer.utf16Count <= 65_536, "caption buffer grew beyond bounds")
        buffer.upsert(CaptionFragment(id: "evicted-late", revision: 2, order: 2, text: "Old content"))
        try require(!buffer.fragments.contains { $0.id == "evicted-late" }, "late update rebroadcast evicted text")
        try require(CaptionLayout.lines(buffer.fragments, width: 100, font: font).count <= 256, "layout cache grew beyond bounds")
        buffer.upsert(CaptionFragment(id: "huge", revision: 1, order: 5000, text: String(repeating: "界👩🏽‍💻", count: 20000)))
        try require(buffer.utf16Count <= 65_536, "huge fragment bypassed UTF16 bound")
        passed += ["long English Chinese Japanese sentences wrap by width", "Unicode preserved", "stream revisions replace in place", "stale revisions rejected", "provisional replacement", "bounded long-session tail and late updates"]
        var revisionBuffer = CaptionTrackBuffer()
        revisionBuffer.upsert(CaptionFragment(id: "past", revision: 1, order: 0, text: "Evicted context"))
        revisionBuffer.upsert(CaptionFragment(id: "current", revision: 1, order: 1, text: String(repeating: long, count: 4), state: .provisional))
        view.configure(buffer: revisionBuffer, fontSize: 24, count: 4, color: .white, opacity: 1)
        revisionBuffer.upsert(CaptionFragment(id: "current", revision: 2, order: 1, text: "Corrected short final"))
        view.configure(buffer: revisionBuffer, fontSize: 24, count: 4, color: .white, opacity: 1)
        try require(view.visibleLines.map(\.text) == ["Corrected short final"], "shortening revision emptied the viewport or replayed evicted context")
        var translated = CaptionTrackBuffer()
        translated.upsert(CaptionFragment(id: "t2", revision: 1, order: 2, text: "Late translation two", sourceRevision: 1))
        translated.upsert(CaptionFragment(id: "t1", revision: 1, order: 1, text: "Late translation one", sourceRevision: 2))
        let translatedView = CaptionLinesView(frame: CGRect(x: 0, y: 0, width: 500, height: 160))
        translatedView.configure(buffer: translated, fontSize: 24, count: 2, color: .white, opacity: 1)
        try require(translatedView.visibleLines.map(\.fragmentID) == ["t1", "t2"] && view.visibleLines.map(\.fragmentID) == ["current"], "late independent translation changed source context")
        translated.reset(); translatedView.configure(buffer: translated, fontSize: 24, count: 2, color: .white, opacity: 1)
        try require(translatedView.visibleLines.isEmpty, "session reset retained old captions")
        translated.upsert(CaptionFragment(id: "late-second", revision: 1, order: 2, text: "Second translation"))
        translatedView.configure(buffer: translated, fontSize: 24, count: 4, color: .white, opacity: 1)
        translated.upsert(CaptionFragment(id: "late-first", revision: 1, order: 1, text: "First translation arrives late"))
        translatedView.configure(buffer: translated, fontSize: 24, count: 4, color: .white, opacity: 1)
        try require(translatedView.visibleLines.map(\.fragmentID) == ["late-first", "late-second"], "late translation failed to fill unused rows before any eviction")
        for i in 3...6 { translated.upsert(CaptionFragment(id: "newer-\(i)", revision: 1, order: Int64(i), text: "Newer \(i)")); translatedView.configure(buffer: translated, fontSize: 24, count: 4, color: .white, opacity: 1) }
        translated.upsert(CaptionFragment(id: "late-first", revision: 2, order: 1, text: "Obsolete revised translation"))
        translatedView.configure(buffer: translated, fontSize: 24, count: 4, color: .white, opacity: 1)
        try require(translatedView.visibleLines.map(\.fragmentID) == (3...6).map { "newer-\($0)" }, "late correction replayed context that really left the viewport")
        passed.append("late translation fills unused rows but never replays evicted context")
        passed += ["shortening revisions keep current context without replay", "independent late translations preserve source track", "session reset clears presentation"]
        var burst = CaptionTrackBuffer()
        view.reduceMotion = { false }
        for i in 0..<4 { burst.upsert(CaptionFragment(id: "burst-old-\(i)", revision: 1, order: Int64(i), text: "Old row \(i)")) }
        view.configure(buffer: burst, fontSize: 24, count: 4, color: .white, opacity: 1)
        burst.upsert(CaptionFragment(id: "burst-new", revision: 1, order: 10, text: (0..<6).map { "New row \($0)" }.joined(separator: "\n")))
        view.configure(buffer: burst, fontSize: 24, count: 4, color: .white, opacity: 1)
        try require((view.presentationEvidence.first?["y"] as? Double ?? 0) <= view.lineHeight * 2, "burst scroll moved past the two outgoing rows and exposed an empty gap")
        passed.append("burst scrolling remains within the painted outgoing-row guard band")
        if CommandLine.arguments.contains("--dynamic") { try await record(out: out, app: app); passed.append("native dynamic frames and visible row identity trace") }
        try JSONSerialization.data(withJSONObject: ["passed": passed, "source": "native CoreText layout and AppKit draw; synthetic text, no audio/network", "hardwareAudio": false], options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("checks.json"))
        print("PASS: \(passed.count) caption rolling/layout behaviors")
    }
    @MainActor static func record(out: URL, app: NSApplication) async throws {
        let frames = out.appendingPathComponent("frames"); try FileManager.default.createDirectory(at: frames, withIntermediateDirectories: true)
        let window = NSWindow(contentRect: CGRect(x: 160, y: 220, width: 960, height: 430), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "ULecture · Visual line scrolling verification"
        let surface = NSView(frame: CGRect(x: 0, y: 0, width: 960, height: 430)); surface.wantsLayer = true; surface.layer?.backgroundColor = NSColor(white: 0.08, alpha: 1).cgColor
        let title = NSTextField(labelWithString: "ULecture  •  4 visual lines / 逐行滚动")
        title.frame = CGRect(x: 32, y: 372, width: 896, height: 32); title.font = .systemFont(ofSize: 24, weight: .semibold); title.textColor = .white; surface.addSubview(title)
        let view = CaptionLinesView(frame: CGRect(x: 32, y: 160, width: 896, height: 188)); surface.addSubview(view)
        let label = NSTextField(labelWithString: "A B C D → B C D E → C D E F  ·  Actual native layout")
        label.frame = CGRect(x: 32, y: 90, width: 896, height: 32); label.font = .systemFont(ofSize: 20); label.textColor = .lightGray; surface.addSubview(label)
        let lateView = CaptionLinesView(frame: CGRect(x: 32, y: 16, width: 896, height: 60)); surface.addSubview(lateView)
        lateView.reduceMotion = { true }
        window.contentView = surface; window.orderFrontRegardless(); app.activate(ignoringOtherApps: true)
        var buffer = CaptionTrackBuffer(), lateBuffer = CaptionTrackBuffer(), trace: [[String: Any]] = []
        for index in 0..<480 {
            view.reduceMotion = { (180..<240).contains(index) }
            if index < 300 && index % 30 == 0 {
                let n = index / 30
                buffer.upsert(CaptionFragment(id: "line-\(n)", revision: 1, order: Int64(n), text: "\(String(UnicodeScalar(65 + n)!))  Connect classroom materials, understanding and notes."))
                view.configure(buffer: buffer, fontSize: 28, count: 4, color: .white, opacity: 1)
            }
            if index == 300 {
                label.stringValue = "Long text / 长句折行 / 長い文章  ·  Revision in place"
                buffer.upsert(CaptionFragment(id: "long-stream", revision: 1, order: 100, text: String(repeating: "课堂资料、听课理解与学习记录连接起来。", count: 6), state: .provisional))
                view.configure(buffer: buffer, fontSize: 28, count: 4, color: .white, opacity: 1)
            }
            if index == 330 {
                buffer.upsert(CaptionFragment(id: "long-stream", revision: 2, order: 100, text: String(repeating: "课堂资料、听课理解与学习记录连接起来。", count: 6) + "现在原位修订，保持阅读上下文。👩🏽‍💻", state: .confirmed))
                view.configure(buffer: buffer, fontSize: 28, count: 4, color: .white, opacity: 1)
            }
            if index == 360 {
                buffer.upsert(CaptionFragment(id: "japanese", revision: 1, order: 101, text: "授業の資料を読みながら、大切な内容を理解してノートに残します。長い文章は画面の幅に合わせて自然に折り返します。"))
                view.configure(buffer: buffer, fontSize: 28, count: 4, color: .white, opacity: 1)
            }
            if index == 300 { lateBuffer.upsert(CaptionFragment(id: "late-second", revision: 1, order: 2, text: "第二句译文先到达，原文区域独立更新。")) }
            if index == 315 { lateBuffer.upsert(CaptionFragment(id: "late-first", revision: 1, order: 1, text: "第一句译文迟到，补入仍然空闲的视觉行。")) }
            if index == 360 { lateBuffer.upsert(CaptionFragment(id: "late-third", revision: 1, order: 3, text: "第三句译文继续滚动，每次只淘汰一行。")) }
            if index == 375 { lateBuffer.upsert(CaptionFragment(id: "late-first", revision: 2, order: 1, text: "已经离开的旧句修订不会重新播放。")) }
            if [300, 315, 360, 375].contains(index) { lateView.configure(buffer: lateBuffer, fontSize: 18, count: 2, color: .white, opacity: 1) }
            if index == 390 { view.setFrameSize(CGSize(width: 600, height: 188)); view.layoutSubtreeIfNeeded(); label.stringValue = "Resize → native visual reflow / 窗口变化自然重排" }
            if index == 420 { view.configure(buffer: buffer, fontSize: 32, count: 2, color: .white, opacity: 1); title.stringValue = "ULecture  •  2 visual lines / 两行" }
            if index == 450 { view.setFrameSize(CGSize(width: 600, height: 200)); view.configure(buffer: buffer, fontSize: 18, count: 8, color: .white, opacity: 1); title.stringValue = "ULecture  •  8 visual lines / 八行" }
            try await Task.sleep(nanoseconds: 33_333_333)
            window.displayIfNeeded(); surface.layoutSubtreeIfNeeded(); view.displayIfNeeded()
            guard let bitmap = surface.bitmapImageRepForCachingDisplay(in: surface.bounds) else { throw Failure(reason: "native bitmap capture failed") }
            surface.cacheDisplay(in: surface.bounds, to: bitmap)
            guard let png = bitmap.representation(using: .png, properties: [:]) else { throw Failure(reason: "PNG encoding failed") }
            try png.write(to: frames.appendingPathComponent(String(format: "%05d.png", index)))
            trace.append(["frame": index, "seconds": Double(index) / 30, "reduceMotion": view.reduceMotion(), "visible": view.presentationEvidence, "translationVisible": lateView.presentationEvidence])
        }
        window.close()
        let animated = trace.filter { ($0["frame"] as? Int ?? 0) >= 120 && ($0["frame"] as? Int ?? 0) < 180 }.contains { row in
            guard let first = (row["visible"] as? [[String: Any]])?.first, let y = first["y"] as? Double else { return false }; return y > 0.01
        }
        try require(animated, "captured frames never observed a native scrolling transition")
        let reduced = trace.filter { $0["reduceMotion"] as? Bool == true }
        try require(reduced.allSatisfy { row in ((row["visible"] as? [[String: Any]])?.first?["y"] as? Double ?? 0) == 0 }, "Reduce Motion still moved caption rows")
        let filled = (trace[315]["translationVisible"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        let advanced = (trace[375]["translationVisible"] as? [[String: Any]] ?? []).compactMap { $0["id"] as? String }
        try require(filled == ["late-first:0", "late-second:0"] && advanced == ["late-second:0", "late-third:0"], "native dynamic late-translation viewport did not preserve independent readable context")
        try JSONSerialization.data(withJSONObject: trace, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("dynamic-lines.json"))
    }
}
