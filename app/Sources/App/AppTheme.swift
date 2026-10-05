import SwiftUI
import AppKit

/// Deliberately close neutral surfaces, matching the supplied desktop reference.
/// System underPageBackgroundColor is a scroll-gutter gray, not a sidebar surface.
struct AppPalette {
    let dark: Bool
    var canvas: Color { Color(white: dark ? 0.105 : 1) }
    var sidebar: Color { Color(white: dark ? 0.125 : 0.969) }
    var subtle: Color { Color(white: dark ? 0.15 : 0.981) }
    var selected: Color { Color(white: dark ? 0.25 : 0.885) }
    var hover: Color { Color(white: dark ? 0.18 : 0.936) }
    var border: Color { Color.primary.opacity(dark ? 0.10 : 0.065) }
}

struct SidebarRowStyle: ButtonStyle {
    var selected = false
    @Environment(\.colorScheme) private var scheme
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        let colors = AppPalette(dark: scheme == .dark)
        configuration.label
            .contentShape(Rectangle())
            .background(selected || configuration.isPressed ? colors.selected : hovering ? colors.hover : .clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .onHover { hovering = $0 }
    }
}

struct QuietButtonStyle: ButtonStyle {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @State private var hovering = false
    func makeBody(configuration: Configuration) -> some View {
        let colors = AppPalette(dark: scheme == .dark)
        configuration.label
            .font(.system(size: 12.5, weight: .medium))
            .padding(.horizontal, 11).padding(.vertical, 7)
            .contentShape(RoundedRectangle(cornerRadius: 8))
            .background(configuration.isPressed || hovering ? colors.hover : colors.canvas, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(colors.border))
            .opacity(enabled ? 1 : 0.42)
            .onHover { hovering = $0 }
    }
}

struct QuietGroupBoxStyle: GroupBoxStyle {
    @Environment(\.colorScheme) private var scheme
    func makeBody(configuration: Configuration) -> some View {
        let colors = AppPalette(dark: scheme == .dark)
        VStack(alignment: .leading, spacing: 12) {
            configuration.label.font(.system(size: 14, weight: .semibold))
            configuration.content
        }
        .padding(20).frame(maxWidth: .infinity, alignment: .leading)
        .background(colors.canvas, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 14, style: .continuous).stroke(colors.border))
    }
}

/// Native traffic lights and native window corners; no second decorative title bar.
struct WindowAttachment: NSViewRepresentable {
    let onConnect: (NSWindow) -> Void
    func makeNSView(context: Context) -> Host { let view = Host(); view.onConnect = onConnect; return view }
    func updateNSView(_ view: Host, context: Context) { view.onConnect = onConnect; if let window = view.window { onConnect(window) } }
    final class Host: NSView {
        var onConnect: ((NSWindow) -> Void)?
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); if let window { onConnect?(window) } }
        override func hitTest(_ point: NSPoint) -> NSView? { nil }
    }
}

struct WindowDragRegion: NSViewRepresentable {
    func makeNSView(context: Context) -> Host { Host() }
    func updateNSView(_ view: Host, context: Context) {}
    final class Host: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        override func mouseDown(with event: NSEvent) { window?.performDrag(with: event) }
    }
}
