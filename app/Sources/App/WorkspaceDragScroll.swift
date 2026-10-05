import AppKit
import SwiftUI

/// Keeps the real sidebar scroll view moving while a drag rests near its edge.
/// Native drag updates stop when the pointer is stationary, so the timer owns
/// only scrolling; the existing row delegate still owns the eventual move.
@MainActor final class WorkspaceDragScroller: ObservableObject {
    weak var scrollView: NSScrollView?
    private var timer: Timer?

    func update() {
        stepAtPointer()
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 0.06, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard NSEvent.pressedMouseButtons & 1 != 0 else { self?.stop(); return }
                self?.stepAtPointer()
            }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    func stop() { timer?.invalidate(); timer = nil }

    private func stepAtPointer() {
        guard let scrollView, let window = scrollView.window else { stop(); return }
        let point = scrollView.contentView.convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil)
        scroll(at: point)
    }

    // Internal entry point also allows a native NSScrollView regression without
    // moving the desktop pointer or manufacturing input events.
    func scroll(at point: NSPoint) {
        guard let scrollView, let document = scrollView.documentView else { return }
        let clip = scrollView.contentView, viewport = clip.bounds
        guard viewport.contains(point), viewport.height > 0 else { return }
        let fromTop = clip.isFlipped ? point.y - viewport.minY : viewport.maxY - point.y
        let fromBottom = viewport.height - fromTop
        let edge: CGFloat = min(36, viewport.height / 4)
        let towardTop: Bool
        let proximity: CGFloat
        if fromTop < edge { towardTop = true; proximity = (edge - fromTop) / edge }
        else if fromBottom < edge { towardTop = false; proximity = (edge - fromBottom) / edge }
        else { return }
        let distance = 5 + 19 * proximity
        let direction: CGFloat = towardTop == document.isFlipped ? -1 : 1
        var target = viewport
        target.origin.y += direction * distance
        target = clip.constrainBoundsRect(target)
        clip.scroll(to: target.origin)
        scrollView.reflectScrolledClipView(clip)
    }
}

struct WorkspaceScrollAttachment: NSViewRepresentable {
    let scroller: WorkspaceDragScroller
    func makeNSView(context: Context) -> Attachment {
        let view = Attachment(); view.scroller = scroller; return view
    }
    func updateNSView(_ view: Attachment, context: Context) { view.scroller = scroller; view.attach() }
    static func dismantleNSView(_ view: Attachment, coordinator: ()) { view.scroller?.stop() }

    final class Attachment: NSView {
        weak var scroller: WorkspaceDragScroller?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); attach() }
        override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); attach() }
        func attach() {
            DispatchQueue.main.async { [weak self] in
                guard let self, let scroll = self.enclosingScrollView else { return }
                self.scroller?.scrollView = scroll
            }
        }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}
