import Foundation
import PDFKit

@main struct ConversionChecks {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let fixture = root.appendingPathComponent("app/Tests/Fixtures/Conversion")
        let evidence = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true)
        let packagedResources = CommandLine.arguments.count > 3 ? URL(fileURLWithPath: CommandLine.arguments[3], isDirectory: true) : nil
        var resources = ConversionResources(directory: packagedResources ?? root.appendingPathComponent("app/build/conversion"))
        if packagedResources == nil { resources.libreOffice = root.appendingPathComponent("app/Dependencies/libreoffice-26.8.0/LibreOffice.app/Contents/MacOS/soffice") }
        if !FileManager.default.fileExists(atPath: fixture.appendingPathComponent("lesson.ppt").path) {
            let profile = fixture.appendingPathComponent("binary-ppt-profile")
            try FileManager.default.createDirectory(at: profile, withIntermediateDirectories: true)
            try await ConversionProcess.run(resources.libreOffice, arguments: ["-env:UserInstallation=" + profile.absoluteString, "--headless", "--convert-to", "ppt:MS PowerPoint 97", "--outdir", fixture.path, fixture.appendingPathComponent("lesson.pptx").path], directory: fixture, resources: [resources.libreOffice.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent(), evidence])
        }
        let prepared = try await DocumentPreparation.prepare(source: fixture.appendingPathComponent("complex.pdf"), directory: evidence.appendingPathComponent("pdf"), sourceLanguage: "en", resources: resources)
        print("PDF pages=\(prepared.pages.count) regions=\(prepared.regions.count) OCR=\(prepared.regions.filter { $0.kind == "ocr" }.count)")
        try JSONEncoder().encode(prepared.pages).write(to: evidence.appendingPathComponent("pages.json"), options: .atomic)
        try JSONEncoder().encode(prepared.regions).write(to: evidence.appendingPathComponent("regions.json"), options: .atomic)
        let reading = try await DocumentPreparation.prepareForReading(source: fixture.appendingPathComponent("lesson.pptx"), cacheDirectory: evidence.appendingPathComponent("reading"), resources: resources)
        guard let slides = PDFDocument(url: reading.pdfURL), slides.pageCount == 1, slides.string?.contains("Working") == true, slides.string?.contains("日本語") == true, slides.string?.contains("中文") == true else { throw DocumentConversionError.invalidOutput }
        print("PPTX pages=\(slides.pageCount) output=\(reading.pdfURL.path)")
    }
}
