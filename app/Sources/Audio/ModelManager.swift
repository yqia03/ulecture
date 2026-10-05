import Foundation
import Combine
import CryptoKit

struct ASRText: Codable { let text: String; let start: Double; let end: Double }
enum AudioFailure: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let text) = self { return text }; return nil }
}
final class ASREngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "local.uway.classroom.asr", qos: .userInitiated)
    private var handle: UnsafeMutableRawPointer?
    let vadURL: URL
    init(model: URL, vad: URL) throws {
        guard let handle = classroom_asr_open(model.path, vad.path) else { throw AudioFailure.message("离线模型加载失败；没有启动云端转写。") }
        self.handle = handle; self.vadURL = vad
    }
    deinit { if let handle { classroom_asr_close(handle) } }
    /// Waits behind every admitted recognition, then releases Metal before process exit.
    /// Further recognition requests fail instead of dereferencing a closed handle.
    func shutdown() async {
        await withCheckedContinuation { continuation in
            queue.async { if let handle = self.handle { classroom_asr_close(handle); self.handle = nil }; continuation.resume() }
        }
    }
    func recognize(_ samples: [Float], language: String, completion: @escaping (Result<[ASRText], Error>) -> Void) {
        queue.async {
            guard let handle = self.handle else { completion(.failure(AudioFailure.message("离线模型已卸载"))); return }
            let code = samples.withUnsafeBufferPointer { classroom_asr_run(handle, $0.baseAddress, Int32($0.count), language) }
            guard code == 0 else { completion(.failure(AudioFailure.message("离线识别失败（\(code)）；尾部未确认为原文。"))); return }
            let rows = (0..<classroom_asr_count(handle)).map { index in ASRText(text: String(cString: classroom_asr_text(handle, index)).trimmingCharacters(in: .whitespacesAndNewlines), start: classroom_asr_start(handle, index), end: classroom_asr_end(handle, index)) }.filter { !$0.text.isEmpty }
            completion(.success(rows))
        }
    }
    func recognize(_ samples: [Float], language: String) async throws -> [ASRText] {
        try await withCheckedThrowingContinuation { continuation in recognize(samples, language: language) { continuation.resume(with: $0) } }
    }
}

struct OfflineResource {
    let name: String, sha256: String, bytes: Int64, address: String
    static let base = OfflineResource(name: "ggml-base.bin", sha256: "60ed5bc3dd14eea856493d334349b405782ddcaf0028d4b5df4088345fba2efe", bytes: 147951465, address: "https://huggingface.co/ggerganov/whisper.cpp/resolve/5359861c739e955e79d9a303bcbc70fb988958b1/ggml-base.bin")
    static let vad = OfflineResource(name: "ggml-silero-v6.2.0.bin", sha256: "2aa269b785eeb53a82983a20501ddf7c1d9c48e33ab63a41391ac6c9f7fb6987", bytes: 885098, address: "https://huggingface.co/ggml-org/whisper-vad/resolve/9ffd54a1e1ee413ddf265af9913beaf518d1639b/ggml-silero-v6.2.0.bin")
    static func validate(_ url: URL, resource: OfflineResource) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard (attrs[.size] as? NSNumber)?.int64Value == resource.bytes else { throw AudioFailure.message("模型文件大小不符：\(resource.name)") }
        let input = try FileHandle(forReadingFrom: url); defer { try? input.close() }
        var hash = SHA256()
        while let data = try input.read(upToCount: 1_048_576), !data.isEmpty { hash.update(data: data) }
        guard hash.finalize().map({ String(format: "%02x", $0) }).joined() == resource.sha256 else { throw AudioFailure.message("模型 SHA-256 校验失败；原文件已保留。") }
    }
}

enum ModelResourceState: String, Codable { case checking, absent, downloading, verifying, installing, ready, error }
enum ModelEngineState: String { case unloaded, loading, loaded, failed }

/// One resource worker also serializes cancelled and replacement preparations.
/// Cancellation invalidates publication; it never starts a second native loader
/// while an earlier loader is still returning.
enum ModelResourceWorker {
    private static let queue = DispatchQueue(label: "local.ulecture.model-resources", qos: .userInitiated)
    static func run<T>(_ operation: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try operation() }) }
        }
    }
}

struct ModelInstallation: Codable {
    struct Resource: Codable { let name: String, sha256: String, path: String; let bytes: Int64 }
    let schema: Int
    let engineRevision: String
    let verifiedAt: Date
    let resources: [Resource]
}

final class ModelDownload: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private var session: URLSession?, task: URLSessionDownloadTask?
    private var continuation: CheckedContinuation<URL, Error>?
    @MainActor private var cancelled = false
    #if AUDIO_TESTING
    var beforeNetworkStartForChecks: (() throws -> Void)?
    #endif
    let progress: (Double) -> Void
    init(progress: @escaping (Double) -> Void) { self.progress = progress }
    @MainActor func download(_ url: URL) async throws -> URL {
        guard !cancelled else { throw CancellationError() }
        #if AUDIO_TESTING
        if let beforeNetworkStartForChecks { try beforeNetworkStartForChecks() }
        #endif
        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            let config = URLSessionConfiguration.ephemeral; config.timeoutIntervalForRequest = 30; config.timeoutIntervalForResource = 900
            session = URLSession(configuration: config, delegate: self, delegateQueue: nil)
            task = session!.downloadTask(with: url); task!.resume()
        }
    }
    @MainActor func cancel() { cancelled = true; task?.cancel() }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) { if totalBytesExpectedToWrite > 0 { progress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)) } }
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            guard let response = downloadTask.response as? HTTPURLResponse, response.statusCode == 200 else { throw AudioFailure.message("模型下载服务器返回错误；文件未安装。") }
            let preserved = FileManager.default.temporaryDirectory.appendingPathComponent("classroom-model-\(UUID().uuidString).partial")
            try FileManager.default.moveItem(at: location, to: preserved)
            continuation?.resume(returning: preserved); continuation = nil
        } catch { continuation?.resume(throwing: error); continuation = nil }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { continuation?.resume(throwing: error); continuation = nil }
        session.finishTasksAndInvalidate()
        Task { @MainActor in self.session = nil; self.task = nil }
    }
}

@MainActor final class ModelManager: ObservableObject {
    @Published private(set) var status = "离线模型尚未检查"
    @Published private(set) var progress: Double = 0
    @Published private(set) var ready = false
    /// Verified local resources are available; this does not imply a loaded engine.
    @Published private(set) var resourcesAvailable = false
    @Published private(set) var busy = false
    @Published private(set) var resourceState: ModelResourceState = .checking
    @Published private(set) var engineState: ModelEngineState = .unloaded
    var isInUse = false
    private(set) var engine: ASREngine?
    let cacheDirectory: URL
    private var downloadJob: ModelDownload?
    private var generation = UUID()
    private var startupChecked = false
    #if AUDIO_TESTING
    var bundledDirectoryForChecks: URL?
    var validationForChecks: ((URL, OfflineResource) async throws -> Void)?
    var downloadForChecks: ((URL) async throws -> URL)?
    #endif
    private func validate(_ url: URL, resource: OfflineResource) async throws {
        #if AUDIO_TESTING
        if let validationForChecks { try await validationForChecks(url, resource); return }
        #endif
        try await ModelResourceWorker.run { try OfflineResource.validate(url, resource: resource) }
    }
    private func downloadResource(_ resource: OfflineResource, index: Int, token: UUID) async throws -> URL {
        guard generation == token else { throw CancellationError() }
        let address = URL(string: resource.address)!
        #if AUDIO_TESTING
        if let downloadForChecks { return try await downloadForChecks(address) }
        #endif
        let resources = [OfflineResource.base, .vad]
        let total = Double(resources.reduce(Int64(0)) { $0 + $1.bytes })
        let previous = Double(resources.prefix(index).reduce(Int64(0)) { $0 + $1.bytes })
        let job = ModelDownload { value in Task { @MainActor [weak self] in guard self?.generation == token else { return }; self?.progress = (previous + value * Double(resource.bytes)) / total } }
        downloadJob = job
        return try await job.download(address)
    }
    private func bundledResource(_ name: String) -> URL? {
        #if AUDIO_TESTING
        if let bundledDirectoryForChecks { return bundledDirectoryForChecks.appendingPathComponent(name) }
        #endif
        return Bundle.main.resourceURL?.appendingPathComponent("Models/\(name)")
    }
    init(cacheDirectory: URL? = nil) {
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("UwayClassroom/Models", isDirectory: true)
    }
    func cancel() {
        generation = UUID(); downloadJob?.cancel(); downloadJob = nil; busy = false
        if ready { resourceState = .ready; engineState = .loaded }
        else { resourceState = .absent; engineState = engine == nil ? .unloaded : .loaded }
        status = ready ? "已取消；现有已验证模型仍可用" : "准备已取消；尚未就绪"
    }
    /// Capture owners must drain first. A failed stop retains the engine for safety.
    func unload() async -> Bool {
        guard !isInUse else { return false }
        cancel()
        _ = try? await ModelResourceWorker.run { () }
        guard !isInUse else { return false }
        let old = engine; engine = nil
        await old?.shutdown()
        ready = false; engineState = .unloaded
        resourceState = resourcesAvailable ? .ready : .absent
        return true
    }
    /// Read-only discovery: opening the app must not install or load offline ASR.
    func restoreAtLaunch() async {
        guard !startupChecked else { return }; startupChecked = true
        let token = generation
        let candidates = [OfflineResource.base, .vad].map { resource in
            (resource, [cacheDirectory.appendingPathComponent(resource.name), bundledResource(resource.name)].compactMap { $0 })
        }
        let available = (try? await ModelResourceWorker.run {
            candidates.allSatisfy { resource, urls in
                urls.contains { (try? OfflineResource.validate($0, resource: resource)) != nil }
            }
        }) ?? false
        guard token == generation, !busy, engine == nil else { return }
        resourcesAvailable = available; resourceState = available ? .ready : .absent
        engineState = .unloaded; ready = false
        status = available ? "离线资源可用；开始本地识别时加载" : "尚未下载离线模型；下载后即可离线转写。"
    }
    /// Recheck actual resources before a new session, including a deleted or
    /// replaced file while this process still owns an old in-memory engine.
    func ensureLoaded() async throws -> ASREngine {
        while busy { try Task.checkCancellation(); try await Task.sleep(nanoseconds: 20_000_000) }
        try Task.checkCancellation()
        await prepare(importURL: nil, allowDownload: false)
        try Task.checkCancellation()
        guard ready, let engine else { throw AudioFailure.message(status) }
        return engine
    }
    func prepareBundledOrCached() async {
        await prepare(importURL: nil, allowDownload: false)
    }
    func importModel(url: URL) async { await prepare(importURL: url, allowDownload: false) }
    func download() async { await prepare(importURL: nil, allowDownload: true) }
    private func prepare(importURL: URL?, allowDownload: Bool) async {
        guard !busy, !isInUse else { status = "请先暂停课堂并等待识别完成，再准备模型。"; return }
        busy = true; progress = 0; resourceState = .checking; let token = UUID(); generation = token
        defer { if generation == token { busy = false; downloadJob = nil } }
        do {
            let cache = cacheDirectory
            try await ModelResourceWorker.run { try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true) }
            guard generation == token else { return }
            var replacedResource = false
            for (index, resource) in [OfflineResource.base, .vad].enumerated() {
                guard generation == token else { return }
                let dest = cacheDirectory.appendingPathComponent(resource.name)
                let bundled = bundledResource(resource.name)
                let source = resource.name == OfflineResource.base.name ? importURL : nil
                let cachedExists = FileManager.default.fileExists(atPath: dest.path)
                var cacheValid = false
                if cachedExists {
                    resourceState = .verifying; status = "正在校验 \(resource.name)"
                    cacheValid = (try? await validate(dest, resource: resource)) != nil
                    guard generation == token else { return }
                }
                if source != nil || !cacheValid {
                    ready = false
                    // A corrupt cache is never the input to the loader. Prefer a independently
                    // verified bundled resource; downloading still requires explicit user action.
                    var origin = source
                    if origin == nil, let bundled, FileManager.default.fileExists(atPath: bundled.path),
                       (try? await validate(bundled, resource: resource)) != nil {
                        origin = bundled
                    }
                    guard generation == token else { return }
                    var temporaryDownload: URL?
                    if origin == nil, allowDownload {
                        resourceState = .downloading; status = "正在下载 \(resource.name)"
                        origin = try await downloadResource(resource, index: index, token: token); temporaryDownload = origin
                    }
                    defer { if let temporaryDownload { try? FileManager.default.removeItem(at: temporaryDownload) } }
                    guard generation == token else { return }
                    guard let origin else {
                        resourceState = cachedExists ? .error : .absent
                        throw AudioFailure.message(cachedExists ? "离线模型已损坏；请重新下载离线模型。原文件已保留。" : "尚未下载离线模型；下载后即可离线转写。")
                    }
                    resourceState = .installing; status = "校验并安装 \(resource.name)"
                    let stage = cacheDirectory.appendingPathComponent("\(UUID().uuidString).partial")
                    do {
                        try await ModelResourceWorker.run { try OfflineResource.validate(origin, resource: resource); try FileManager.default.copyItem(at: origin, to: stage); try OfflineResource.validate(stage, resource: resource) }
                        guard generation == token else { try? FileManager.default.removeItem(at: stage); return }
                        if cachedExists && !cacheValid {
                            let rejected = cacheDirectory.appendingPathComponent("\(resource.name).rejected-\(UUID().uuidString)")
                            try FileManager.default.moveItem(at: dest, to: rejected)
                            do { try FileManager.default.moveItem(at: stage, to: dest) }
                            catch { try? FileManager.default.moveItem(at: rejected, to: dest); throw error }
                        } else if cachedExists { _ = try FileManager.default.replaceItemAt(dest, withItemAt: stage) }
                        else { try FileManager.default.moveItem(at: stage, to: dest) }
                        replacedResource = true
                    } catch { try? FileManager.default.removeItem(at: stage); throw error }
                }
                let resources = [OfflineResource.base, .vad]
                progress = Double(resources.prefix(index + 1).reduce(Int64(0)) { $0 + $1.bytes }) / Double(resources.reduce(Int64(0)) { $0 + $1.bytes })
            }
            guard generation == token else { return }
            engineState = .loading; status = "正在加载离线识别模型"
            let model = cacheDirectory.appendingPathComponent(OfflineResource.base.name), vad = cacheDirectory.appendingPathComponent(OfflineResource.vad.name)
            let loaded: ASREngine
            if let existing = engine, !replacedResource { loaded = existing }
            else { loaded = try await ModelResourceWorker.run { try ASREngine(model: model, vad: vad) } }
            guard generation == token else { return }
            let installation = ModelInstallation(schema: 1, engineRevision: "whisper.cpp-927cfce34f31707e17f2bff35c349632fb9e2c3a", verifiedAt: Date(), resources: [OfflineResource.base, .vad].map { .init(name: $0.name, sha256: $0.sha256, path: cache.appendingPathComponent($0.name).path, bytes: $0.bytes) })
            let manifestURL = cache.appendingPathComponent("installation.json")
            try await ModelResourceWorker.run { try JSONEncoder().encode(installation).write(to: manifestURL, options: .atomic) }
            guard generation == token else { return }
            engine = loaded; ready = true; resourcesAvailable = true; resourceState = .ready; engineState = .loaded
            status = "已准备完成，可启用离线转写"
        } catch {
            guard generation == token else { return }
            ready = false; resourcesAvailable = false; engine = nil; engineState = .failed
            if resourceState != .absent { resourceState = .error }
            status = error.localizedDescription
        }
    }
}
