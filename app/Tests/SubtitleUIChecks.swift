import AppKit
import SwiftUI
import Combine

@main struct SubtitleUIChecks {
    @MainActor static func main() {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)
        let out = URL(fileURLWithPath: CommandLine.arguments[1])
        let defaults = UserDefaults(suiteName: "local.ulecture.subtitle-ui-check")!
        let controller = SubtitlePanelController(defaults: defaults)
        controller.language = "en"
        controller.display(source: "Working memory has limited capacity. This is a static UI fixture; capture and speech are off.", translation: "工作记忆的容量有限。这是静态界面样本；未采集或播报。")
        let window = NSWindow(contentRect: CGRect(x: 200, y: 260, width: 440, height: 560), styleMask: [.titled, .closable, .resizable], backing: .buffered, defer: false)
        window.title = "ULecture Subtitle Checks"
        window.contentView = NSHostingView(rootView: VStack(alignment: .leading, spacing: 12) {
            Text("Native subtitle controls — no capture or sound").font(.headline)
            HStack {
                Button("Show captions") { controller.show() }
                Button("Hide captions") { controller.hide() }
                Button("Write evidence") {
                    let values: [String: Any] = ["visible": controller.isVisible, "level": controller.panel?.level.rawValue ?? 0, "windowNumber": controller.panel?.windowNumber ?? 0, "keyWindow": app.keyWindow?.title ?? "", "canBecomeMain": controller.panel?.canBecomeMain ?? false, "canBecomeKey": controller.panel?.canBecomeKey ?? false, "hidesOnDeactivate": controller.panel?.hidesOnDeactivate ?? true, "capture": false, "speech": false]
                    try? JSONSerialization.data(withJSONObject: values, options: [.prettyPrinted, .sortedKeys]).write(to: out.appendingPathComponent("panel-state.json"))
                    try? JSONEncoder().encode(controller.preferences).write(to: out.appendingPathComponent("preferences.json"))
                }
            }
            TextField("Keyboard focus stays in this field", text: .constant("Focus fixture"))
            SubtitlePreferencesView(controller: controller, language: "en")
        }.padding(20))
        window.makeKeyAndOrderFront(nil)
        app.activate(ignoringOtherApps: true)
        app.run()
    }
}
