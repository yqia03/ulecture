import Foundation
import CryptoKit
import Darwin

private struct LegacyArchiveConversionReceipt: Codable {
    var format = "ulecture-legacy-archive-conversion"
    var version = 1
    var sourceFingerprint: String
    var sourceManifestHash: String
    var attachmentHashes: [String: String]
    var convertedManifestHash: String
}
private struct LegacyArchiveJournalIdentity: Decodable {
    var id: String
    var sourceHash: String
    var destination: String
}
private struct LegacyArchiveRestoreCommit: Decodable {
    var snapshotID: String
    var itemIDs: [String]
}

/// A v1 archive never writes directly into the user's current catalog. Its
/// validated conversion is atomically published once, then the v2 restore
/// journal owns physical publication and catalog/session commits.
final class LegacyArchiveRestore {
    private let catalog: WorkspaceCatalog
    private var library: LibraryStore { catalog.library }
    private let fm = FileManager.default
    init(catalog: WorkspaceCatalog) { self.catalog = catalog }

    @discardableResult func restore(from source: URL, into destination: URL, checkpoint: ((String) throws -> Void)? = nil) throws -> [WorkspaceItem] {
        try library.checkWritable()
        let inspected = try inspect(source)
        let cacheRoot = library.rootURL.appendingPathComponent("legacy-archive-conversions/" + inspected.fingerprint, isDirectory: true)
        try fm.createDirectory(at: cacheRoot, withIntermediateDirectories: true)
        // Concurrent attempts must share one conversion and one destination journal.
        let lock = open(cacheRoot.appendingPathComponent(".conversion.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lock >= 0 else { throw LibraryError.message("旧备份转换锁无法打开。") }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else { throw LibraryError.message("此旧备份正在恢复，请等待当前操作结束。") }
        defer { flock(lock, LOCK_UN) }
        let prepared = cacheRoot.appendingPathComponent("prepared", isDirectory: true)
        if !fm.fileExists(atPath: prepared.path) {
            let stage = cacheRoot.appendingPathComponent("preparing-" + UUID().uuidString, isDirectory: true)
            try fm.createDirectory(at: stage, withIntermediateDirectories: false)
            let frozen = stage.appendingPathComponent("source.uwaybackup", isDirectory: true)
            try fm.createDirectory(at: frozen, withIntermediateDirectories: false)
            try inspected.manifestBytes.write(to: frozen.appendingPathComponent("manifest.json"), options: .atomic)
            for asset in inspected.manifest.attachments {
                let original = try LibraryStore.safeChild(asset.relativePath, under: source)
                let copy = try LibraryStore.safeChild(asset.relativePath, under: frozen)
                try fm.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.copyItem(at: original, to: copy)
                guard try LibraryStore.sha256(of: copy) == asset.sha256 else { throw LibraryError.message("旧备份复制期间附件改变，转换未提交。") }
            }
            guard try inspect(source).fingerprint == inspected.fingerprint else { throw LibraryError.message("旧备份在转换期间发生变化，请重新选择。") }
            // Existing v1 validation checks relationships, cloud references,
            // times and allowed attachments in this isolated library only.
            let isolated = try LibraryStore(rootURL: stage.appendingPathComponent("catalog"))
            let imported = try isolated.restoreBackup(from: frozen)
            guard let rootIndex = inspected.manifest.items.firstIndex(where: { $0.id == inspected.manifest.rootItemID }), imported.indices.contains(rootIndex) else { throw LibraryError.message("旧备份根对象缺失。") }
            let rootID = imported[rootIndex].id
            // v2 applies the visible restored suffix exactly once.
            try isolated.rename(id: rootID, title: inspected.manifest.items[rootIndex].title)
            _ = try isolated.organizeLegacyRoots(title: "旧备份资料")
            let converted = stage.appendingPathComponent("converted.ulbackup", isDirectory: true)
            try WorkspaceArchive(catalog: WorkspaceCatalog(library: isolated)).backup(itemID: rootID, to: converted)
            let receipt = LegacyArchiveConversionReceipt(sourceFingerprint: inspected.fingerprint, sourceManifestHash: inspected.manifestHash,
                attachmentHashes: inspected.attachmentHashes, convertedManifestHash: try LibraryStore.sha256(of: converted.appendingPathComponent("manifest.json")))
            try JSONEncoder().encode(receipt).write(to: stage.appendingPathComponent("conversion.json"), options: .atomic)
            try library.syncDirectory(stage)
            try fm.moveItem(at: stage, to: prepared)
            try library.syncDirectory(cacheRoot)
        }
        let receipt = try JSONDecoder().decode(LegacyArchiveConversionReceipt.self, from: Data(contentsOf: prepared.appendingPathComponent("conversion.json")))
        let converted = prepared.appendingPathComponent("converted.ulbackup")
        guard receipt.format == "ulecture-legacy-archive-conversion", receipt.version == 1,
              receipt.sourceFingerprint == inspected.fingerprint, receipt.sourceManifestHash == inspected.manifestHash,
              receipt.attachmentHashes == inspected.attachmentHashes,
              try LibraryStore.sha256(of: converted.appendingPathComponent("manifest.json")) == receipt.convertedManifestHash else { throw LibraryError.message("已准备的旧备份转换校验失败，未写入现有资料。") }
        let manifest = try JSONDecoder().decode(WorkspaceArchiveManifest.self, from: Data(contentsOf: converted.appendingPathComponent("manifest.json")))
        let archive = WorkspaceArchive(catalog: catalog)
        try archive.validate(manifest, at: converted)
        try checkpoint?("legacy-converted")
        // A crash after the v2 catalog commit but before this call returns is
        // already complete. Do not ask v2 to create a second restored copy.
        if let completed = try completedRestore(sourceHash: receipt.convertedManifestHash, snapshotID: manifest.snapshotID, destination: destination) { return completed }
        return try archive.restore(from: converted, into: destination, checkpoint: checkpoint)
    }

    private func completedRestore(sourceHash: String, snapshotID: String, destination: URL) throws -> [WorkspaceItem]? {
        let root = library.rootURL.appendingPathComponent("archive-restores")
        guard fm.fileExists(atPath: root.path) else { return nil }
        let target = destination.standardizedFileURL.resolvingSymlinksInPath().path
        for file in try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: nil) where file.pathExtension == "json" {
            let journal = try JSONDecoder().decode(LegacyArchiveJournalIdentity.self, from: Data(contentsOf: file))
            guard journal.sourceHash == sourceHash, journal.destination == target,
                  let commit = try library.record(collection: "workspace-restores", id: journal.id, as: LegacyArchiveRestoreCommit.self), commit.snapshotID == snapshotID else { continue }
            return try commit.itemIDs.map { id in
                guard let item = try library.item(id: id) else { throw LibraryError.message("已恢复对象后来被移除，未重复恢复或覆盖现有资料。") }
                return item
            }
        }
        return nil
    }

    private struct Inspected {
        var manifest: LibraryBackupManifest
        var manifestBytes: Data
        var manifestHash: String
        var attachmentHashes: [String: String]
        var fingerprint: String
    }
    private func inspect(_ source: URL) throws -> Inspected {
        let file = try LibraryStore.safeChild("manifest.json", under: source)
        let values = try file.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? .max) <= 256 * 1024 * 1024 else { throw LibraryError.message("旧备份清单无效或过大。") }
        let bytes = try Data(contentsOf: file), manifest = try JSONDecoder().decode(LibraryBackupManifest.self, from: bytes)
        guard manifest.format == "uway-portable-library", manifest.version == 1, !manifest.items.isEmpty,
              manifest.items.count <= 100_000, manifest.records.count <= 1_000_000, manifest.attachments.count <= 100_000 else { throw LibraryError.message("不支持此旧备份格式或规模。") }
        var hashes: [String: String] = [:]
        for asset in manifest.attachments {
            guard asset.relativePath.hasPrefix("attachments/"), hashes[asset.relativePath] == nil,
                  asset.sha256.count == 64, asset.sha256.allSatisfy(\.isHexDigit) else { throw LibraryError.message("旧备份附件清单无效或重复。") }
            let url = try LibraryStore.safeChild(asset.relativePath, under: source)
            let value = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard value.isRegularFile == true, Int64(value.fileSize ?? -1) == asset.byteCount,
                  try LibraryStore.sha256(of: url) == asset.sha256 else { throw LibraryError.message("旧备份附件缺失或校验失败。") }
            hashes[asset.relativePath] = asset.sha256
        }
        if let files = fm.enumerator(at: source, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isExecutableKey]) {
            for case let url as URL in files {
                let value = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isExecutableKey])
                guard value.isSymbolicLink != true, !(value.isRegularFile == true && value.isExecutable == true) else { throw LibraryError.message("旧备份含符号链接或可执行内容，已拒绝。") }
            }
        }
        func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        let manifestHash = hash(bytes)
        let identity = try JSONSerialization.data(withJSONObject: ["manifest": manifestHash, "attachments": hashes], options: [.sortedKeys])
        return Inspected(manifest: manifest, manifestBytes: bytes, manifestHash: manifestHash, attachmentHashes: hashes, fingerprint: hash(identity))
    }
}
