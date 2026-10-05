import AppKit
import SwiftUI

private final class FlippedDocument: NSView { override var isFlipped: Bool { true } }

@main struct WorkspaceDragScrollChecks {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        _ = NSApplication.shared
        var checks = [String]()
        for flipped in [false, true] {
            let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 220, height: 320))
            let document = flipped ? FlippedDocument(frame: NSRect(x: 0, y: 0, width: 220, height: 4000)) : NSView(frame: NSRect(x: 0, y: 0, width: 220, height: 4000))
            scroll.documentView = document
            let scroller = WorkspaceDragScroller(); scroller.scrollView = scroll
            let clip = scroll.contentView
            clip.scroll(to: NSPoint(x: 0, y: 1200))
            let before = clip.bounds.origin.y
            scroller.scroll(at: NSPoint(x: clip.bounds.midX, y: clip.bounds.midY))
            precondition(clip.bounds.origin.y == before)
            checks.append("center preserves native offset, flipped=\(flipped)")
            let top = { NSPoint(x: clip.bounds.midX, y: clip.isFlipped ? clip.bounds.minY + 1 : clip.bounds.maxY - 1) }
            for _ in 0..<10 { scroller.scroll(at: top()) }
            precondition(flipped ? clip.bounds.origin.y < before : clip.bounds.origin.y > before)
            checks.append("top edge scrolls actual native document upward, flipped=\(flipped)")
            for _ in 0..<400 { scroller.scroll(at: top()) }
            let topOffset = clip.bounds.origin.y
            scroller.scroll(at: top())
            precondition(clip.bounds.origin.y == topOffset)
            checks.append("top bound clamps without overscroll, flipped=\(flipped)")
            let bottom = { NSPoint(x: clip.bounds.midX, y: clip.isFlipped ? clip.bounds.maxY - 1 : clip.bounds.minY + 1) }
            for _ in 0..<400 { scroller.scroll(at: bottom()) }
            precondition(flipped ? clip.bounds.origin.y > topOffset : clip.bounds.origin.y < topOffset)
            let bottomOffset = clip.bounds.origin.y
            scroller.scroll(at: bottom())
            precondition(clip.bounds.origin.y == bottomOffset)
            checks.append("bottom edge reaches and clamps opposite bound, flipped=\(flipped)")
            scroller.scroll(at: NSPoint(x: clip.bounds.maxX + 1, y: clip.bounds.minY + 1))
            precondition(clip.bounds.origin.y == bottomOffset)
            checks.append("pointer outside viewport does not scroll, flipped=\(flipped)")
        }
        let connected = WorkspaceDragScroller()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 220, height: 320), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = NSHostingView(rootView: ScrollView {
            VStack { ForEach(0..<100) { Text("Row \($0)").frame(height: 34) } }
                .background(WorkspaceScrollAttachment(scroller: connected).frame(width: 0, height: 0))
        })
        window.contentView?.layoutSubtreeIfNeeded()
        let deadline = Date().addingTimeInterval(2)
        while connected.scrollView == nil && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
        precondition(connected.scrollView != nil, "SwiftUI sidebar attachment must resolve the real enclosing NSScrollView")
        checks.append("production SwiftUI attachment resolves native enclosing scroll view")
        let data = try JSONSerialization.data(withJSONObject: ["passed": checks.count, "checks": checks, "scope": "Real AppKit scroll view and SwiftUI attachment, without desktop pointer or synthetic input; native user drag still needs foreground validation"], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("results.json")); print(String(decoding: data, as: UTF8.self))
    }
}
