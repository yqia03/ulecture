import Foundation
import CoreGraphics
import CryptoKit
import Darwin

enum DocumentConversionError: String, Error, LocalizedError {
    case resourcesMissing, babelDOCMissing, babelDOCScannedNeedsNative, unsupported, invalidDocument, encrypted, tooLarge, conversionFailed, timedOut, cancelled, noText, persistence, invalidOutput, incompatibleCheckpoint
    var errorDescription: String? { rawValue }
}
struct ConversionResources {
    static let readingCacheVersion = "lo26.8.0.3-layout2"
    private var directoryOverride: URL?
    private var libreOfficeOverride: URL?
    private var root: URL { directoryOverride ?? ConversionResourceStore.standard.effectiveRoot }
    var helper: URL { get { root.appendingPathComponent("ul-pdfium") } set { directoryOverride = newValue.deletingLastPathComponent() } }
    var libreOffice: URL { get { libreOfficeOverride ?? root.appendingPathComponent("LibreOffice.app/Contents/MacOS/soffice") } set { libreOfficeOverride = newValue } }
    init(directory: URL? = nil) {
        directoryOverride = directory
    }
    func frozen() -> Self { var value = Self(directory: root); value.libreOfficeOverride = libreOffice; return value }
    var pdfReady: Bool { FileManager.default.isExecutableFile(atPath: helper.path) && FileManager.default.fileExists(atPath: helper.deletingLastPathComponent().appendingPathComponent("libpdfium.dylib").path) }
    var slidesReady: Bool { FileManager.default.isExecutableFile(atPath: libreOffice.path) }
}

/// Child conversion processes receive a fresh private profile and an explicit
/// environment. The seatbelt denies network and limits filesystem access to
/// runtime resources, system libraries/fonts and the disposable job folder.
enum ConversionProcess {
    @discardableResult static func run(_ executable: URL, arguments: [String], directory: URL, resources: [URL], timeout: TimeInterval = 120, maximumOutputBytes: Int = 32_000_000) async throws -> Data {
        try Task.checkCancellation()
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw DocumentConversionError.resourcesMissing }
        let profile = directory.appendingPathComponent("process-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
        // LibreOffice's single-instance guard uses a UNIX socket even in
        // headless mode. Keep its pathname below sockaddr_un's 104-byte limit.
        let socketDirectory = URL(fileURLWithPath: "/private/tmp/ulc-" + String(UUID().uuidString.prefix(8)), isDirectory: true)
        try FileManager.default.createDirectory(at: socketDirectory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: socketDirectory) }
        let output = profile.appendingPathComponent("output.log"), errors = profile.appendingPathComponent("error.log")
        FileManager.default.createFile(atPath: output.path, contents: nil); FileManager.default.createFile(atPath: errors.path, contents: nil)
        let out = try FileHandle(forWritingTo: output), err = try FileHandle(forWritingTo: errors)
        defer { try? out.close(); try? err.close() }
        func quoted(_ path: String) -> String { "\"" + path.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\"" }
        func pathAliases(_ url: URL) -> [String] {
            var paths = [url.path, url.resolvingSymlinksInPath().path]
            // Foundation can preserve /var/folders even though seatbelt sees
            // /private/var/folders. Resolve existing roots through the kernel
            // without expanding the allowed scope beyond the same directory.
            if let resolved = realpath(url.path, nil) {
                paths.append(String(cString: resolved)); free(resolved)
            }
            return Array(Set(paths)).sorted()
        }
        let directoryPaths = Array(Set(pathAliases(directory) + pathAliases(socketDirectory))).sorted()
        let roots = resources.flatMap(pathAliases) + directoryPaths + ["/System", "/usr", "/Library/Fonts", "/Library/Apple", "/private/var/db", "/private/preboot", "/dev"]
        let readRules = "(literal \"/\") " + roots.map { "(subpath " + quoted($0) + ")" }.joined(separator: " ")
        let writeRules = directoryPaths.map { "(subpath " + quoted($0) + ")" }.joined(separator: " ")
        let rules = "(version 1)\n(deny default)\n(allow process*)\n(allow sysctl-read)\n(allow mach-lookup)\n(allow ipc-posix*)\n(allow file-map-executable)\n(allow file-read-metadata)\n(allow file-read* \(readRules))\n(allow file-write* \(writeRules))\n(deny network*)\n(allow network* (local unix-socket))\n"
        let policy = profile.appendingPathComponent("sandbox.sb"); try Data(rules.utf8).write(to: policy, options: .atomic)
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        let scopedArguments = executable.lastPathComponent == "soffice" ? ["-env:OSL_SOCKET_PATH=" + socketDirectory.path] + arguments : arguments
        process.arguments = ["-f", policy.path, executable.path] + scopedArguments
        process.currentDirectoryURL = directory
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": profile.path, "TMPDIR": profile.path, "LANG": "en_US.UTF-8", "PYTHONDONTWRITEBYTECODE": "1"]
        if executable.lastPathComponent == "soffice" {
            // The headless backend uses Fontconfig even on macOS. Its empty
            // default configuration otherwise discovers only bundled Latin
            // fonts and silently loses CJK glyphs. Reference system fonts in
            // place; never copy or redistribute Apple's font files.
            func xml(_ value: String) -> String { value.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;").replacingOccurrences(of: ">", with: "&gt;") }
            let bundledFonts = executable.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/fonts/truetype")
            let fontConfig = profile.appendingPathComponent("fonts.conf")
            let content = "<?xml version=\"1.0\"?><!DOCTYPE fontconfig SYSTEM \"fonts.dtd\"><fontconfig><dir>/System/Library/Fonts</dir><dir>/Library/Fonts</dir><dir>" + xml(bundledFonts.path) + "</dir><cachedir>" + xml(profile.appendingPathComponent("font-cache").path) + "</cachedir></fontconfig>"
            try Data(content.utf8).write(to: fontConfig, options: .atomic)
            process.environment?["FONTCONFIG_FILE"] = fontConfig.path
            process.environment?["FONTCONFIG_PATH"] = profile.path
        }
        process.standardOutput = out; process.standardError = err
        try process.run(); let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning {
            let outputSize = ((try? output.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) + ((try? errors.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
            if Task.isCancelled || Date() >= deadline || outputSize > maximumOutputBytes {
                process.terminate()
                await Task.detached {
                    for _ in 0..<20 where process.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
                }.value
                if process.isRunning { kill(process.processIdentifier, SIGKILL) }
                await Task.detached {
                    for _ in 0..<20 where process.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
                }.value
                if Task.isCancelled { throw CancellationError() }
                if outputSize > maximumOutputBytes { throw DocumentConversionError.tooLarge }
                throw DocumentConversionError.timedOut
            }
            try? await Task.sleep(nanoseconds: 30_000_000)
        }
        guard process.terminationStatus == 0 else {
            let message = (try? String(contentsOf: errors, encoding: .utf8)) ?? ""
            if message.contains("pdfLoad:4") { throw DocumentConversionError.encrypted }
            throw DocumentConversionError.conversionFailed
        }
        let bytes = try Data(contentsOf: output)
        guard bytes.count <= maximumOutputBytes else { throw DocumentConversionError.tooLarge }
        return bytes
    }
}

struct PDFiumLayout: Codable {
    var schema: Int
    var engine: String
    var pages: [Page]
    struct Page: Codable { var number: Int; var width: Double; var height: Double; var rotation: Int; var objects: [Object] }
    struct Object: Codable { var id: String; var text: String; var bounds: [Double]; var fontSize: Double; var rgba: [Double]; var angle: Double; var fontName: String? }
}
struct DocumentRegion: Codable, Equatable, Identifiable {
    var id: String
    var page: Int
    var objectIDs: [String]
    var source: String
    var bounds: CGRect
    var fontSize: Double
    var color: [Double]
    var angle: Double = 0
    var kind: String = "text"
    var confidence: Double? = nil
    var background: [Double]? = nil
    var translation: String? = nil
    var dispatches: [CloudDispatch] = []
    var error: String? = nil
    var isTranslatable: Bool { kind == "text" || kind == "ocr" }
}
struct DocumentPageLayout: Codable, Equatable, Identifiable {
    var number: Int
    var width: Double
    var height: Double
    var regionIDs: [String]
    var warnings: [String] = []
    var rasterDPI: Int? = nil
    var rasterReason: String? = nil
    var id: Int { number }
}
struct DocumentProcessingVersion: Codable, Equatable {
    var prompt: String
    var pdfium: String
    var slides: String
    var ocr: String
    var layout: String
    var operatingSystem: String
    static var current: Self { Self(prompt: "document-translation-1", pdfium: "153.0.7999.0-e9fc018", slides: "26.8.0.3-bce0998", ocr: "Vision-text-revision3", layout: "2026-10-01.2", operatingSystem: ProcessInfo.processInfo.operatingSystemVersionString) }
}
struct DocumentTranslationMapping: Codable, Equatable {
    var sourcePage: Int
    var outputPages: [Int]
    var regionIDs: [String]
}

enum DocumentOutputMode: String, Codable, CaseIterable { case translated, bilingual }
enum DocumentTranslationEngine: String, Codable, CaseIterable { case native, babelDOC }
enum DocumentTaskStatus: String, Codable { case preparing, translating, rendering, completed, partial, failed, cancelled, interrupted }
struct DocumentTranslationJob: Codable, Identifiable {
    var id: String = UUID().uuidString
    var title: String
    var sourceExtension: String
    var sourceHash: String = ""
    var sourceLanguage: String
    var targetLanguage: String
    var mode: DocumentOutputMode
    var domain: TranslationDomain
    var glossaryRevision: Int
    var terms: [TranslationTerm]
    var status: DocumentTaskStatus = .preparing
    var pages: [DocumentPageLayout] = []
    var regions: [DocumentRegion] = []
    var mapping: [DocumentTranslationMapping] = []
    var warnings: [String] = []
    var error: String? = nil
    var slideNotes: [DocumentSlideNote]? = nil
    var fontReports: [DocumentFontReport]? = nil
    var scopeID: String? = nil
    var createdAt: Date = Date()
    var layoutVersion = "2026-10-01.2"
    var processingVersion: DocumentProcessingVersion? = .current
    var outputName: String? = nil
    var companionName: String? = nil
    // Optional fields keep saved native jobs decodable without reinterpreting
    // their checkpoints as a different translation engine.
    var engine: DocumentTranslationEngine? = nil
    var engineProgress: Double? = nil
    var engineStage: String? = nil
    var engineDispatches: [CloudDispatch]? = nil
    var engineVersion: String? = nil
    var effectiveEngine: DocumentTranslationEngine { engine ?? .native }
    var completedCount: Int { regions.filter { $0.isTranslatable && $0.translation != nil }.count }
    var totalCount: Int { regions.filter(\.isTranslatable).count }
}

func documentHash(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
