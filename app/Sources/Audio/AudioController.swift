import Foundation
import Combine
import AVFoundation

/// Only this local facade owns the ASR model; online sessions use its base
/// capture lifecycle directly and never construct this adapter.
private final class LocalASRFrameConsumer: @unchecked Sendable {
    let converter = AudioPCMConverter()
    var pipeline: AudioPipeline?
    var failed: (@Sendable (String) -> Void)?
    func append(_ frame: CapturedAudioFrame) -> Bool {
        guard let pipeline else { return false }
        do { return pipeline.append(try converter.convert(frame.pcm)) }
        catch { failed?(error.localizedDescription); return false }
    }
}

@MainActor final class AudioController: AudioCaptureSession {
    @Published private(set) var provisional = ""
    @Published private(set) var captionProvisional: AudioProvisional?
    var onConfirmed: ((AudioTranscript) -> Void)?
    private let modelManager: ModelManager
    private var pipeline: AudioPipeline?
    private var consumer: LocalASRFrameConsumer?

    init(modelManager: ModelManager, backend: AudioCaptureBackend = HardwareAudioCaptureBackend(), coordinator: CaptureSessionCoordinator? = nil) {
        self.modelManager = modelManager
        super.init(backend: backend, coordinator: coordinator)
        onDrain = { [weak self] in
            guard let self else { return }
            let old = self.pipeline; self.pipeline = nil
            if let consumer = self.consumer {
                do { if let old { _ = old.append(try consumer.converter.finish(), bounded: false) } }
                catch { self.onGap?(AudioGap(id: UUID().uuidString, sessionID: self.sessionID ?? "", epochID: self.epochID, reason: "resampler-tail-failed", start: self.currentOffset, end: self.currentOffset)) }
            }
            self.consumer = nil
            await old?.finish()
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            if !self.provisional.isEmpty { self.provisional = "" }; self.captionProvisional = nil
            if !self.requiresRestartAfterStopFailure { self.modelManager.isInUse = false }
        }
    }
    override func selectSession(ended: Bool) {
        super.selectSession(ended: ended)
        if phase != .capturing, phase != .starting, !draining { provisional = ""; captionProvisional = nil }
    }
    override func configure(_ value: AudioConfiguration) async {
        var local = value; local.language = value.language == "ja" ? "ja" : "en"
        await super.configure(local)
    }
    func start(sessionID: String, elapsedOffset: Double, recordingDirectory: URL?, maximumCaptureDuration: TimeInterval? = nil, startupTimeout: TimeInterval = 20) async throws {
        try await preflight(sessionID: sessionID, elapsedOffset: elapsedOffset, startupTimeout: startupTimeout)
        let token = generation
        try await withTaskCancellationHandler(operation: {
            do {
                let engine = try await modelManager.ensureLoaded()
                try checkStart(token)
                modelManager.isInUse = true
                let pipe = try await makePipeline(engine: engine, sessionID: sessionID, anchor: currentOffset)
                do { try checkStart(token) } catch { await pipe.finish(); throw error }
                pipeline = pipe
                let consumer = makeConsumer(pipe, token: token)
                self.consumer = consumer
                try await startPrepared(recordingDirectory: recordingDirectory, maximumCaptureDuration: maximumCaptureDuration, drainAdmittedFrames: true, onFrame: { consumer.append($0) })
            } catch {
                if generation == token { await pause(reason: error is CancellationError ? "启动已取消；请手动继续" : error.localizedDescription) }
                throw error
            }
        }, onCancel: { [weak self] in Task { @MainActor in guard self?.generation == token else { return }; self?.stopImmediately(reason: "启动已取消；请手动继续") } })
    }
    private func makePipeline(engine: ASREngine, sessionID: String, anchor: Double) async throws -> AudioPipeline {
        let epoch = epochID, language = configuration.language
        return try await Task.detached { [weak self] in
            try AudioPipeline(engine: engine, sessionID: sessionID, epochID: epoch, language: language, anchor: anchor, recordingDirectory: nil,
                onConfirmed: { [weak self] row in DispatchQueue.main.async { self?.onConfirmed?(row) } },
                onProvisional: { [weak self] text in DispatchQueue.main.async { if self?.epochID == epoch, self?.provisional != text { self?.provisional = text } } },
                onGap: { [weak self] gap in DispatchQueue.main.async { self?.onGap?(gap) } },
                onRecording: { _ in },
                onError: { [weak self] error in DispatchQueue.main.async { if self?.epochID == epoch { self?.stopImmediately(reason: error) } } },
                onCaptionProvisional: { [weak self] value in DispatchQueue.main.async {
                    guard let self, self.epochID == value.epochID else { return }
                    if value.text.isEmpty { if self.captionProvisional?.id == value.id { self.captionProvisional = nil } }
                    else if self.captionProvisional != value { self.captionProvisional = value }
                } })
        }.value
    }
    private func makeConsumer(_ pipe: AudioPipeline, token: UUID) -> LocalASRFrameConsumer {
        let consumer = LocalASRFrameConsumer(); consumer.pipeline = pipe
        consumer.failed = { [weak self] error in Task { @MainActor in guard self?.generation == token else { return }; self?.stopImmediately(reason: error) } }
        return consumer
    }
    #if AUDIO_TESTING
    /// Changes only the live draft for mounted-view observation checks. This
    /// does not create a transcript, start ASR, or reach production builds.
    func setProvisionalForUIObservationChecks(_ value: String) { provisional = value }
    @discardableResult func beginSilentReplayForCheck(samples: [Float], recordingDirectory: URL?) async throws -> @Sendable (AVAudioPCMBuffer) -> Void {
        guard let engine = modelManager.engine, phase != .capturing, phase != .starting, phase != .ended, !draining else { throw AudioFailure.message("Invalid test setup") }
        let identity = "development-replay-controller", consumer = LocalASRFrameConsumer()
        let callback = try await beginSyntheticCapture(sessionID: identity, recordingDirectory: recordingDirectory, onFrame: { consumer.append($0) })
        let pipe = try await makePipeline(engine: engine, sessionID: identity, anchor: currentOffset)
        pipeline = pipe; consumer.pipeline = pipe; modelManager.isInUse = true
        self.consumer = consumer
        for offset in stride(from: 0, to: samples.count, by: 1600) {
            let count = min(1600, samples.count - offset), chunk = Array(samples[offset..<min(offset + 1600, samples.count)])
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
                    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!; buffer.frameLength = buffer.frameCapacity
                    chunk.withUnsafeBufferPointer { buffer.floatChannelData![0].update(from: $0.baseAddress!, count: count) }
                    callback(buffer); continuation.resume()
                }
            }
            await captureBarrierForChecks(); await pipe.barrier()
        }
        return callback
    }
    #endif
}
