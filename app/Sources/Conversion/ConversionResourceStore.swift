import Foundation
import CryptoKit
import Darwin

struct ConversionIntegrityManifest: Codable {
    var schema: Int
    var files: [Entry]
    struct Entry: Codable { var path: String; var sha256: String?; var bytes: Int?; var link: String? }
}
struct ConversionResourceReceipt: Codable, Equatable {
    var manifestID: String
    var directory: String
    var verifiedAt: Date
}
enum ConversionResourceFailure: String, Error { case missingManifest, damagedResource, incompatibleSource, invalidPath, persistence }

/// Repair only copies a complete, exact build from a user-selected local app.
/// The trusted tree manifest stays outside Conversion in the signed app bundle.
struct ConversionResourceStore {
    let bundledRoot: URL
    let manifestURL: URL
    let managedRoot: URL
    static var defaultManagedRoot: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("UwayClassroom/ConversionRepairs", isDirectory: true)
    }
    static var standard: Self {
        let root = Bundle.main.resourceURL!
        return Self(bundledRoot: root.appendingPathComponent("Conversion"), manifestURL: root.appendingPathComponent("ConversionIntegrity.json"), managedRoot: defaultManagedRoot)
    }
    var manifestID: String? { (try? String(contentsOf: manifestURL.deletingPathExtension().appendingPathExtension("id"), encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) }
    var effectiveRoot: URL {
        guard let identifier = manifestID, identifier.count == 64,
              let data = try? Data(contentsOf: managedRoot.appendingPathComponent("active.json")), data.count <= 4096,
              let receipt = try? JSONDecoder().decode(ConversionResourceReceipt.self, from: data),
              receipt.manifestID == identifier, UUID(uuidString: receipt.directory) != nil else { return bundledRoot }
        let root = managedRoot.appendingPathComponent(receipt.directory, isDirectory: true)
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == false,
              FileManager.default.fileExists(atPath: root.path) else { return bundledRoot }
        return root
    }
    func loadManifest() throws -> (ConversionIntegrityManifest, String) {
        guard let identifier = manifestID, let data = try? Data(contentsOf: manifestURL), data.count <= 16_000_000,
              documentHash(data) == identifier, let manifest = try? JSONDecoder().decode(ConversionIntegrityManifest.self, from: data),
              manifest.schema == 1, !manifest.files.isEmpty, manifest.files.count <= 100_000,
              Set(manifest.files.map(\.path)).count == manifest.files.count else { throw ConversionResourceFailure.missingManifest }
        return (manifest, identifier)
    }
    func verify(_ root: URL, progress: @Sendable (Double) -> Void = { _ in }) throws -> String {
        let (manifest, identifier) = try loadManifest()
        // Foundation may present /private/tmp as /tmp while enumeration returns
        // /private/tmp. POSIX realpath gives one identity for containment checks.
        guard let rootPath = Self.canonicalPath(root.path) else { throw ConversionResourceFailure.damagedResource }
        let normalized = URL(fileURLWithPath: rootPath, isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: normalized, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey]) else { throw ConversionResourceFailure.damagedResource }
        var actual = Set<String>()
        for case let file as URL in walker {
            try Task.checkCancellation()
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true || values.isSymbolicLink == true { actual.insert(String(file.path.dropFirst(normalized.path.count + 1))) }
        }
        guard actual == Set(manifest.files.map(\.path)) else { throw ConversionResourceFailure.damagedResource }
        for (index, entry) in manifest.files.enumerated() {
            try Task.checkCancellation()
            guard !entry.path.hasPrefix("/"), !entry.path.components(separatedBy: "/").contains(where: { $0 == ".." || $0.isEmpty }) else { throw ConversionResourceFailure.invalidPath }
            let file = normalized.appendingPathComponent(entry.path)
            guard Self.canonicalPath(file.path)?.hasPrefix(normalized.path + "/") == true else { throw ConversionResourceFailure.invalidPath }
            let values = try? file.resourceValues(forKeys: [.isSymbolicLinkKey, .fileSizeKey, .isRegularFileKey])
            if let link = entry.link {
                guard values?.isSymbolicLink == true, (try? FileManager.default.destinationOfSymbolicLink(atPath: file.path)) == link else { throw ConversionResourceFailure.damagedResource }
            } else {
                guard values?.isSymbolicLink == false, values?.isRegularFile == true, values?.fileSize == entry.bytes, let hash = entry.sha256 else { throw ConversionResourceFailure.damagedResource }
                let handle = try FileHandle(forReadingFrom: file); defer { try? handle.close() }
                var digest = SHA256()
                while let bytes = try handle.read(upToCount: 1_048_576), !bytes.isEmpty { try Task.checkCancellation(); digest.update(data: bytes) }
                guard digest.finalize().map({ String(format: "%02x", $0) }).joined() == hash else { throw ConversionResourceFailure.damagedResource }
            }
            if index % 32 == 0 { progress(Double(index + 1) / Double(manifest.files.count)) }
        }
        guard FileManager.default.isExecutableFile(atPath: normalized.appendingPathComponent("ul-pdfium").path),
              FileManager.default.isExecutableFile(atPath: normalized.appendingPathComponent("LibreOffice.app/Contents/MacOS/soffice").path) else { throw ConversionResourceFailure.damagedResource }
        progress(1); return identifier
    }
    func repair(from application: URL, progress: @Sendable (Double) -> Void = { _ in }) throws -> ConversionResourceReceipt {
        let source = application.appendingPathComponent("Contents/Resources/Conversion", isDirectory: true)
        let identifier: String
        do { identifier = try verify(source, progress: { progress($0 * 0.4) }) }
        catch is CancellationError { throw CancellationError() }
        catch { throw ConversionResourceFailure.incompatibleSource }
        try FileManager.default.createDirectory(at: managedRoot, withIntermediateDirectories: true)
        let name = UUID().uuidString, staging = managedRoot.appendingPathComponent(name, isDirectory: true)
        var published = false
        defer { if !published { try? FileManager.default.removeItem(at: staging) } }
        try Task.checkCancellation()
        try FileManager.default.copyItem(at: source, to: staging)
        try Task.checkCancellation()
        _ = try verify(staging, progress: { progress(0.4 + $0 * 0.6) })
        let receipt = ConversionResourceReceipt(manifestID: identifier, directory: name, verifiedAt: Date())
        try Task.checkCancellation()
        try JSONEncoder().encode(receipt).write(to: managedRoot.appendingPathComponent("active.json"), options: .atomic)
        published = true
        // Older verified trees remain available; repair never deletes them.
        return receipt
    }
    private static func canonicalPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }; return String(cString: resolved)
    }
}
