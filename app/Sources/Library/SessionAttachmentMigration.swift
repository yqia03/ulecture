import Foundation

extension LibraryStore {
    /// Old libraries keep recordings beside other attachments. Copy verified bytes to the independent
    /// session root without changing their identities or removing the old rollback copy.
    func migrateLegacySessionAttachments() throws {
        guard let transcriptStore, !isReadOnly else { return }
        let fm = FileManager.default
        for asset in try attachments() {
            guard let session = try item(id: asset.ownerID), session.kind == .classroom,
                  try record(collection: "session-attachments", id: asset.id, as: SessionAttachmentLocation.self) == nil else { continue }
            let source = try managedURL(asset.relativePath)
            guard try Self.sha256(of: source) == asset.sha256 else { throw LibraryError.message("旧录音校验失败，原件保留且尚未迁移。") }
            let ext = source.pathExtension
            let relative = "recordings/" + asset.id + (ext.isEmpty ? "" : "." + ext)
            let target = try Self.safeChild(relative, under: transcriptStore.directory(for: session))
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            if !fm.fileExists(atPath: target.path) {
                let temporary = target.deletingLastPathComponent().appendingPathComponent(".migrating-" + UUID().uuidString)
                try fm.copyItem(at: source, to: temporary)
                guard try Self.sha256(of: temporary) == asset.sha256 else { throw LibraryError.message("录音副本校验失败，原件保留。") }
                try fm.moveItem(at: temporary, to: target)
                try syncDirectory(target.deletingLastPathComponent())
            }
            guard try Self.sha256(of: target) == asset.sha256 else { throw LibraryError.message("录音目标已有不同内容，未覆盖。") }
            try withTransaction {
                try putRecord(collection: "session-attachments", id: asset.id, ownerID: session.id, value: SessionAttachmentLocation(assetID: asset.id, sessionID: session.id, relativePath: relative))
                try putRecord(collection: "session-attachment-metadata", id: asset.id, ownerID: session.id, value: asset)
            }
        }
    }
}
