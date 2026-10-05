import Foundation
import PDFKit
import Darwin

struct BabelDOCResources {
    let directory: URL
    init(directory: URL? = nil) {
        if let directory { self.directory = directory }
        else if let packaged = Bundle.main.resourceURL?.appendingPathComponent("BabelDOC"), FileManager.default.fileExists(atPath: packaged.path) { self.directory = packaged }
        else { self.directory = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("app/Dependencies/babeldoc-runtime") }
    }
    var python: URL { directory.appendingPathComponent("runtime/bin/python3") }
    var worker: URL { directory.appendingPathComponent("worker.py") }
    var assets: URL { directory.appendingPathComponent("assets", isDirectory: true) }
    var ready: Bool {
        FileManager.default.isExecutableFile(atPath: python.path) &&
        FileManager.default.isReadableFile(atPath: worker.path) &&
        FileManager.default.isReadableFile(atPath: directory.appendingPathComponent("runtime-manifest.json").path)
    }
}

struct BabelDOCResult {
    var outputURL: URL
    var pageCount: Int
    var inputTokens: Int? = nil
    var outputTokens: Int? = nil
    var engineVersion: String = "0.6.4"
    var warnings: [String] = []
}

typealias BabelDOCTranslate = @MainActor (URL, URL, DocumentTranslationJob, CloudAuthorization, @escaping @MainActor (Double, String) throws -> Void) async throws -> BabelDOCResult

/// Runs the pinned engine in a separate process. The key crosses only an
/// anonymous stdin pipe; it is never included in argv, environment or job JSON.
enum BabelDOCBridge {
    static func baseURL(for configuration: CloudConfiguration) throws -> String {
        _ = try configuration.validated()
        switch configuration.provider {
        case .geminiDeveloper: return "https://generativelanguage.googleapis.com/v1beta/openai/"
        case .deepSeek: return "https://api.deepseek.com"
        case .openAI: return "https://api.openai.com/v1"
        case .openAICompatible: return configuration.resolvedBaseURL
        case .googleCloudStandard, .googleCloudExpress: throw CloudFailure.invalidConfiguration
        }
    }

    @MainActor static func translate(inputPDF: URL, directory: URL, job: DocumentTranslationJob, authorization: CloudAuthorization, resources: BabelDOCResources = .init(), onProgress: @escaping @MainActor (Double, String) throws -> Void) async throws -> BabelDOCResult {
        try Task.checkCancellation()
        guard resources.ready else { throw DocumentConversionError.babelDOCMissing }
        guard let input = PDFDocument(url: inputPDF), !input.isEncrypted, input.pageCount > 0 else { throw DocumentConversionError.invalidDocument }
        let fm = FileManager.default
        let runDirectory = directory.appendingPathComponent("babeldoc-" + UUID().uuidString, isDirectory: true)
        try fm.createDirectory(at: runDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: runDirectory) }
        let outputDirectory = runDirectory.appendingPathComponent("output", isDirectory: true)
        try fm.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
        let profile = runDirectory.appendingPathComponent("profile", isDirectory: true)
        try fm.createDirectory(at: profile, withIntermediateDirectories: true)
        let payload = try authorization.subprocessInput(parameters: [
            "schema": 1, "inputPDF": inputPDF.path, "outputDirectory": outputDirectory.path,
            "sourceLanguage": job.sourceLanguage, "targetLanguage": job.targetLanguage,
            "mode": job.mode.rawValue, "model": authorization.dispatch.preset.model,
            "baseURL": try baseURL(for: authorization.dispatch.configuration),
            "domain": job.domain.instruction,
            "terms": job.terms.map { ["source": $0.source, "translation": $0.translation, "note": $0.note] },
            "cacheDirectory": profile.appendingPathComponent("cache", isDirectory: true).path
        ])
        guard payload.count <= 2_000_000 else { throw DocumentConversionError.tooLarge }
        let eventFile = runDirectory.appendingPathComponent("events.jsonl")
        fm.createFile(atPath: eventFile.path, contents: nil, attributes: [.posixPermissions: 0o600])
        let eventWriter = try FileHandle(forWritingTo: eventFile), eventReader = try FileHandle(forReadingFrom: eventFile)
        defer { try? eventWriter.close(); try? eventReader.close() }
        let process = Process(), stdin = Pipe()
        process.executableURL = resources.python
        process.arguments = ["-I", "-B", "-u", resources.worker.path]
        process.currentDirectoryURL = runDirectory
        process.environment = ["PATH": "/usr/bin:/bin", "HOME": profile.path, "TMPDIR": profile.path, "LANG": "en_US.UTF-8", "PYTHONDONTWRITEBYTECODE": "1", "TOKENIZERS_PARALLELISM": "false", "OMP_NUM_THREADS": "2"]
        process.standardInput = stdin; process.standardOutput = eventWriter; process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw DocumentConversionError.babelDOCMissing }
        let workerPID = process.processIdentifier
        var ownedProcessGroup: pid_t?
        var processTreeStopped = false
        var inputWriter: Task<Void, Error>?
        var buffer = Data(), byteCount = 0, result: BabelDOCResult?, workerFailure: Error?
        var lastProgress = -1.0, lastStage = ""
        func readEvents() throws {
            let bytes = try eventReader.read(upToCount: 262_144) ?? Data()
            byteCount += bytes.count
            guard byteCount <= 4_000_000 else { throw DocumentConversionError.tooLarge }
            buffer.append(bytes)
            while let newline = buffer.firstIndex(of: 10) {
                let line = Data(buffer[..<newline]); buffer.removeSubrange(...newline)
                if line.isEmpty { continue }
                guard let object = try JSONSerialization.jsonObject(with: line) as? [String: Any], let type = object["type"] as? String else { throw DocumentConversionError.conversionFailed }
                switch type {
                case "ready":
                    guard object["processGroup"] as? Int == Int(workerPID), getpgid(workerPID) == workerPID else { throw DocumentConversionError.conversionFailed }
                    ownedProcessGroup = workerPID
                case "progress":
                    guard ownedProcessGroup != nil else { throw DocumentConversionError.conversionFailed }
                    let progress = min(1, max(0, object["progress"] as? Double ?? 0))
                    let stage = object["stage"] as? String ?? "translating"
                    guard ["preparing", "translating", "rendering"].contains(stage) else { continue }
                    if progress != lastProgress || stage != lastStage {
                        lastProgress = progress; lastStage = stage; try onProgress(progress, stage)
                    }
                case "result":
                    guard ownedProcessGroup != nil else { throw DocumentConversionError.conversionFailed }
                    guard let path = object["outputPath"] as? String else { throw DocumentConversionError.invalidOutput }
                    let url = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL
                    let outputRoot = outputDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
                    guard url.path.hasPrefix(outputRoot),
                          let size = try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize,
                          size > 0, size <= 512_000_000,
                          let pdf = PDFDocument(url: url), !pdf.isEncrypted, pdf.pageCount > 0 else { throw DocumentConversionError.invalidOutput }
                    let expectedPages = job.mode == .bilingual ? input.pageCount * 2 : input.pageCount
                    guard pdf.pageCount == expectedPages else { throw DocumentConversionError.invalidOutput }
                    result = BabelDOCResult(outputURL: url, pageCount: pdf.pageCount, inputTokens: object["inputTokens"] as? Int, outputTokens: object["outputTokens"] as? Int)
                case "error":
                    let code = object["code"] as? String ?? "conversionFailed"
                    workerFailure = CloudFailure(rawValue: code).map { $0 as Error } ?? DocumentConversionError(rawValue: code).map { $0 as Error } ?? DocumentConversionError.conversionFailed
                default: throw DocumentConversionError.conversionFailed
                }
            }
        }
        func stop() async {
            guard !processTreeStopped else { return }
            processTreeStopped = true
            // Before the handshake, the worker may already have created its
            // private session. Never signal an inherited or unverified group.
            if ownedProcessGroup == nil, process.isRunning, getpgid(workerPID) == workerPID { ownedProcessGroup = workerPID }
            let group = ownedProcessGroup
            if let group { kill(-group, SIGTERM) }
            else if process.isRunning { process.terminate() }
            await Task.detached {
                if let group {
                    // Multiprocessing helpers can outlive their leader and
                    // ignore SIGTERM. Group ownership survives leader exit.
                    for _ in 0..<40 {
                        if kill(-group, 0) == -1 && errno == ESRCH { break }
                        try? await Task.sleep(nanoseconds: 50_000_000)
                    }
                    kill(-group, SIGKILL)
                } else {
                    for _ in 0..<40 where process.isRunning { try? await Task.sleep(nanoseconds: 50_000_000) }
                    if process.isRunning { kill(workerPID, SIGKILL) }
                }
                process.waitUntilExit()
            }.value
        }
        do {
            let handshakeDeadline = Date().addingTimeInterval(30)
            while ownedProcessGroup == nil && process.isRunning {
                try Task.checkCancellation()
                guard Date() < handshakeDeadline else { throw DocumentConversionError.timedOut }
                try readEvents()
                if let workerFailure { throw workerFailure }
                if ownedProcessGroup == nil { try await Task.sleep(nanoseconds: 10_000_000) }
            }
            guard ownedProcessGroup != nil else { throw DocumentConversionError.conversionFailed }
            inputWriter = Task.detached {
                defer { try? stdin.fileHandleForWriting.close() }
                try stdin.fileHandleForWriting.write(contentsOf: payload)
            }
            let deadline = Date().addingTimeInterval(60 * 60)
            while process.isRunning {
                try Task.checkCancellation()
                guard Date() < deadline else { throw DocumentConversionError.timedOut }
                try readEvents()
                if let workerFailure { throw workerFailure }
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            try await inputWriter?.value
            try Task.checkCancellation()
            try readEvents()
            guard buffer.isEmpty else { throw DocumentConversionError.invalidOutput }
            if let workerFailure { throw workerFailure }
            guard process.terminationStatus == 0, var completed = result else { throw DocumentConversionError.conversionFailed }
            // Reap any remaining engine helpers before validating and
            // publishing their final output, even after a successful leader.
            await stop()
            let finalURL = completed.outputURL.resolvingSymlinksInPath().standardizedFileURL
            let outputRoot = outputDirectory.resolvingSymlinksInPath().standardizedFileURL.path + "/"
            guard finalURL.path.hasPrefix(outputRoot),
                  let values = try? finalURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true, let size = values.fileSize, size > 0, size <= 512_000_000 else { throw DocumentConversionError.invalidOutput }
            let finalBytes = try Data(contentsOf: finalURL)
            let expectedPages = job.mode == .bilingual ? input.pageCount * 2 : input.pageCount
            // A worker may continue writing after its result event. Validate
            // the exact bytes published only once the process has exited.
            guard let finalPDF = PDFDocument(data: finalBytes), !finalPDF.isEncrypted,
                  finalPDF.pageCount == expectedPages else { throw DocumentConversionError.invalidOutput }
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent("translation.pdf")
            // Atomic publication keeps a previous valid output intact if a run
            // fails or is cancelled before the PDF has been verified.
            try finalBytes.write(to: destination, options: .atomic)
            completed.outputURL = destination
            return completed
        } catch {
            await stop()
            if let inputWriter { _ = try? await inputWriter.value }
            else { try? stdin.fileHandleForWriting.close() }
            throw error
        }
    }
}
