import AppKit

@MainActor final class ClassroomAppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    weak var model: AppModel?
    private weak var installedWindow: NSWindow?
    private var closeInProgress = false
    private var approvedWindowClose = false
    func install(on window: NSWindow) {
        guard installedWindow !== window else { return }
        installedWindow = window
        window.delegate = self
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        window.styleMask.insert(.fullSizeContentView)
        window.isMovableByWindowBackground = false
        window.toolbar = nil
    }
    func applicationDidFinishLaunching(_ notification: Notification) { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true) }
    func applicationDidBecomeActive(_ notification: Notification) { model?.refreshProjects(reportErrors: false, showProgress: false) }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        guard let model else { return true }
        if approvedWindowClose { return true }
        guard !closeInProgress else { return false }
        closeInProgress = true
        // Keep the recovery/error UI alive until the final ASR callbacks and
        // every pending save have completed. A queued pause is not a drain.
        Task {
            let saved = await model.prepareForExit()
            closeInProgress = false
            if saved { approvedWindowClose = true; sender.performClose(nil) }
        }
        return false
    }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let model else { return .terminateNow }
        guard model.flushDrafts() else { return .terminateCancel }
        model.audio.stopPlayback(); model.clouds.values.forEach { $0.stopSpeech() }
        Task { NSApp.reply(toApplicationShouldTerminate: await model.prepareForExit()) }
        return .terminateLater
    }
}
