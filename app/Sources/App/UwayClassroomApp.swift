import SwiftUI
import AppKit

@main struct ULectureApp: App {
    @NSApplicationDelegateAdaptor(ClassroomAppDelegate.self) var delegate
    @StateObject private var model = AppModel()
    var body: some Scene {
        Window("ULecture", id: "main") {
            RootView(model: model)
                .background(WindowAttachment { window in
                    delegate.model = model
                    delegate.install(on: window)
                })
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 850)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button(model.t("aboutApp")) {
                    NSApp.orderFrontStandardAboutPanel(options: [
                        .applicationName: "ULecture",
                        .applicationIcon: NSImage(named: NSImage.applicationIconName) ?? NSImage(),
                        .credits: NSAttributedString(string: model.t("productSummary") + "\n\n" + model.t("licensePending") + "\nhttps://github.com/yqia03/ulecture")
                    ])
                }
            }
            CommandGroup(replacing: .newItem) {
                Button(model.t("importPDF")) { model.importPDF(parentID: model.suitableParent(for: .pdf)) }.keyboardShortcut("i")
                Button(model.t("save")) { Task { _ = await DocumentEditingSessions.flushAll(); _ = model.flushDrafts() } }.keyboardShortcut("s")
            }
            CommandGroup(replacing: .appSettings) {
                Button(model.t("settings")) { model.route = "settings" }.keyboardShortcut(",")
            }
            CommandMenu(model.t("classroom")) {
                Button(model.t("pause")) { if model.route == "voiceTool" { Task { await model.interpretation?.pause() } } else { model.pauseClass() } }.keyboardShortcut("p", modifiers: [.command, .shift])
                Button(model.t("stopSound")) { model.audio.stopPlayback(); model.clouds.values.forEach { $0.stopSpeech() }; model.interpretation?.stopSpeech(); model.interpretation?.capture.stopPlayback() }.keyboardShortcut(".")
                Button(model.t("sidebar")) { model.sidebarVisible.toggle() }.keyboardShortcut("s", modifiers: [.command, .control])
            }
        }
    }
}
