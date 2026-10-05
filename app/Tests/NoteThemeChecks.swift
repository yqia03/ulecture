import AppKit
import SwiftUI

@main @MainActor enum NoteThemeChecks {
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { do { try await run(); exit(0) } catch { print("FAIL: \(error.localizedDescription)"); exit(1) } }
        NSApplication.shared.run()
    }
    static func run() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]); try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let id = UUID().uuidString, package = root.appendingPathComponent("Theme.ulnote"), store = BlockNoteStore(packageURL: package, noteID: id)
        var document = try store.create(title: "Theme persistence")
        let plain = NoteBlock(kind: .paragraph, text: "Default semantic text · 中文・日本語")
        var rich = NoteBlock(kind: .paragraph, text: "Bold text without an explicit color")
        rich.richText = try NoteRichText.encode(NSAttributedString(string: rich.text, attributes: [.font: NSFont.boldSystemFont(ofSize: 17)]))
        var colored = NoteBlock(kind: .paragraph, text: "Explicit red remains authored red")
        colored.richText = try NoteRichText.encode(NSAttributedString(string: colored.text, attributes: [.font: NSFont.systemFont(ofSize: 17), .foregroundColor: NSColor.red]))
        let originalColorData = colored.richText
        document.blocks = [plain, rich, colored]; _ = try store.save(document)
        let originalNoteBytes = try Data(contentsOf: package.appendingPathComponent("note.json"))
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 760, height: 600), styleMask: .borderless, backing: .buffered, defer: false); window.isReleasedWhenClosed = false
        var checks: [String] = []
        func require(_ value: @autoclosure () -> Bool, _ label: String) throws { guard value() else { throw DocumentFailure.message(label) }; checks.append(label) }
        func fields(_ view: NSView) -> [NSTextView] { (view as? NSTextView).map { [$0] } ?? view.subviews.flatMap(fields) }
        func content(_ dark: Bool) -> AnyView { AnyView(BlockNoteEditor(packageURL: package, noteID: id, title: "Theme persistence").environment(\.colorScheme, dark ? .dark : .light)) }
        func open(_ dark: Bool) async -> NSHostingView<AnyView> {
            window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
            let host = NSHostingView(rootView: content(dark))
            window.contentView = host; host.frame = CGRect(x: 0, y: 0, width: 760, height: 600)
            try? await Task.sleep(nanoseconds: 250_000_000); host.layoutSubtreeIfNeeded(); return host
        }
        func verify(_ host: NSView, dark: Bool, label: String) throws {
            for block in [plain, rich, colored] {
                guard let text = fields(host).first(where: { $0.identifier?.rawValue == "block-" + block.id }), let color = text.textStorage?.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor else { throw DocumentFailure.message("Missing native text color") }
                try require(text.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (dark ? .darkAqua : .aqua), label + " actual NSTextView appearance matches the selected theme")
                if block.id == colored.id { try require(color == NSColor.red, label + " explicitly authored foreground remains red") }
                else {
                    var brightness: CGFloat = -1
                    text.effectiveAppearance.performAsCurrentDrawingAppearance { brightness = color.usingColorSpace(.deviceRGB).map { ($0.redComponent + $0.greenComponent + $0.blueComponent) / 3 } ?? -1 }
                    try require(dark ? brightness > 0.7 : brightness >= 0 && brightness < 0.3, label + " automatic foreground has readable theme contrast")
                }
            }
            host.displayIfNeeded(); guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw DocumentFailure.invalidFormat }
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try bitmap.representation(using: .png, properties: [:])!.write(to: root.appendingPathComponent(label + ".png"))
        }
        var host: NSView? = await open(true); try verify(host!, dark: true, label: "initial-dark")
        let afterOpen = try Data(contentsOf: package.appendingPathComponent("note.json"))
        try require(afterOpen == originalNoteBytes, "Opening an uncolored note only styles the display copy and preserves exact note.json bytes")
        guard let editor = DocumentEditingSessions.noteEditor(at: package), let text = fields(host!).first(where: { $0.identifier?.rawValue == "block-" + plain.id }) else { throw DocumentFailure.invalidFormat }
        let end = (text.string as NSString).length; text.setSelectedRange(NSRange(location: end, length: 0)); text.insertText(" saved", replacementRange: NSRange(location: end, length: 0))
        guard await editor.flush() else { throw DocumentFailure.conflict }
        let saved = try store.load(); try require(saved.blocks.first?.text.hasSuffix(" saved") == true, "Native editing commits the semantic foreground with exact Unicode text")
        let savedNoteBytes = try Data(contentsOf: package.appendingPathComponent("note.json"))
        try require(saved.blocks.first(where: { $0.id == colored.id })?.richText == originalColorData, "Saving another block never rewrites explicit rich-text color bytes")
        window.contentView = nil; host = nil
        let reopenedLight = await open(false); try verify(reopenedLight, dark: false, label: "reopened-light")
        window.appearance = NSAppearance(named: .darkAqua); reopenedLight.appearance = NSAppearance(named: .darkAqua)
        reopenedLight.rootView = content(true)
        try await Task.sleep(nanoseconds: 150_000_000); try verify(reopenedLight, dark: true, label: "reopened-native-dark")
        window.contentView = nil
        let reopenedDark = await open(true); try verify(reopenedDark, dark: true, label: "reopened-dark")
        let afterThemes = try Data(contentsOf: package.appendingPathComponent("note.json"))
        try require(afterThemes == savedNoteBytes, "Reopening and changing appearance do not save or rewrite document bytes")
        window.close()
        try JSONSerialization.data(withJSONObject: ["checks": checks, "scope": "Actual native NSTextView theme resolution, native edit, persisted secure attributed archive, explicit color preservation and hidden renders; no desktop actions or cloud"], options: [.prettyPrinted, .sortedKeys]).write(to: root.appendingPathComponent("results.json"))
        print("PASS: \(checks.count) native note theme/edit/reopen checks")
    }
}
