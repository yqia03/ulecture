import Foundation

/// Only a completely copied and re-read tree reaches its public destination. An interrupted
/// private copy remains available for inspection; retries create a new private copy.
enum VerifiedMigrationCopy {
    static func copy(_ source: URL, to destination: URL, expected: [String: String]? = nil) throws {
        let fm = FileManager.default
        let hashes = try expected ?? WorkspaceCatalog.manifest(source)
        guard try WorkspaceCatalog.manifest(source) == hashes else { throw LibraryError.message("迁移暂存副本有变化，尚未提交。") }
        if fm.fileExists(atPath: destination.path) {
            guard try WorkspaceCatalog.manifest(destination) == hashes else { throw LibraryError.message("目标有同名内容，未覆盖；请处理冲突后继续迁移。") }
            return
        }
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        let stage = destination.deletingLastPathComponent().appendingPathComponent(".ulecture-migration-copy-" + UUID().uuidString)
        try fm.copyItem(at: source, to: stage)
        guard try WorkspaceCatalog.manifest(stage) == hashes, try WorkspaceCatalog.manifest(source) == hashes else { throw LibraryError.message("迁移复制校验失败。") }
        try fm.moveItem(at: stage, to: destination)
    }
}
