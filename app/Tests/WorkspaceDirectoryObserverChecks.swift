import Foundation

@main struct WorkspaceDirectoryObserverChecks {
    @MainActor static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        let first = root.appendingPathComponent("first"), second = root.appendingPathComponent("second")
        for path in [first, second] { try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false) }
        var changes = 0, checks = [String]()
        let observer = WorkspaceDirectoryObserver { changes += 1 }
        func run(_ executable: String, _ arguments: [String]) throws {
            let child = Process(); child.executableURL = URL(fileURLWithPath: executable); child.arguments = arguments
            try child.run(); child.waitUntilExit(); precondition(child.terminationStatus == 0)
        }
        func awaitEvent(after count: Int) {
            let deadline = Date().addingTimeInterval(4)
            while changes == count && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.03)) }
            precondition(changes > count, "Expected an actual external filesystem event")
        }
        observer.observe([first.path, second.path])
        try run("/usr/bin/touch", [first.appendingPathComponent("External.md").path])
        awaitEvent(after: 0); checks.append("external process creates file in first watched root")
        let beforeRename = changes
        try run("/bin/mv", [first.appendingPathComponent("External.md").path, second.appendingPathComponent("日本語.md").path])
        awaitEvent(after: beforeRename); checks.append("external cross-root rename requests a catalog rescan")
        observer.observe([second.path])
        let beforeSecond = changes
        try run("/usr/bin/touch", [second.appendingPathComponent("New.txt").path])
        awaitEvent(after: beforeSecond); checks.append("updating watched mounts retains event delivery")
        observer.stop()
        let afterStop = changes
        try run("/usr/bin/touch", [second.appendingPathComponent("After-stop.txt").path])
        RunLoop.current.run(until: Date().addingTimeInterval(0.8))
        precondition(changes == afterStop); checks.append("stopped observer no longer requests scans")
        let result: [String: Any] = ["passed": checks.count, "checks": checks, "eventsReceived": changes, "scope": "Real FSEvents with separate local touch/mv processes; no UI, network or user files"]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("results.json")); print(String(decoding: data, as: UTF8.self))
    }
}
