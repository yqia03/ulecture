import Foundation

/// Consumes real output packages from DocumentTranslationChecks with the canonical editor store.
@main enum TranslatedNoteReopenChecks {
    static func main() throws {
        var results = [[String: Any]]()
        for path in CommandLine.arguments.dropFirst() {
            let url = URL(fileURLWithPath: path), store = BlockNoteStore(packageURL: url, noteID: UUID().uuidString)
            let current = try store.loadSnapshot()
            guard store.missingResources(in: current.document).isEmpty else { throw DocumentFailure.missingResource(path) }
            var hashes = [String]()
            for revision in 1...current.document.revision {
                let prior = try store.revisionSnapshot(revision)
                guard prior.document.id == current.document.id,
                      prior.document.blocks.map(\.id) == current.document.blocks.map(\.id),
                      store.missingResources(in: prior.document).isEmpty else { throw DocumentFailure.invalidFormat }
                hashes.append(prior.sourceHash)
            }
            guard Set(hashes).count == current.document.revision else { throw DocumentFailure.invalidFormat }
            results.append(["package": path, "revision": current.document.revision, "id": current.document.id, "blocks": current.document.blocks.count, "hash": current.sourceHash, "allVersionsReadable": true, "resourcesPresent": true])
        }
        guard !results.isEmpty else { throw DocumentFailure.message("Pass real translated .ulnote output paths") }
        let report: [String: Any] = ["suite": "TranslatedNoteReopenChecks", "passed": results.count, "packages": results, "scope": "Canonical BlockNoteStore loadSnapshot and every immutable revision; real translation output, no cloud request"]
        print(String(decoding: try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
}
