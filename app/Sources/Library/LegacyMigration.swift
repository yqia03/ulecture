import Foundation
import Darwin
import CryptoKit

struct LegacyMigrationReceipt: Codable {
    var format = "ulecture-legacy-migration"
    var migrationVersion = 1
    var taskID: String
    var sourceLibraryID: String
    var snapshotHash: String
    var sourceFingerprint: String
    var itemCount: Int
    var recordCount: Int
    var attachmentHashes: [String: String]
    var fileHashes: [String: [String: String]]? = nil
    var phase: String
    var createdAt: Date
}

/// Migration reads a frozen SQLite snapshot. Originals and every historical revision remain available.
final class LegacyMigration {
    let destination: LibraryStore
    private let fm = FileManager.default
    init(destination: LibraryStore) { self.destination = destination }

    func prepare(sourceRoot: URL, newGeneration: Bool = false, checkpoint: ((String) throws -> Void)? = nil) throws -> URL {
        // Cooperate with the legacy writer lock; a second running writer must finish before snapshotting.
        let lockURL = sourceRoot.appendingPathComponent(".writer.lock")
        let fd = open(lockURL.path, O_RDONLY | O_NOFOLLOW)
        guard fd >= 0 else { throw LibraryError.message("旧资料库缺少写入锁，不能确认一致性。") }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else { close(fd); throw LibraryError.message("旧资料库仍在使用，请关闭旧版本再迁移。") }
        defer { flock(fd, LOCK_UN); close(fd) }
        let source = try LibraryStore(rootURL: sourceRoot, createIfMissing: false, readOnly: true)
        let base = destination.rootURL.appendingPathComponent("migrations/" + source.libraryID, isDirectory: true)
        let folder = newGeneration ? base.appendingPathComponent("generations/" + UUID().uuidString, isDirectory: true) : base
        let receiptURL = folder.appendingPathComponent("migration.json")
        let published = folder.appendingPathComponent("snapshot")
        let embeddedReceipt = published.appendingPathComponent(".migration-receipt.json")
        if !fm.fileExists(atPath: receiptURL.path), fm.fileExists(atPath: embeddedReceipt.path) {
            let receipt = try JSONDecoder().decode(LegacyMigrationReceipt.self, from: Data(contentsOf: embeddedReceipt))
            try verify(snapshot: published, receipt: receipt)
            try Data(contentsOf: embeddedReceipt).write(to: receiptURL, options: .atomic)
        }
        if fm.fileExists(atPath: receiptURL.path) {
            let receipt = try JSONDecoder().decode(LegacyMigrationReceipt.self, from: Data(contentsOf: receiptURL))
            guard receipt.migrationVersion == 1, receipt.sourceLibraryID == source.libraryID else { throw LibraryError.message("迁移任务版本不匹配，已有快照保留。") }
            guard try fingerprint(source) == receipt.sourceFingerprint else { throw LibraryError.message("旧库在快照后已有修改。原快照与新修改均保留；请重新预检，不能继续旧任务。") }
            let snapshot = folder.appendingPathComponent("snapshot")
            try verify(snapshot: snapshot, receipt: receipt)
            return snapshot
        }
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let taskID = UUID().uuidString
        let stage = folder.appendingPathComponent("snapshot-" + taskID, isDirectory: true)
        try fm.createDirectory(at: stage, withIntermediateDirectories: false)
        try source.snapshotDatabase(to: stage.appendingPathComponent("library.sqlite"))
        // Only owned library data is copied. Models, credentials and global preferences are never enumerated.
        for directory in ["attachments", "document-data", "recording-staging"] {
            let original = source.rootURL.appendingPathComponent(directory)
            if fm.fileExists(atPath: original.path) {
                let before = try WorkspaceCatalog.manifest(original)
                let copy = stage.appendingPathComponent(directory)
                try fm.copyItem(at: original, to: copy)
                guard try WorkspaceCatalog.manifest(copy) == before, try WorkspaceCatalog.manifest(original) == before else { throw LibraryError.message("快照期间资料发生变化，旧资料未改写；请重新预检。") }
            }
        }
        let frozen = try LibraryStore(rootURL: stage, createIfMissing: false, readOnly: true)
        let attachments = try frozen.attachments()
        for asset in attachments {
            guard try LibraryStore.sha256(of: frozen.attachmentURL(assetID: asset.id)) == asset.sha256 else { throw LibraryError.message("旧附件校验失败，迁移未提交。") }
        }
        var receipt = LegacyMigrationReceipt(taskID: taskID, sourceLibraryID: source.libraryID,
            snapshotHash: try LibraryStore.sha256(of: stage.appendingPathComponent("library.sqlite")), sourceFingerprint: try fingerprint(source), itemCount: try frozen.items(includeDeleted: true).count,
            recordCount: try frozen.databaseRows("SELECT id FROM records").count,
            attachmentHashes: Dictionary(uniqueKeysWithValues: attachments.map { ($0.id, $0.sha256) }), phase: "verified", createdAt: Date())
        receipt.fileHashes = try Dictionary(uniqueKeysWithValues: ["attachments", "document-data", "recording-staging"].compactMap { name in
            let url = stage.appendingPathComponent(name)
            return fm.fileExists(atPath: url.path) ? (name, try WorkspaceCatalog.manifest(url)) : nil
        })
        try JSONEncoder().encode(receipt).write(to: stage.appendingPathComponent(".migration-receipt.json"), options: .atomic)
        let snapshot = folder.appendingPathComponent("snapshot")
        if fm.fileExists(atPath: snapshot.path) {
            try fm.moveItem(at: snapshot, to: folder.appendingPathComponent("snapshot-unverified-" + UUID().uuidString))
        }
        try fm.moveItem(at: stage, to: snapshot)
        try checkpoint?("snapshot-published")
        try JSONEncoder().encode(receipt).write(to: receiptURL, options: .atomic)
        try destination.syncDirectory(folder)
        return snapshot
    }

    @discardableResult func install(snapshot: URL, checkpoint: ((String) throws -> Void)? = nil) throws -> LegacyMigrationReceipt {
        let receiptURL = snapshot.deletingLastPathComponent().appendingPathComponent("migration.json")
        var receipt = try JSONDecoder().decode(LegacyMigrationReceipt.self, from: Data(contentsOf: receiptURL))
        try verify(snapshot: snapshot, receipt: receipt)
        let source = try LibraryStore(rootURL: snapshot, createIfMissing: false, readOnly: true)
        let marker = destination.rootURL.appendingPathComponent("migrations/" + receipt.sourceLibraryID + "/installed.json")
        if fm.fileExists(atPath: marker.path) {
            let old = try JSONDecoder().decode(LegacyMigrationReceipt.self, from: Data(contentsOf: marker))
            guard old.taskID == receipt.taskID, old.snapshotHash == receipt.snapshotHash else { throw LibraryError.message("迁移源快照已变化，未覆盖既有修改。") }
            return old
        }
        if var saved = try destination.record(collection: "legacy-migration", id: receipt.taskID, as: LegacyMigrationReceipt.self) {
            guard saved.snapshotHash == receipt.snapshotHash else { throw LibraryError.message("迁移源快照已变化，未覆盖既有修改。") }
            saved.phase = "committed"
            try JSONEncoder().encode(saved).write(to: marker, options: .atomic)
            return saved
        }
        let items = try source.items(includeDeleted: true)
        let records = try source.databaseRows("SELECT collection,id,owner_id,json FROM records").map {
            PortableRecord(collection: $0["collection"]!, id: $0["id"]!, ownerID: $0["owner_id"]!, json: $0["json"]!)
        }
        // Copy verified assets before the catalog commit. A retry accepts only the same bytes.
        for asset in try source.attachments() {
            let target = try destination.managedURL(asset.relativePath)
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            try VerifiedMigrationCopy.copy(source.attachmentURL(assetID: asset.id), to: target, expected: [".": asset.sha256])
        }
        let original = snapshot.appendingPathComponent("document-data")
        if fm.fileExists(atPath: original.path) {
            for child in try fm.contentsOfDirectory(at: original, includingPropertiesForKeys: nil) {
                try VerifiedMigrationCopy.copy(child, to: destination.rootURL.appendingPathComponent("document-data/" + child.lastPathComponent))
            }
        }
        try checkpoint?("files-published")
        try destination.withTransaction {
            // Idempotency lives inside the same transaction as the imported identities.
            if let first = items.first, let old = try destination.record(collection: "legacy-migration", id: receipt.taskID, as: LegacyMigrationReceipt.self) {
                guard old.snapshotHash == receipt.snapshotHash, try destination.item(id: first.id) != nil else { throw LibraryError.message("迁移任务与已保存身份不一致。") }
                return
            }
            var pending = items
            while !pending.isEmpty {
                let ready = pending.filter { $0.parentID == nil || (try? destination.item(id: $0.parentID!)) != nil }
                guard !ready.isEmpty else { throw LibraryError.message("旧资料层级包含缺失引用。") }
                for item in ready {
                    guard try destination.item(id: item.id) == nil else { throw LibraryError.message("稳定标识与现有资料冲突，未覆盖。") }
                    try destination.writeItem(item)
                }
                let ids = Set(ready.map(\.id)); pending.removeAll { ids.contains($0.id) }
            }
            for asset in try source.attachments() { try destination.writeAttachment(asset) }
            for record in records { try destination.writePortableRecord(record) }
            for session in items where session.kind == .classroom {
                try destination.putRecord(collection: "workspace-restore-pending", id: session.id, ownerID: session.id, value: ["restoreTaskID": receipt.taskID])
            }
            if let owner = items.first?.id {
                try destination.putRecord(collection: "legacy-migration", id: receipt.taskID, ownerID: owner, value: receipt)
                try destination.putRecord(collection: "workspace-restores", id: receipt.taskID, ownerID: owner, value: ["legacyMigrationTaskID": receipt.taskID])
            }
        }
        try checkpoint?("catalog-committed")
        receipt.phase = "committed"
        try JSONEncoder().encode(receipt).write(to: marker, options: .atomic)
        return receipt
    }

    private func verify(snapshot: URL, receipt: LegacyMigrationReceipt) throws {
        guard receipt.format == "ulecture-legacy-migration", receipt.migrationVersion == 1,
              try LibraryStore.sha256(of: snapshot.appendingPathComponent("library.sqlite")) == receipt.snapshotHash else { throw LibraryError.message("迁移快照已改变，未继续。") }
        for (path, hashes) in receipt.fileHashes ?? [:] {
            guard try WorkspaceCatalog.manifest(LibraryStore.safeChild(path, under: snapshot)) == hashes else { throw LibraryError.message("迁移快照已改变，未继续。") }
        }
        let library = try LibraryStore(rootURL: snapshot, createIfMissing: false, readOnly: true)
        guard library.libraryID == receipt.sourceLibraryID, try library.items(includeDeleted: true).count == receipt.itemCount,
              try library.databaseRows("SELECT id FROM records").count == receipt.recordCount else { throw LibraryError.message("迁移快照实体数量不一致。") }
        for asset in try library.attachments() { guard receipt.attachmentHashes[asset.id] == asset.sha256, try LibraryStore.sha256(of: library.attachmentURL(assetID: asset.id)) == asset.sha256 else { throw LibraryError.message("迁移快照附件校验失败。") } }
    }
    private func fingerprint(_ store: LibraryStore) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: [
            "items": store.databaseRows("SELECT id,json FROM items ORDER BY id"),
            "records": store.databaseRows("SELECT collection,id,json FROM records ORDER BY collection,id"),
            "attachments": store.databaseRows("SELECT id,json FROM attachments ORDER BY id")
        ], options: [.sortedKeys])
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
