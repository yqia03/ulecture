import Foundation
import PDFKit
import Darwin

@main struct BabelDOCRealBridgeChecks {
    @MainActor static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let resources = BabelDOCResources(directory: URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true))
        let endpoint = CommandLine.arguments[3]
        let source = URL(fileURLWithPath: CommandLine.arguments[4])
        let fm = FileManager.default
        try fm.createDirectory(at: output, withIntermediateDirectories: true)
        let suite = "ulecture.babeldoc.real-bridge." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = FeatureCredentials()
        let config = CloudConfiguration(provider: .openAICompatible, model: "fixture-swift-selected-model", baseURL: endpoint)
        let settings = CloudServiceSettings(initialConfiguration: config, credentials: credentials, defaults: defaults, scope: "documentTranslation")
        let secret = "swift-bridge-fixture-" + UUID().uuidString
        try settings.saveCredential(secret)
        let authorization = try settings.authorize()
        var checks: [String] = []
        func check(_ value: @autoclosure () -> Bool, _ label: String) throws {
            guard value() else { throw NSError(domain: "BabelDOCRealBridgeChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            checks.append(label)
        }
        try check(resources.ready, "real bundled Python, worker and manifest are present")
        try check(authorization.dispatch.configuration.credentialScope == "documentTranslation", "real bridge authorization uses isolated document credential scope")
        var usage: [[String: Any]] = []
        for mode in DocumentOutputMode.allCases {
            let folder = output.appendingPathComponent(mode.rawValue, isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
            var job = DocumentTranslationJob(title: "Real bridge regression", sourceExtension: "pdf", sourceLanguage: "en", targetLanguage: "zh-Hans", mode: mode, domain: .general, glossaryRevision: 1, terms: [TranslationTerm(source: "Working memory", translation: "工作记忆", note: "Use this exact course term.")])
            job.engine = .babelDOC
            var progress: [(Double, String)] = [], groups = Set<pid_t>()
            let result = try await BabelDOCBridge.translate(inputPDF: source, directory: folder, job: job, authorization: authorization, resources: resources) { value, stage in
                progress.append((value, stage))
                if groups.isEmpty {
                    let process = Process(), pipe = Pipe()
                    process.executableURL = URL(fileURLWithPath: "/bin/ps")
                    process.arguments = ["-axo", "pid=,command="]
                    process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
                    try process.run()
                    let bytes = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
                    for line in String(decoding: bytes, as: UTF8.self).split(separator: "\n") where line.contains(resources.worker.path) {
                        if let first = line.split(whereSeparator: \.isWhitespace).first, let pid = Int32(first), getpgid(pid) == pid { groups.insert(pid) }
                    }
                }
            }
            guard let pdf = PDFDocument(url: result.outputURL), let text = pdf.string else { throw DocumentConversionError.invalidOutput }
            try check(result.pageCount == (mode == .bilingual ? 4 : 2) && pdf.pageCount == result.pageCount, "\(mode.rawValue): real engine result passes Swift PDFKit page validation")
            try check(text.contains("工作记忆") && text.contains("学习成果"), "\(mode.rawValue): Swift reads actual translated Chinese from published PDF")
            try check((result.inputTokens ?? 0) > 0 && (result.outputTokens ?? 0) > 0, "\(mode.rawValue): actual local model usage crosses Python/Swift boundary")
            try check(progress.count > 3 && progress.allSatisfy { (0...1).contains($0.0) }, "\(mode.rawValue): verified ready handshake allows real pipeline progress")
            try check(!groups.isEmpty, "\(mode.rawValue): actual worker has a private process group")
            for group in groups {
                let until = Date().addingTimeInterval(4)
                while kill(-group, 0) == 0, Date() < until { try await Task.sleep(nanoseconds: 20_000_000) }
                try check(kill(-group, 0) == -1 && errno == ESRCH, "\(mode.rawValue): worker and multiprocessing helpers are gone after publication")
            }
            let remaining = try fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            try check(remaining.map(\.lastPathComponent) == ["translation.pdf"], "\(mode.rawValue): stripped-HOME cache, events and temporary input are cleaned up")
            usage.append(["mode": mode.rawValue, "inputTokens": result.inputTokens!, "outputTokens": result.outputTokens!, "progressEvents": progress.count])
        }
        func persistedSecret() throws -> Bool {
            let files = fm.enumerator(at: output, includingPropertiesForKeys: [.isRegularFileKey])!
            for case let file as URL in files where (try? file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                if try Data(contentsOf: file).range(of: Data(secret.utf8)) != nil { return true }
            }
            return false
        }
        let leaked = try persistedSecret()
        try check(!leaked, "secret never appears in persisted evidence or PDFs")
        let report: [String: Any] = ["passed": checks.count, "checks": checks, "usage": usage, "runtime": resources.directory.path, "realProviderRequests": 0]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: output.appendingPathComponent("results.json"))
        print("Real BabelDOC Swift bridge checks passed: \(checks.count)")
    }
}
