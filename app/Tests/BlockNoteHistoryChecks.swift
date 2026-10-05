import AppKit

@main @MainActor enum BlockNoteHistoryChecks {
    static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let package = root.appendingPathComponent("History.ulnote"), id = UUID().uuidString
        let store = BlockNoteStore(packageURL: package, noteID: id)
        var original = try store.create(title: "History")
        original.blocks = [NoteBlock(kind: .paragraph, text: "Original exact version")]; original = try store.save(original)
        let fixed = try store.revisionSnapshot(original.revision)
        var next = original; next.blocks[0].text = "Current revised text"; next = try store.save(next)
        let currentBytes = try Data(contentsOf: package.appendingPathComponent("note.json"))
        var checks: [String] = []
        func require(_ value: @autoclosure () throws -> Bool, _ label: String) throws { guard try value() else { throw DocumentFailure.message("FAILED: " + label) }; checks.append(label) }
        let editor = BlockNoteEditorModel(packageURL: package, noteID: id)
        await editor.load(title: "History", language: "en", revision: original.revision)
        try require(editor.readOnly && editor.document == original, "initial fixed-version navigation opens the exact historical note as read-only")
        await editor.showRevision(next.revision)
        try require(editor.readOnly && editor.document == next, "an explicitly pinned latest revision is also read-only")
        await editor.showRevision(original.revision)
        try Data("damaged current note".utf8).write(to: package.appendingPathComponent("note.json"))
        var failed = false
        do { _ = try await DocumentNoteActions.append([NoteBlock(kind: .paragraph, text: "AI result")], packageURL: package, documentID: id, title: "History") }
        catch { failed = true }
        try require(failed && editor.readOnly && editor.document == original, "append reports failure when the current version cannot open, rather than claiming a no-op was saved")
        try require(try store.revisionSnapshot(original.revision).sourceHash == fixed.sourceHash, "failed append leaves the cited immutable revision unchanged")
        await editor.showRevision(original.revision)
        try require(editor.readOnly && editor.document == original && editor.error == nil, "historical note remains readable even with a damaged current note")
        try currentBytes.write(to: package.appendingPathComponent("note.json"))
        let appended = try await DocumentNoteActions.append([NoteBlock(kind: .paragraph, text: "Explicit AI result")], packageURL: package, documentID: id, title: "History")
        try require(!editor.readOnly && appended.revision > next.revision && appended.blocks.first?.text == "Current revised text" && appended.blocks.last?.text == "Explicit AI result", "explicit append after restoration targets current content and commits a new revision")
        try require(try store.load().blocks == appended.blocks && store.revisionSnapshot(original.revision).sourceHash == fixed.sourceHash, "successful append survives reopen and preserves the original reference")
        let result: [String: Any] = ["suite": "BlockNoteHistoryChecks", "passed": checks.count, "checks": checks, "scope": "Production note model and write-back action with actual revision files; no UI automation or cloud"]
        let data = try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys]); try data.write(to: root.appendingPathComponent("results.json")); print(String(decoding: data, as: UTF8.self))
    }
}
