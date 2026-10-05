import Foundation

/// Opening a legacy note may import a large immutable Markdown revision. Resolve it off the
/// main actor; the view only publishes the completed location when its selection is still current.
struct NoteOpenLocation {
    var packageURL: URL?
    var textURL: URL?
    var draftURL: URL?

    static func resolve(item: WorkspaceItem, library: LibraryStore, catalog: WorkspaceCatalog?) throws -> NoteOpenLocation {
        let locator = try catalog?.locator(id: item.id)
        let metadata: URL
        if let catalog { metadata = try catalog.metadataDirectory(documentID: item.id) }
        else {
            metadata = library.rootURL.appendingPathComponent("document-data/" + item.id)
            try FileManager.default.createDirectory(at: metadata, withIntermediateDirectories: true)
        }
        if let catalog, let locator {
            let url = try catalog.documentURL(id: item.id)
            if locator.format == "md" || locator.format == "txt" { return Self(textURL: url, draftURL: metadata.appendingPathComponent("text-draft.json")) }
            if locator.format == "ulnote" { return Self(packageURL: url) }
        }
        let package = metadata.appendingPathComponent("note.ulnote")
        let store = BlockNoteStore(packageURL: package, noteID: item.id)
        if !FileManager.default.fileExists(atPath: package.appendingPathComponent("note.json").path) {
            if let revision = try library.noteRevision(noteID: item.id) { _ = try store.importMarkdown(Data(revision.markdown.utf8), title: item.title) }
            else { _ = try store.create(title: item.title) }
        }
        return Self(packageURL: package)
    }
}
