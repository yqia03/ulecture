import AppKit
import SwiftUI

/// Test-only initial-state injection. The product content and the system's
/// disclosure rendering remain unchanged; this does not simulate a user click.
private struct ExpandedForRendering: DisclosureGroupStyle {
    func makeBody(configuration: Configuration) -> some View {
        DisclosureGroup(isExpanded: configuration.$isExpanded) {
            configuration.content.disclosureGroupStyle(ExpandedForRendering())
        } label: { configuration.label }
        .disclosureGroupStyle(.automatic)
        .onAppear { configuration.isExpanded = true }
    }
}

@main @MainActor enum ExpandedUIRenderChecks {
    static var entries = [[String: Any]]()
    static func argument(_ name: String) -> String? { CommandLine.arguments.firstIndex(of: name).flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil } }
    static func main() {
        NSApplication.shared.setActivationPolicy(.prohibited)
        Task { do { try await run(); exit(0) } catch { print("FAIL: \(error.localizedDescription)"); exit(1) } }
        NSApplication.shared.run()
    }
    static func run() async throws {
        guard let path = argument("--ui-test-workspace"), argument("--model-cache") != nil,
              let target = argument("--render-output"), let ocrPath = argument("--ocr-catalog"), let scopePath = argument("--scope-catalog") else { throw DocumentFailure.invalidFormat }
        let fm = FileManager.default, root = URL(fileURLWithPath: path), output = URL(fileURLWithPath: target)
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let ids = try FullUIRenderChecks.fixture(root)
        let defaults = AppPreferences.shared.defaults, keys = ["interfaceLanguage", "darkAppearance", "hideSetup", "classPanel"]
        let previous = Dictionary(uniqueKeysWithValues: keys.map { ($0, defaults.object(forKey: $0)) })
        defer { for key in keys { if let value = previous[key] ?? nil { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) } } }
        let model = AppModel(); model.workspaceRefreshTask?.cancel(); model.workspaceRefreshTask = nil; model.legacyLibraryURL = nil
        guard model.isTestMode, let library = model.library, let catalog = model.workspaceCatalog else { throw DocumentFailure.invalidFormat }
        let session = try library.item(id: ids["class"]!)!
        model.openItem(session); model.ensureCloud(session.id)
        try model.configureClassTerminology(session.id, enabled: true)
        let controls = AIAssistantController(library: library, catalog: catalog, settings: model.cloudService)
        await controls.selectContext(itemID: session.id, classroomID: session.id)
        for option in controls.options where [.transcript, .note, .pdf].contains(option.kind) { controls.selectSource(option.id, included: true) }
        if let option = controls.options.first(where: { $0.kind == .transcript }) { controls.setTranscriptRange(option, start: "00:02", end: "00:07") }
        if let option = controls.options.first(where: { $0.kind == .note }) { controls.selectNoteVersion(option, version: 1) }
        guard controls.scope(for: controls.options.first { $0.kind == .note }!).version == 1 else { throw DocumentFailure.invalidFormat }
        let ocrLibrary = try LibraryStore(rootURL: URL(fileURLWithPath: ocrPath), createIfMissing: false, readOnly: true)
        let ocrCatalog = WorkspaceCatalog(library: ocrLibrary)
        let ocr = AIAssistantController(library: ocrLibrary, catalog: ocrCatalog, settings: model.cloudService)
        guard let source = try ocrLibrary.items().first(where: { $0.kind == .pdf && $0.title.hasPrefix("Bitmap evidence") }) else { throw DocumentFailure.invalidFormat }
        await ocr.selectContext(itemID: source.id)
        guard ocr.turns.contains(where: { turn in ocr.snapshots[turn.snapshotID]?.pdfCoverage?.count == 3 }),
              ocr.snapshots.values.contains(where: { $0.sources.contains { $0.ocr != nil } }) else { throw DocumentFailure.message("Real stored OCR provenance is required") }
        let scopeLibrary = try LibraryStore(rootURL: URL(fileURLWithPath: scopePath), createIfMissing: false, readOnly: true)
        let scopes = AIAssistantController(library: scopeLibrary, catalog: WorkspaceCatalog(library: scopeLibrary), settings: model.cloudService)
        guard let savedScope = try scopeLibrary.records(collection: "assistant-conversations", as: AssistantConversation.self).first else { throw DocumentFailure.invalidFormat }
        await scopes.selectContext(itemID: savedScope.contextID)
        guard let firstTurn = scopes.turns.first, scopes.snapshots[firstTurn.snapshotID]?.sources.contains(where: { $0.kind == .transcript && $0.startMS == 3000 && $0.endMS == 7000 }) == true else { throw DocumentFailure.message("The saved real controller fixture must expose its exact 00:03–00:07 source") }
        let window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 1280, height: 840), styleMask: .borderless, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        for language in ["zh-Hans", "zh-Hant", "en", "ja"] {
            for dark in [false, true] {
                model.preferences.language = language; model.preferences.dark = dark
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                for width in [1280, 760] {
                    let components: [(String, AnyView, Int, String)] = [
                        ("20-source-controls", AnyView(AIAssistantView(controller: controls, language: language)), 1100, "Production assistant with locally saved transcript bounds and note version; test-only initial disclosure expansion; no ask or retry."),
                        ("21-ocr-coverage", AnyView(AIAssistantView(controller: ocr, language: language)), width == 760 ? 3600 : 3000, "Production assistant reopened read-only from the passing real bitmap/Vision OCR fixture; source provenance and missing-page coverage are saved historical evidence. Controls are disabled because the fixture is read-only."),
                        ("22-classroom-terminology", AnyView(ClassroomTerminologyView(cloud: model.clouds[session.id]!, terminology: model.textTranslation, classID: session.id, courseID: session.courseID!)), 340, "Production classroom terminology controls with a locally saved enabled empty snapshot; no translation request."),
                        ("23-conversion-repair", AnyView(ConversionResourceView(language: language)), 380, "Production resource verification/repair component in a CLI harness lacking the bundle manifest; the displayed missing-resource result is real and is not the final application bundle's ready state."),
                        ("25-transcript-evidence", AnyView(AIAssistantView(controller: scopes, language: language)), 1800, "Read-only production controller reopening the real saved source-scope test conversation. The first fixed transcript source is exactly 00:03–00:07; no synthesized turn, ask or retry.")
                    ]
                    for (name, component, height, scope) in components {
                        let host = NSHostingView(rootView: component
                            .disclosureGroupStyle(ExpandedForRendering())
                            .padding(24).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .background(AppPalette(dark: dark).canvas)
                            .frame(width: CGFloat(width), height: CGFloat(height), alignment: .topLeading)
                            .environmentObject(model).environmentObject(model.preferences)
                            .environment(\.colorScheme, dark ? .dark : .light))
                        window.setContentSize(CGSize(width: width, height: height)); window.contentView = host
                        host.frame = CGRect(x: 0, y: 0, width: width, height: height)
                        try await Task.sleep(nanoseconds: 300_000_000)
                        try capture(host, output: output, name: name, language: language, dark: dark, width: width, height: height, scope: scope)
                        if name == "20-source-controls" {
                            scrollFirstToEnd(host)
                            try await Task.sleep(nanoseconds: 100_000_000)
                            try capture(host, output: output, name: "24-source-controls-bottom", language: language, dark: dark, width: width, height: height, scope: scope + " The source list was scrolled internally to its final viewport.")
                        }
                        window.contentView = nil
                    }
                }
            }
        }
        guard model.audio.phase != .capturing, model.probe.phase != .capturing, !model.serviceSettings.credentialUnlocked,
              model.cloudService.usage.isEmpty else { throw DocumentFailure.message("Unexpected active service state") }
        window.close()
        let report: [String: Any] = ["suite": "ExpandedUIRenderChecks", "count": entries.count, "images": entries,
            "scope": "Supplementary actual component rendering using a test-only initially expanded system DisclosureGroup style. Not click acceptance or a replacement for the 304 unmodified RootView baseline.",
            "ocrFixture": ocrPath, "ocrSnapshotHashes": ocr.snapshots.values.map(\.hash).sorted(), "scopeFixture": scopePath, "scopeSnapshotHashes": scopes.snapshots.values.map(\.hash).sorted(),
            "limitations": ["Internal rendering does not prove pointer/keyboard interaction or platform permission behavior.", "The tall OCR component makes stored evidence visible outside the normal viewport; the product retains scrolling.", "Conversion missing-manifest state is specific to the command-line render harness, not the delivered app."]]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("results.json"))
        print("Rendered \(entries.count) supplementary actual component images")
    }
    static func scrollFirstToEnd(_ view: NSView) {
        func all(_ value: NSView) -> [NSScrollView] { (value as? NSScrollView).map { [$0] } ?? value.subviews.flatMap(all) }
        if let scroll = all(view).first, let document = scroll.documentView {
            scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentSize.height)))
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }
    static func capture(_ host: NSView, output: URL, name: String, language: String, dark: Bool, width: Int, height: Int, scope: String) throws {
        host.layoutSubtreeIfNeeded(); host.displayIfNeeded()
        guard let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { throw DocumentFailure.invalidFormat }
        host.cacheDisplay(in: host.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]), png.count > 3000 else { throw DocumentFailure.invalidFormat }
        let filename = "\(name)-\(language)-\(dark ? "dark" : "light")-\(width).png"
        try png.write(to: output.appendingPathComponent(filename))
        entries.append(["page": name, "language": language, "theme": dark ? "dark" : "light", "width": width, "height": height, "pixelWidth": bitmap.pixelsWide, "pixelHeight": bitmap.pixelsHigh, "bytes": png.count, "path": filename, "scope": scope])
    }
}
