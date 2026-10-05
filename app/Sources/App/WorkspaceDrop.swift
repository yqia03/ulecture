import Foundation
import AppKit
import UniformTypeIdentifiers
import SwiftUI

enum WorkspaceDropPosition { case before, into, after }

struct WorkspaceRowDropDelegate: DropDelegate {
    let model: AppModel
    let item: WorkspaceItem
    let scroller: WorkspaceDragScroller
    @Binding var position: WorkspaceDropPosition?
    func dropEntered(info: DropInfo) { scroller.update() }
    func dropUpdated(info: DropInfo) -> DropProposal? {
        scroller.update()
        if info.location.y < 8 { position = .before }
        else if info.location.y > 26 { position = .after }
        else { position = [.course, .folder, .classroom].contains(item.kind) ? .into : .after }
        return DropProposal(operation: info.hasItemsConforming(to: [.fileURL]) ? .copy : .move)
    }
    func dropExited(info: DropInfo) { position = nil; scroller.stop() }
    func performDrop(info: DropInfo) -> Bool {
        scroller.stop()
        let landing = position ?? .into; position = nil
        return model.handleDrop(info.itemProviders(for: [.text, .fileURL]), parentID: landing == .into ? item.id : item.parentID, relativeTo: landing == .into ? nil : item.id, after: landing == .after)
    }
}

@MainActor extension AppModel {
    func handleDrop(_ providers: [NSItemProvider], parentID: String?, relativeTo: String? = nil, after: Bool = false) -> Bool {
        guard !busy, library != nil else { return false }
        let destination: String?
        if let id = parentID, let item = items.first(where: { $0.id == id }), ![.course, .folder, .classroom].contains(item.kind) { destination = item.parentID }
        else { destination = parentID }
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) }
        if !files.isEmpty {
            busy = true
            Task {
                do {
                    var urls: [URL] = []
                    for provider in files {
                        let url: URL = try await withCheckedThrowingContinuation { continuation in
                            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { value, error in
                                if let error { continuation.resume(throwing: error); return }
                                let url = (value as? URL) ?? (value as? Data).flatMap { URL(dataRepresentation: $0, relativeTo: nil) } ?? (value as? String).flatMap(URL.init(string:))
                                guard let url, url.isFileURL else { continuation.resume(throwing: CocoaError(.fileReadUnsupportedScheme)); return }
                                continuation.resume(returning: url)
                            }
                        }
                        urls.append(url)
                    }
                    busy = false; importURLs(urls, parentID: destination, relativeTo: relativeTo, after: after)
                } catch { busy = false; report(error) }
            }
            return true
        }
        let text = providers.filter { $0.canLoadObject(ofClass: NSString.self) }
        guard !text.isEmpty else { return false }
        busy = true
        Task {
            var dragged = [String]()
            for provider in text {
                let id: String? = await withCheckedContinuation { continuation in
                    _ = provider.loadObject(ofClass: NSString.self) { value, _ in continuation.resume(returning: value as? String) }
                }
                if let id, items.contains(where: { $0.id == id }), !dragged.contains(id) { dragged.append(id) }
            }
            // A dragged ancestor carries its descendants; selecting both must not pull a child out.
            let selectedIDs = Set(dragged)
            dragged = dragged.filter { id in
                var parent = items.first(where: { $0.id == id })?.parentID
                var seen = Set<String>()
                while let current = parent, seen.insert(current).inserted {
                    if selectedIDs.contains(current) { return false }
                    parent = items.first(where: { $0.id == current })?.parentID
                }
                return true
            }
            busy = false
            guard !dragged.isEmpty else { return }
            if let catalog = workspaceCatalog {
                let identities = dragged
                performProjectChange {
                    var anchor = relativeTo
                    for id in identities {
                        guard let item = try catalog.library.item(id: id) else { continue }
                        if item.kind == .course, let destination, relativeTo == nil {
                            try catalog.reorder(id: item.id, relativeTo: destination, after: true); continue
                        }
                        if item.parentID != destination {
                            guard let destination, item.kind != .course else { throw LibraryError.message("请选择课程或文件夹。") }
                            try catalog.move(id: item.id, parentID: destination)
                        }
                        if let anchor { try catalog.reorder(id: item.id, relativeTo: anchor, after: after) }
                        if after { anchor = item.id }
                    }
                }
            } else {
                for id in dragged { if let item = items.first(where: { $0.id == id }) { move(item, to: destination) } }
            }
        }
        return true
    }
    func moveSibling(_ item: WorkspaceItem, offset: Int) {
        guard let catalog = workspaceCatalog else { return }
        let siblings = children(item.parentID)
        guard let index = siblings.firstIndex(where: { $0.id == item.id }), siblings.indices.contains(index + offset) else { return }
        let target = siblings[index + offset]
        performProjectChange { try catalog.reorder(id: item.id, relativeTo: target.id, after: offset > 0) }
    }
}
