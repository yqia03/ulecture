import Foundation
import PDFKit

@main struct ConversionRepairChecks {
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let application = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let fixture = URL(fileURLWithPath: CommandLine.arguments[3])
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        var checks: [String] = []
        func check(_ value: Bool, _ label: String) throws { guard value else { throw NSError(domain: "ConversionRepairChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }; checks.append(label) }
        let damaged = directory.appendingPathComponent("damaged-bundle"), managed = directory.appendingPathComponent("managed")
        try FileManager.default.createDirectory(at: damaged, withIntermediateDirectories: true)
        let store = ConversionResourceStore(bundledRoot: damaged, manifestURL: directory.appendingPathComponent("ConversionIntegrity.json"), managedRoot: managed)
        try check(store.effectiveRoot == damaged && !FileManager.default.fileExists(atPath: managed.path), "construction and unresolved default do not install, download or select managed resources")
        do { _ = try store.verify(damaged); throw DocumentConversionError.invalidOutput } catch ConversionResourceFailure.damagedResource { checks.append("missing conversion resources fail real manifest verification") }
        let source = application.appendingPathComponent("Contents/Resources/Conversion")
        let identifier = try store.verify(source)
        try check(identifier == store.manifestID, "complete real bundled PDFium and LibreOffice tree matches the fixed build manifest")
        let receipt = try await Task.detached { try store.repair(from: application) }.value
        try check(receipt.manifestID == identifier && store.effectiveRoot.path == managed.appendingPathComponent(receipt.directory).path && FileManager.default.fileExists(atPath: source.appendingPathComponent("ul-pdfium").path), "explicit local repair verifies a complete copy and atomically selects it while preserving the original app")
        _ = try store.verify(store.effectiveRoot)
        let reading = try await DocumentPreparation.prepareForReading(source: fixture, cacheDirectory: directory.appendingPathComponent("reading"), resources: ConversionResources(directory: store.effectiveRoot))
        let pdf = PDFDocument(url: reading.pdfURL)
        try check(pdf?.pageCount == 1 && pdf?.string?.contains("日本語") == true && pdf?.string?.contains("中文") == true && pdf?.string?.contains("Practice") == true, "repaired resources execute real slide conversion with readable Japanese Chinese and Latin text")
        let active = managed.appendingPathComponent("active.json"), previous = try Data(contentsOf: active)
        let invalid = directory.appendingPathComponent("wrong.app"); try FileManager.default.createDirectory(at: invalid, withIntermediateDirectories: true)
        do { _ = try store.repair(from: invalid); throw DocumentConversionError.invalidOutput } catch ConversionResourceFailure.incompatibleSource { }
        try check(try Data(contentsOf: active) == previous, "incompatible local repair source cannot replace a previously verified resource selection")
        let cancelled = Task.detached { try Task.checkCancellation(); return try store.repair(from: application) }
        cancelled.cancel()
        do { _ = try await cancelled.value; throw DocumentConversionError.invalidOutput } catch is CancellationError { }
        try check(try Data(contentsOf: active) == previous, "cancelled repair leaves the active receipt and previous resources unchanged")
        let repaired = store.effectiveRoot, tampered = repaired.appendingPathComponent("ul-pdfium")
        let original = try Data(contentsOf: tampered); try Data("damaged fixture".utf8).write(to: tampered)
        do { _ = try store.verify(repaired); throw DocumentConversionError.invalidOutput } catch ConversionResourceFailure.damagedResource { }
        try original.write(to: tampered)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tampered.path)
        try check(try store.verify(repaired) == identifier, "post-install damage is detected by bytes and a restored exact component passes again")
        let report: [String: Any] = ["passed": true, "checks": checks, "manifestID": identifier, "managedDirectory": repaired.path, "convertedPDF": reading.pdfURL.path, "realProviderRequests": 0, "networkDownloads": 0, "globalInstalls": 0]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("conversion-repair-checks.json"))
        print("Passed \(checks.count) real local converter repair checks")
    }
}
