import Foundation
import Darwin

extension WorkspaceCatalog {
    /// Foundation's standardized URLs can choose /tmp or /private/tmp differently before and after
    /// directory creation. POSIX realpath provides a stable comparison identity for existing parents.
    static func canonicalURL(_ url: URL) -> URL {
        if let path = realpath(url.path, nil) { defer { free(path) }; return URL(fileURLWithPath: String(cString: path)) }
        let parent = url.deletingLastPathComponent()
        guard parent.path != url.path else { return url }
        return canonicalURL(parent).appendingPathComponent(url.lastPathComponent)
    }
}
