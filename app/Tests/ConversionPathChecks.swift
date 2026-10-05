import Foundation
import Darwin
import PDFKit

/// Runs the public preparation API using both spellings of macOS's per-user
/// temporary directory, including executable resources outside the job scope.
@main struct ConversionPathChecks {
    static func main() async throws {
        let source = URL(fileURLWithPath: CommandLine.arguments[1])
        let bundled = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let evidence = URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true)
        try FileManager.default.createDirectory(at: evidence, withIntermediateDirectories: true)
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("ulecture-conversion-alias-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        guard let pointer = realpath(temporary.path, nil) else { throw DocumentConversionError.persistence }
        let canonical = URL(fileURLWithPath: String(cString: pointer), isDirectory: true); free(pointer)
        guard temporary.path.hasPrefix("/var/folders/"), canonical.path.hasPrefix("/private/var/folders/") else { throw DocumentConversionError.invalidOutput }
        let resourceAlias = temporary.appendingPathComponent("resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resourceAlias, withIntermediateDirectories: true)
        for name in ["ul-pdfium", "libpdfium.dylib"] {
            try FileManager.default.copyItem(at: bundled.appendingPathComponent(name), to: resourceAlias.appendingPathComponent(name))
        }
        var checks: [String] = [], previous: PreparedDocument?
        func check(_ value: Bool, _ label: String) throws {
            guard value else { throw NSError(domain: "ConversionPathChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }; checks.append(label)
        }
        for (name, base) in [("foundation", temporary), ("canonical", canonical)] {
            let directory = base.appendingPathComponent(name)
            let prepared = try await DocumentPreparation.prepare(source: source, directory: directory, sourceLanguage: "en", resources: ConversionResources(directory: resourceAlias))
            try check(prepared.pages.count == 3 && PDFDocument(url: directory.appendingPathComponent("normalized.pdf"))?.pageCount == 3, "\(name) temporary path runs real helper normalization and extraction")
            try check(prepared.regions.contains { ($0.kind == "ocr" || $0.kind == "unprocessedImageText") && ($0.confidence ?? 0) >= 0.85 }, "\(name) temporary path includes reliable local OCR from the bitmap-only fixture")
            let policies = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).filter { $0.lastPathComponent.hasPrefix("process-") }
            try check(!policies.isEmpty && policies.allSatisfy { profile in
                guard let text = try? String(contentsOf: profile.appendingPathComponent("sandbox.sb"), encoding: .utf8) else { return false }
                return text.contains(canonical.appendingPathComponent(name).path) && text.contains(canonical.appendingPathComponent("resources").path) && text.contains("(deny network*)")
            }, "\(name) sandbox grants only corresponding canonical job/resource roots and retains network denial")
            if let previous {
                try check(previous.sourceHash == prepared.sourceHash && previous.regions.map(\.source) == prepared.regions.map(\.source), "both path spellings produce identical source hash and extracted text")
            }
            previous = prepared
            try FileManager.default.copyItem(at: directory, to: evidence.appendingPathComponent(name))
        }
        let report: [String: Any] = ["passed": true, "checks": checks, "temporaryPath": temporary.path, "canonicalPath": canonical.path, "resourceAlias": resourceAlias.path, "fixtureSHA256": documentHash(try Data(contentsOf: source)), "realProviderRequests": 0, "networkRequests": 0]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: evidence.appendingPathComponent("conversion-path-checks.json"))
        print("Passed \(checks.count) actual helper/OCR path checks")
    }
}
