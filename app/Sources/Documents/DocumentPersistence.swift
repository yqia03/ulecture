import Foundation
import CryptoKit
import Darwin

enum DocumentFailure: LocalizedError {
    case message(String)
    case conflict
    case invalidFormat
    case missingResource(String)
    var errorDescription: String? {
        switch self {
        case .message(let value): return value
        case .conflict: return "The file changed outside this editor. Your draft is retained; reload or save a separate copy."
        case .invalidFormat: return "This document is damaged or uses an unsupported format. The original has not been changed."
        case .missingResource(let value): return "A document resource is missing: \(value)"
        }
    }
}

enum DocumentDisk {
    private static let locksGuard = NSLock()
    private static var locks: [String: NSRecursiveLock] = [:]
    static func serialLock(for url: URL) -> NSRecursiveLock {
        locksGuard.lock(); defer { locksGuard.unlock() }
        let key = url.standardizedFileURL.resolvingSymlinksInPath().path
        if let existing = locks[key] { return existing }
        let value = NSRecursiveLock(); locks[key] = value; return value
    }
    static func hash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
    static func hash(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var digest = SHA256()
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty { digest.update(data: data) }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func child(_ path: String, in root: URL) throws -> URL {
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard !path.isEmpty, !path.contains("\\"), !path.contains("\0"), components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }) else { throw DocumentFailure.invalidFormat }
        let base = root.standardizedFileURL.resolvingSymlinksInPath()
        let url = base.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(base.path + "/"), url.resolvingSymlinksInPath().path == url.path else { throw DocumentFailure.invalidFormat }
        return url
    }
    static func writableDirectory(_ url: URL, create: Bool = false) throws {
        let fm = FileManager.default
        if create, !fm.fileExists(atPath: url.path) { try fm.createDirectory(at: url, withIntermediateDirectories: true) }
        let attributes = try fm.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory,
              fm.isWritableFile(atPath: url.path), ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o222 != 0 else {
            throw DocumentFailure.message("The document folder is not writable. Your changes have not been saved.")
        }
    }
    static func syncDirectory(_ url: URL) throws {
        let fd = open(url.path, O_RDONLY | O_DIRECTORY)
        guard fd >= 0 else { throw DocumentFailure.message("The document folder is unavailable.") }
        defer { close(fd) }
        guard fsync(fd) == 0 else { throw DocumentFailure.message("The document folder could not be synchronized.") }
    }
    static func write(_ data: Data, to destination: URL, replace: Bool = true) throws {
        let parent = destination.deletingLastPathComponent()
        try writableDirectory(parent)
        guard destination.standardizedFileURL.resolvingSymlinksInPath() == destination.standardizedFileURL else { throw DocumentFailure.invalidFormat }
        if !replace, FileManager.default.fileExists(atPath: destination.path) { throw CocoaError(.fileWriteFileExists) }
        let temporary = parent.appendingPathComponent(".ul-write-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try data.write(to: temporary, options: .withoutOverwriting)
        if replace, FileManager.default.fileExists(atPath: destination.path) {
            let attributes = try FileManager.default.attributesOfItem(atPath: destination.path)
            guard attributes[.type] as? FileAttributeType == .typeRegular, ((attributes[.posixPermissions] as? NSNumber)?.intValue ?? 0) & 0o222 != 0 else { throw DocumentFailure.message("The document is read-only. Save a separate copy.") }
            guard copyfile(destination.path, temporary.path, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        let handle = try FileHandle(forWritingTo: temporary); try handle.synchronize(); try handle.close()
        if replace {
            guard rename(temporary.path, destination.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        } else {
            // link is an atomic, no-overwrite publication on the destination volume.
            guard link(temporary.path, destination.path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        }
        try syncDirectory(parent)
    }
    static func json<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(value)
    }
    static func read<T: Decodable>(_ type: T.Type, from url: URL) throws -> T {
        guard (try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])).isRegularFile == true,
              (try url.resourceValues(forKeys: [.isSymbolicLinkKey])).isSymbolicLink != true else { throw DocumentFailure.invalidFormat }
        return try JSONDecoder().decode(type, from: Data(contentsOf: url))
    }
}

struct DocumentPageLink: Codable, Equatable, Identifiable {
    var id: String = UUID().uuidString
    var documentID: String
    var page: Int
    var label: String
    var sourceHash: String? = nil
    static func parse(_ url: URL) -> DocumentPageLink? {
        guard ["ulecture-document", "uway-pdf"].contains(url.scheme?.lowercased() ?? ""), let id = url.host, !id.isEmpty else { return nil }
        let values = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard let pageText = values.first(where: { $0.name == "page" })?.value, let page = Int(pageText), page > 0 else { return nil }
        return DocumentPageLink(documentID: id, page: page, label: id, sourceHash: values.first { $0.name == "version" }?.value)
    }
    var url: URL? {
        var parts = URLComponents(); parts.scheme = "ulecture-document"; parts.host = documentID
        parts.queryItems = [URLQueryItem(name: "page", value: String(page))]
        if let sourceHash { parts.queryItems?.append(URLQueryItem(name: "version", value: sourceHash)) }
        return parts.url
    }
}

struct DocumentSelection: Equatable {
    var documentID: String
    var text: String
    var sourceHash: String? = nil
    var page: Int? = nil
    var blockID: String? = nil
    var revision: Int? = nil
}
