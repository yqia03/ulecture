import Foundation
import PDFKit
import CoreGraphics
import Darwin

@main struct BabelDOCBridgeChecks {
    @MainActor static func main() async throws {
        let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let root = output.appendingPathComponent("fixtures", isDirectory: true)
        let runtime = root.appendingPathComponent("engine", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: runtime.appendingPathComponent("runtime/bin"), withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: runtime.appendingPathComponent("runtime/bin/python3"), withDestinationURL: URL(fileURLWithPath: "/usr/bin/python3"))
        try Data("{\"version\":\"test-fixture\"}".utf8).write(to: runtime.appendingPathComponent("runtime-manifest.json"))
        let source = root.appendingPathComponent("source.pdf")
        try makePDF(source, pages: 1)
        try makePDF(runtime.appendingPathComponent("two-pages.pdf"), pages: 2)
        try Data(worker.utf8).write(to: runtime.appendingPathComponent("worker.py"))
        let resources = BabelDOCResources(directory: runtime)
        let suite = "ulecture.babeldoc.bridge." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let credentials = FeatureCredentials()
        let settings = CloudServiceSettings(initialConfiguration: CloudConfiguration(provider: .deepSeek), credentials: credentials, defaults: defaults, scope: "documentTranslation")
        let secret = "bridge-private-" + UUID().uuidString
        try settings.saveCredential(secret)
        let authorization = try settings.authorize()
        var checks: [String] = []
        func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw NSError(domain: "BabelDOCBridgeChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            checks.append(label)
        }
        func configure(_ mode: String) throws {
            try Data(mode.utf8).write(to: runtime.appendingPathComponent("scenario"), options: .atomic)
            try? fm.removeItem(at: runtime.appendingPathComponent("audit.json"))
            try? fm.removeItem(at: runtime.appendingPathComponent("startup.json"))
        }
        func job(_ mode: DocumentOutputMode = .translated) -> DocumentTranslationJob {
            var value = DocumentTranslationJob(title: "Bridge fixture", sourceExtension: "pdf", sourceLanguage: "en", targetLanguage: "zh-Hans", mode: mode, domain: .general, glossaryRevision: 1, terms: [])
            value.engine = .babelDOC
            return value
        }
        func directory(_ name: String) throws -> URL {
            let value = root.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: value, withIntermediateDirectories: true)
            return value
        }
        func assertCleanup(_ directory: URL) throws {
            let contents = try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            try check(!contents.contains { $0.lastPathComponent.hasPrefix("babeldoc-") }, "\(directory.lastPathComponent): temporary process files removed")
        }
        try check(resources.ready, "isolated fixture provides a real executable worker process")
        try check(try BabelDOCBridge.baseURL(for: CloudConfiguration(provider: .geminiDeveloper)) == "https://generativelanguage.googleapis.com/v1beta/openai/", "AI Studio selects Google's Gemini OpenAI compatibility endpoint")
        try check(try BabelDOCBridge.baseURL(for: CloudConfiguration(provider: .deepSeek)) == "https://api.deepseek.com", "DeepSeek selects its official endpoint")

        for mode in DocumentOutputMode.allCases {
            try configure("success")
            let folder = try directory(mode.rawValue)
            var progress: [(Double, String)] = []
            let result = try await BabelDOCBridge.translate(inputPDF: source, directory: folder, job: job(mode), authorization: authorization, resources: resources) { progress.append(($0, $1)) }
            let expectedPages = mode == .bilingual ? 2 : 1
            try check(result.outputURL == folder.appendingPathComponent("translation.pdf") && result.pageCount == expectedPages && PDFDocument(url: result.outputURL)?.pageCount == expectedPages, "\(mode.rawValue): validated PDF published to stable output path")
            try check(result.inputTokens == 11 && result.outputTokens == 17, "\(mode.rawValue): reported usage retained")
            try check(progress.map(\.0) == [0.25, 0.8] && progress.map(\.1) == ["preparing", "rendering"], "\(mode.rawValue): duplicate progress and unknown stages filtered")
            let audit = try JSONSerialization.jsonObject(with: Data(contentsOf: runtime.appendingPathComponent("audit.json"))) as! [String: Any]
            try check(audit["stdinHasKey"] as? Bool == true && audit["secretInArguments"] as? Bool == false && audit["secretInEnvironment"] as? Bool == false, "\(mode.rawValue): API key arrives exclusively through stdin")
            try check(audit["bytecodeDisabled"] as? Bool == true, "\(mode.rawValue): worker cannot generate bytecode in the bundled runtime")
            try check(audit["model"] as? String == settings.selectedModel && audit["baseURL"] as? String == "https://api.deepseek.com" && audit["mode"] as? String == mode.rawValue, "\(mode.rawValue): selected provider/model/output options reach worker")
            try assertCleanup(folder)
        }

        for (scenario, expected) in [("outside", "invalidOutput"), ("symlink", "invalidOutput"), ("invalid", "invalidOutput"), ("truncated", "invalidOutput"), ("oversize", "invalidOutput"), ("wrongPageCount", "invalidOutput"), ("truncatedEvent", "invalidOutput"), ("authentication", "authentication"), ("unknownError", "conversionFailed"), ("lateTruncate", "invalidOutput"), ("lateSymlink", "invalidOutput")] {
            try configure(scenario)
            let folder = try directory(scenario)
            let destination = folder.appendingPathComponent("translation.pdf")
            let original = try Data(contentsOf: source)
            try original.write(to: destination)
            var caught: String?
            do { _ = try await BabelDOCBridge.translate(inputPDF: source, directory: folder, job: job(), authorization: authorization, resources: resources) { _, _ in } }
            catch { caught = (error as? DocumentConversionError)?.rawValue ?? (error as? CloudFailure)?.rawValue ?? "unexpected" }
            try check(caught == expected, "\(scenario): unsafe or incomplete worker result rejected as \(expected)")
            try check(try Data(contentsOf: destination) == original, "\(scenario): prior valid PDF preserved")
            try assertCleanup(folder)
        }

        try configure("success")
        let oversizedFolder = try directory("oversizedPayload")
        var oversizedJob = job()
        oversizedJob.terms = [TranslationTerm(source: "term", translation: "术语", note: String(repeating: "x", count: 2_100_000))]
        var oversizedRejected = false
        do { _ = try await BabelDOCBridge.translate(inputPDF: source, directory: oversizedFolder, job: oversizedJob, authorization: authorization, resources: resources) { _, _ in } }
        catch DocumentConversionError.tooLarge { oversizedRejected = true }
        try check(oversizedRejected && !fm.fileExists(atPath: runtime.appendingPathComponent("audit.json").path), "oversized stdin payload rejected before launching a child")
        try assertCleanup(oversizedFolder)

        for scenario in ["sleep", "sleepChild", "beforeReady"] {
            try configure(scenario)
            let cancelFolder = try directory("cancelled-" + scenario)
            let cancelled = Task { @MainActor in
                try await BabelDOCBridge.translate(inputPDF: source, directory: cancelFolder, job: job(), authorization: authorization, resources: resources) { _, _ in }
            }
            let auditURL = runtime.appendingPathComponent(scenario == "beforeReady" ? "startup.json" : "audit.json")
            let deadline = Date().addingTimeInterval(8)
            while !fm.fileExists(atPath: auditURL.path), Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
            try check(fm.fileExists(atPath: auditURL.path), "\(scenario): cancellation waits until the test worker is ready")
            let audit = try JSONSerialization.jsonObject(with: Data(contentsOf: auditURL)) as! [String: Any]
            let pid = pid_t(audit["pid"] as! Int)
            cancelled.cancel()
            var cancellationObserved = false
            do { _ = try await cancelled.value } catch is CancellationError { cancellationObserved = true }
            try check(cancellationObserved && kill(pid, 0) == -1 && errno == ESRCH, "\(scenario): cancellation terminates and reaps the worker process")
            if let childPID = audit["childPID"] as? Int {
                let child = pid_t(childPID), deadline = Date().addingTimeInterval(4)
                while kill(child, 0) == 0, Date() < deadline { try await Task.sleep(nanoseconds: 20_000_000) }
                try check(kill(child, 0) == -1 && errno == ESRCH, "multiprocessing child ignoring SIGTERM is killed after its leader exits")
            }
            if scenario == "beforeReady" { try check(!fm.fileExists(atPath: runtime.appendingPathComponent("audit.json").path), "pre-handshake cancellation sends no credential payload") }
            try check(!fm.fileExists(atPath: cancelFolder.appendingPathComponent("translation.pdf").path), "\(scenario): cancelled worker cannot publish a PDF")
            try assertCleanup(cancelFolder)
        }

        let sentinel = Process()
        sentinel.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        sentinel.arguments = ["-I", "-B", "-c", "import os,time\ntry: os.setsid()\nexcept PermissionError:\n if os.getpgrp() != os.getpid(): raise\ntime.sleep(30)"]
        sentinel.standardOutput = FileHandle.nullDevice; sentinel.standardError = FileHandle.nullDevice
        try sentinel.run()
        defer { if sentinel.isRunning { sentinel.terminate() }; sentinel.waitUntilExit() }
        let sentinelPID = sentinel.processIdentifier, sentinelDeadline = Date().addingTimeInterval(5)
        while getpgid(sentinelPID) != sentinelPID, Date() < sentinelDeadline { try await Task.sleep(nanoseconds: 10_000_000) }
        try check(getpgid(sentinelPID) == sentinelPID, "unrelated sentinel has its own verified process group")
        try configure("forgedReady")
        try Data(String(sentinelPID).utf8).write(to: runtime.appendingPathComponent("forgedGroup"))
        let forgedFolder = try directory("forgedReady")
        var forgedRejected = false
        do { _ = try await BabelDOCBridge.translate(inputPDF: source, directory: forgedFolder, job: job(), authorization: authorization, resources: resources) { _, _ in } }
        catch DocumentConversionError.conversionFailed { forgedRejected = true }
        try check(forgedRejected && sentinel.isRunning && kill(sentinelPID, 0) == 0, "forged ready event cannot cause signals to an unrelated process group")
        try check(!fm.fileExists(atPath: runtime.appendingPathComponent("audit.json").path), "unverified worker receives no credential payload")
        try assertCleanup(forgedFolder)

        try check(try !containsOnDisk(Data(secret.utf8), root: root), "no key is persisted in worker scripts, process events, reports, job files or output PDFs")
        let report = try JSONSerialization.data(withJSONObject: ["passed": checks.count, "checks": checks], options: [.prettyPrinted, .sortedKeys])
        try report.write(to: output.appendingPathComponent("results.json"), options: .atomic)
        print("BabelDOC bridge checks passed: \(checks.count)")
    }

    static func containsOnDisk(_ bytes: Data, root: URL) throws -> Bool {
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey])!
        for case let file as URL in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true && values.isSymbolicLink != true, try Data(contentsOf: file).range(of: bytes) != nil { return true }
        }
        return false
    }

    static func makePDF(_ url: URL, pages: Int) throws {
        var mediaBox = CGRect(x: 0, y: 0, width: 240, height: 320)
        guard let consumer = CGDataConsumer(url: url as CFURL), let context = CGContext(consumer: consumer, mediaBox: &mediaBox, nil) else { throw DocumentConversionError.persistence }
        for page in 0..<pages {
            context.beginPDFPage(nil)
            context.setFillColor(CGColor(gray: CGFloat(page + 1) / CGFloat(pages + 1), alpha: 1))
            context.fill(CGRect(x: 20, y: 20, width: 80, height: 50))
            context.endPDFPage()
        }
        context.closePDF()
    }

    static let worker = #"""
import json, os, pathlib, shutil, signal, subprocess, sys, time
try:
    os.setsid()
except PermissionError:
    if os.getpgrp() != os.getpid():
        raise
root = pathlib.Path(__file__).parent
scenario = (root / 'scenario').read_text()
if scenario == 'beforeReady':
    (root / 'startup.tmp').write_text(json.dumps({'pid': os.getpid()}))
    (root / 'startup.tmp').replace(root / 'startup.json')
    time.sleep(30)
print(json.dumps({'type': 'ready', 'processGroup': int((root / 'forgedGroup').read_text()) if scenario == 'forgedReady' else os.getpid()}), flush=True)
request = json.load(sys.stdin)
secret = request['apiKey']
audit = {'pid': os.getpid(), 'stdinHasKey': bool(secret), 'bytecodeDisabled': sys.dont_write_bytecode,
         'secretInArguments': any(secret in value for value in sys.argv),
         'secretInEnvironment': any(secret in value for value in os.environ.values()),
         'arguments': sys.argv, 'environment': dict(os.environ),
         'model': request['model'], 'baseURL': request['baseURL'], 'mode': request['mode']}
if scenario == 'sleepChild':
    child = subprocess.Popen([sys.executable, '-I', '-B', '-u', '-c', 'import signal,time; signal.signal(signal.SIGTERM,signal.SIG_IGN); print("ready",flush=True); time.sleep(30)'], stdout=subprocess.PIPE)
    child.stdout.readline()
    audit['childPID'] = child.pid
(root / 'audit.tmp').write_text(json.dumps(audit))
(root / 'audit.tmp').replace(root / 'audit.json')
def emit(value):
    print(json.dumps(value), flush=True)
if scenario in ('sleep', 'sleepChild'):
    time.sleep(30)
elif scenario in ('authentication', 'unknownError'):
    emit({'type': 'error', 'code': 'authentication' if scenario == 'authentication' else 'unsafe-internal-exception'})
    sys.exit(1)
elif scenario == 'truncatedEvent':
    sys.stdout.write('{"type":"result"')
    sys.stdout.flush()
    sys.exit(0)
else:
    emit({'type': 'progress', 'progress': 0.25, 'stage': 'preparing'})
    emit({'type': 'progress', 'progress': 0.25, 'stage': 'preparing'})
    emit({'type': 'progress', 'progress': 0.5, 'stage': 'untrusted-stage'})
    emit({'type': 'progress', 'progress': 0.8, 'stage': 'rendering'})
    output = pathlib.Path(request['outputDirectory']) / 'result.pdf'
    source = pathlib.Path(request['inputPDF'])
    if scenario == 'outside':
        output = source
    elif scenario == 'symlink':
        output.symlink_to(source)
    elif scenario == 'invalid':
        output.write_bytes(b'not a PDF')
    elif scenario == 'truncated':
        output.write_bytes(source.read_bytes()[:40])
    elif scenario == 'oversize':
        with output.open('wb') as file:
            file.truncate(512000001)
    elif scenario == 'wrongPageCount':
        shutil.copyfile(root / 'two-pages.pdf', output)
    else:
        shutil.copyfile(root / 'two-pages.pdf' if request['mode'] == 'bilingual' else source, output)
    emit({'type': 'result', 'outputPath': str(output), 'inputTokens': 11, 'outputTokens': 17})
    if scenario == 'lateTruncate':
        time.sleep(0.4)
        output.write_bytes(b'changed after result')
    elif scenario == 'lateSymlink':
        time.sleep(0.4)
        output.unlink()
        output.symlink_to(source)
"""#
}
