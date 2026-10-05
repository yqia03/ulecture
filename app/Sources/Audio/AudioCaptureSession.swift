import Foundation
import Combine
import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia
import ScreenCaptureKit

enum AudioPhase: String { case ready, starting, capturing, paused, ended }
enum AudioSource: String, CaseIterable, Codable { case microphone, system }
struct AudioConfiguration: Equatable, Codable {
    var source: AudioSource = .microphone
    var deviceID: UInt32? = nil
    var language = "en"
    var saveRecording = false
}
struct AudioDevice: Identifiable { let id: UInt32; let name: String; let channels: Int; let builtIn: Bool }
private func deviceAddress(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func classroomInputDevices() -> [AudioDevice] {
    var address = deviceAddress(kAudioHardwarePropertyDevices), size: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else { return [] }
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
    guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else { return [] }
    return ids.compactMap { id in
        var config = deviceAddress(kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeInput), bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &config, 0, nil, &bytes) == noErr, bytes > 0 else { return nil }
        let memory = UnsafeMutableRawPointer.allocate(byteCount: Int(bytes), alignment: MemoryLayout<AudioBufferList>.alignment); defer { memory.deallocate() }
        guard AudioObjectGetPropertyData(id, &config, 0, nil, &bytes, memory) == noErr else { return nil }
        let channels = UnsafeMutableAudioBufferListPointer(memory.assumingMemoryBound(to: AudioBufferList.self)).reduce(0) { $0 + Int($1.mNumberChannels) }
        guard channels > 0 else { return nil }
        var name: CFString = "Microphone" as CFString, nameAddress = deviceAddress(kAudioObjectPropertyName), nameSize = UInt32(MemoryLayout<CFString>.size)
        _ = withUnsafeMutablePointer(to: &name) { AudioObjectGetPropertyData(id, &nameAddress, 0, nil, &nameSize, $0) }
        var transport: UInt32 = 0, transportAddress = deviceAddress(kAudioDevicePropertyTransportType), transportSize = UInt32(MemoryLayout<UInt32>.size)
        _ = AudioObjectGetPropertyData(id, &transportAddress, 0, nil, &transportSize, &transport)
        return AudioDevice(id: id, name: name as String, channels: channels, builtIn: transport == kAudioDeviceTransportTypeBuiltIn)
    }
}

/// A buffer owned by this frame, copied before the hardware callback returns.
/// Consumers must treat pcm as immutable. capturedUptime is receipt time, not a
/// provider transcript timestamp or a claim of hardware sample-accurate timing.
struct CapturedAudioFrame: @unchecked Sendable {
    let pcm: AVAudioPCMBuffer
    let epochID: String
    let sequence: Int
    let capturedUptime: Double
    var frameCount: Int { Int(pcm.frameLength) }
    var sampleRate: Double { pcm.format.sampleRate }
    var channelCount: UInt32 { pcm.format.channelCount }
    var duration: Double { Double(frameCount) / sampleRate }
    static func copy(_ buffer: AVAudioPCMBuffer, epochID: String, sequence: Int) throws -> CapturedAudioFrame {
        guard let owned = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameLength) else { throw AudioFailure.message("无法复制采集音频。") }
        owned.frameLength = buffer.frameLength
        let source = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: buffer.audioBufferList))
        let target = UnsafeMutableAudioBufferListPointer(owned.mutableAudioBufferList)
        guard source.count == target.count else { throw AudioFailure.message("采集音频通道格式无效。") }
        for index in source.indices {
            guard let src = source[index].mData, let dst = target[index].mData, target[index].mDataByteSize >= source[index].mDataByteSize else { throw AudioFailure.message("采集音频缓冲格式无效。") }
            memcpy(dst, src, Int(source[index].mDataByteSize))
        }
        return CapturedAudioFrame(pcm: owned, epochID: epochID, sequence: sequence, capturedUptime: ProcessInfo.processInfo.systemUptime)
    }
}

/// Admission is synchronous and bounded; copying preserves the hardware format.
private final class RawCaptureSink: @unchecked Sendable {
    private let lock = NSLock()
    private let copies = DispatchGroup()
    private let worker = DispatchQueue(label: "local.ulecture.capture-pcm", qos: .userInitiated)
    private var accepting = true, pendingSeconds = 0.0, sequence = 0, lastMeter = 0.0
    private let epoch: String, receive: @Sendable (CapturedAudioFrame) -> Bool
    private let drainAdmittedFrames: Bool
    private var preserveForEnd = false
    private let failed: @Sendable (String) -> Void, meter: @Sendable (Double) -> Void
    private let recordingConverter = AudioPCMConverter()
    private var recorder: AudioRecordingWriter?
    private var recordingFailure: String?
    init(epoch: String, recorder: AudioRecordingWriter?, drainAdmittedFrames: Bool, receive: @escaping @Sendable (CapturedAudioFrame) -> Bool, failed: @escaping @Sendable (String) -> Void, meter: @escaping @Sendable (Double) -> Void) {
        self.epoch = epoch; self.recorder = recorder; self.drainAdmittedFrames = drainAdmittedFrames; self.receive = receive; self.failed = failed; self.meter = meter
    }
    func stop(preservingAdmittedFrames: Bool? = nil) {
        lock.lock(); accepting = false
        if let preservingAdmittedFrames { preserveForEnd = preservingAdmittedFrames }
        lock.unlock()
    }
    func consume(_ buffer: AVAudioPCMBuffer) {
        guard buffer.frameLength > 0, buffer.format.sampleRate > 0 else { return }
        lock.lock()
        guard accepting else { lock.unlock(); return }
        let duration = Double(buffer.frameLength) / buffer.format.sampleRate
        guard pendingSeconds + duration <= 2 else { accepting = false; lock.unlock(); failed("输入缓冲超过两秒；已停止接收，请手动继续。"); return }
        pendingSeconds += duration; sequence += 1; let nextSequence = sequence
        copies.enter()
        lock.unlock()
        defer { copies.leave() }
        do {
            let frame = try CapturedAudioFrame.copy(buffer, epochID: epoch, sequence: nextSequence)
            worker.async {
                self.lock.lock(); self.pendingSeconds -= duration; let allowed = self.accepting, preserve = self.preserveForEnd; self.lock.unlock()
                do {
                    // Every admitted frame is saved even when a pause is draining.
                    if self.recorder != nil {
                        do { try self.recorder?.append(self.recordingConverter.convert(frame.pcm)) }
                        catch { self.recordingFailure = error.localizedDescription; throw error }
                    }
                    guard allowed || preserve || self.drainAdmittedFrames else { return }
                    guard self.receive(frame) else { self.stop(); self.failed("音频处理队列已满；请手动继续。"); return }
                    let now = ProcessInfo.processInfo.systemUptime
                    if now - self.lastMeter >= 0.2 {
                        self.lastMeter = now
                        var squares = 0.0
                        if let channels = frame.pcm.floatChannelData {
                            let stride = frame.pcm.format.isInterleaved ? Int(frame.channelCount) : 1
                            for i in 0..<frame.frameCount { let value = Double(channels[0][i * stride]); squares += value * value }
                        } else if let channels = frame.pcm.int16ChannelData {
                            let stride = frame.pcm.format.isInterleaved ? Int(frame.channelCount) : 1
                            for i in 0..<frame.frameCount { let value = Double(channels[0][i * stride]) / 32768; squares += value * value }
                        }
                        self.meter(max(-80, 20 * log10(max(0.00000001, sqrt(squares / Double(frame.frameCount))))))
                    }
                } catch { self.stop(); self.failed(error.localizedDescription) }
            }
        } catch {
            lock.lock(); pendingSeconds -= duration; accepting = false; lock.unlock(); failed(error.localizedDescription)
        }
    }
    func barrier() async { await withCheckedContinuation { continuation in worker.async { continuation.resume() } } }
    @discardableResult func finish() async -> String? {
        stop()
        // A tap may be copying an already-admitted buffer when stop closes the
        // gate. Its worker block must be enqueued before the final drain block.
        return await withCheckedContinuation { continuation in copies.notify(queue: worker) {
            do {
                if self.recorder != nil { try self.recorder?.append(self.recordingConverter.finish()) }
                try self.recorder?.finish()
            } catch { self.recordingFailure = error.localizedDescription; self.failed(error.localizedDescription) }
            self.recorder = nil; continuation.resume(returning: self.recordingFailure)
        } }
    }
}

/// Shared capture/recording lifecycle. This type never constructs or loads ASR.
@MainActor class AudioCaptureSession: NSObject, ObservableObject {
    @Published private(set) var phase: AudioPhase = .ready
    @Published private(set) var status = "未开始采集"
    @Published private(set) var level = -80.0
    @Published private(set) var devices: [AudioDevice] = []
    @Published private(set) var configuration = AudioConfiguration()
    @Published private(set) var draining = false
    @Published private(set) var playbackPosition: Double?
    @Published private(set) var playbackPaused = false
    @Published private(set) var captureDeadline: Date?
    @Published private(set) var lastRecordingError: String?
    private(set) var sessionID: String?
    private(set) var epochID = ""
    private(set) var generation = UUID()
    private let backend: AudioCaptureBackend
    private let coordinator: CaptureSessionCoordinator
    private let ownerID = UUID()
    private var sink: RawCaptureSink?
    private var originUptime: Double?, originOffset = 0.0, frozenOffset = 0.0, pauseAt: Double?
    private var healthTimer: Timer?, notifications: [(NotificationCenter, NSObjectProtocol)] = [], stopFailed = false, healthCheckPending = false
    private var player: AVAudioPlayer?
    private var drainTask: Task<Void, Never>?, startupWatchdog: Task<Void, Never>?, durationWatchdog: Task<Void, Never>?
    var onGap: ((AudioGap) -> Void)?
    var onRecording: ((AudioRecording) -> Void)?
    var onPhaseChanged: ((AudioPhase) -> Void)?
    /// Runs after capture/recording stop and before releasing the shared lease.
    var onDrain: (@MainActor () async -> Void)?
    var currentOffset: Double { if let originUptime, phase != .ended { return max(frozenOffset, originOffset + ProcessInfo.processInfo.systemUptime - originUptime) }; return frozenOffset }
    var microphoneAuthorized: Bool { AVCaptureDevice.authorizationStatus(for: .audio) == .authorized }
    var systemAudioAuthorized: Bool { CGPreflightScreenCaptureAccess() }
    var requiresRestartAfterStopFailure: Bool { stopFailed }
    var ownsCaptureLease: Bool { coordinator.owner == ownerID }
    init(backend: AudioCaptureBackend = HardwareAudioCaptureBackend(), coordinator: CaptureSessionCoordinator? = nil) {
        self.backend = backend; self.coordinator = coordinator ?? .shared
        super.init(); refreshDevices()
        notifications.append((.default, NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: nil, queue: nil) { [weak self] _ in Task { @MainActor in self?.checkMicrophoneHealth() } }))
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        notifications.append((workspaceCenter, workspaceCenter.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: nil) { [weak self] _ in Task { @MainActor in self?.stopImmediately(reason: "系统休眠；唤醒后需手动继续") } }))
        healthTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in Task { @MainActor in self?.checkMicrophoneHealth(); self?.updatePlaybackPosition() } }
    }
    deinit { healthTimer?.invalidate(); for (center, token) in notifications { center.removeObserver(token) }; startupWatchdog?.cancel(); durationWatchdog?.cancel() }
    func refreshDevices() {
        Task { [weak self] in
            let values = await Task.detached { classroomInputDevices() }.value
            guard let self else { return }
            if self.configuration.deviceID == nil, self.phase == .ready { self.configuration.deviceID = (values.first(where: \.builtIn) ?? values.first)?.id }
            self.devices = values
        }
    }
    func selectSession(ended: Bool) {
        guard phase != .capturing, phase != .starting, !draining, !stopFailed else { return }
        sessionID = nil; originUptime = nil; originOffset = 0; frozenOffset = 0; pauseAt = nil
        setPhase(ended ? .ended : .ready, ended ? "课堂已结束；不能重新采集" : "未开始采集")
    }
    func configure(_ value: AudioConfiguration) async {
        guard value != configuration, phase != .ended else { return }
        await pause(reason: "音源、设备、语言或录音设置已改变；请手动继续")
        guard phase != .ended, !stopFailed else { return }
        configuration = value
    }
    /// Acquires the global lease before the caller opens any billable service.
    func preflight(sessionID: String, elapsedOffset: Double, startupTimeout: TimeInterval = 20) async throws {
        guard (phase == .ready || phase == .paused), !draining, !stopFailed else { throw AudioFailure.message("当前状态不能开始；请等待尾部保存，已结束课堂需新建。") }
        do { try coordinator.acquire(owner: ownerID, sessionID: sessionID) } catch { status = error.localizedDescription; throw error }
        if self.sessionID != sessionID { self.sessionID = sessionID; originUptime = nil; frozenOffset = max(0, elapsedOffset); pauseAt = nil }
        generation = UUID(); let token = generation
        lastRecordingError = nil
        setPhase(.starting, "正在检查权限及所选音源")
        startupWatchdog?.cancel()
        startupWatchdog = Task { @MainActor [weak self] in
            do { try await Task.sleep(nanoseconds: UInt64(max(0.01, startupTimeout) * 1_000_000_000)) } catch { return }
            guard let self, self.generation == token, self.phase == .starting else { return }
            self.stopImmediately(reason: "音频启动超时；正在停止，请等待后手动重试。")
        }
        try await withTaskCancellationHandler(operation: {
            do {
                try await backend.requestPermission(for: configuration.source)
                try checkStart(token)
                try await backend.prepare(requestID: token)
                try checkStart(token)
                epochID = UUID().uuidString
            } catch { if generation == token { await pause(reason: error is CancellationError ? "启动已取消；请手动继续" : error.localizedDescription) }; throw error }
        }, onCancel: { [weak self] in Task { @MainActor in guard self?.generation == token else { return }; self?.stopImmediately(reason: "启动已取消；请手动继续") } })
    }
    func checkStart(_ token: UUID) throws { guard generation == token, phase == .starting, !Task.isCancelled, ownsCaptureLease else { throw CancellationError() } }
    func start(sessionID: String, elapsedOffset: Double, recordingDirectory: URL?, maximumCaptureDuration: TimeInterval? = nil, startupTimeout: TimeInterval = 20, onFrame: @escaping @Sendable (CapturedAudioFrame) -> Bool) async throws {
        try await preflight(sessionID: sessionID, elapsedOffset: elapsedOffset, startupTimeout: startupTimeout)
        try await startPrepared(recordingDirectory: recordingDirectory, maximumCaptureDuration: maximumCaptureDuration, onFrame: onFrame)
    }
    func startPrepared(recordingDirectory: URL?, maximumCaptureDuration: TimeInterval? = nil, drainAdmittedFrames: Bool = false, onFrame: @escaping @Sendable (CapturedAudioFrame) -> Bool) async throws {
        let token = generation
        try checkStart(token)
        try await withTaskCancellationHandler(operation: {
            do {
                let callbackSink = try await prepareSink(recordingDirectory: recordingDirectory, drainAdmittedFrames: drainAdmittedFrames, onFrame: onFrame)
                do { try checkStart(token) } catch { await callbackSink.finish(); throw error }
                sink = callbackSink
                try await backend.start(requestID: token, configuration: configuration, receive: { callbackSink.consume($0) }, failed: { [weak self] reason in Task { @MainActor in guard self?.generation == token else { return }; self?.stopImmediately(reason: reason) } })
                try checkStart(token)
                startupWatchdog?.cancel(); startupWatchdog = nil
                setPhase(.capturing, configuration.source == .system ? "正在采集系统音频 · 已排除本应用音频" : "正在采集所选麦克风")
                if let duration = maximumCaptureDuration {
                    captureDeadline = Date().addingTimeInterval(max(0.01, duration))
                    durationWatchdog = Task { @MainActor [weak self] in
                        do { try await Task.sleep(nanoseconds: UInt64(max(0.01, duration) * 1_000_000_000)) } catch { return }
                        guard let self, self.generation == token, self.phase == .capturing else { return }
                        await self.pause(reason: "试音时限已到；采集已停止")
                    }
                }
            } catch { if generation == token { await pause(reason: error is CancellationError ? "启动已取消；请手动继续" : error.localizedDescription) }; throw error }
        }, onCancel: { [weak self] in Task { @MainActor in guard self?.generation == token else { return }; self?.stopImmediately(reason: "启动已取消；请手动继续") } })
    }
    private func prepareSink(recordingDirectory: URL?, drainAdmittedFrames: Bool = false, onFrame: @escaping @Sendable (CapturedAudioFrame) -> Bool) async throws -> RawCaptureSink {
        guard let sessionID else { throw CancellationError() }
        if configuration.saveRecording, recordingDirectory == nil { throw AudioFailure.message("保存录音已开启，但没有可写的受管目录。") }
        if originUptime == nil { originUptime = ProcessInfo.processInfo.systemUptime; originOffset = frozenOffset }
        let anchor = currentOffset, epoch = epochID, token = generation, directory = configuration.saveRecording ? recordingDirectory : nil
        if let pauseAt, anchor > pauseAt { onGap?(AudioGap(id: UUID().uuidString, sessionID: sessionID, epochID: epochID, reason: "paused-no-audio", start: pauseAt, end: anchor)) }
        self.pauseAt = nil
        let recorder: AudioRecordingWriter? = try await Task.detached { [weak self] in
            guard let directory else { return nil }
            return try AudioRecordingWriter(directory: directory, session: sessionID, epoch: epoch, offset: anchor) { [weak self] row in DispatchQueue.main.async { self?.onRecording?(row) } }
        }.value
        return RawCaptureSink(epoch: epoch, recorder: recorder, drainAdmittedFrames: drainAdmittedFrames, receive: onFrame, failed: { [weak self] error in Task { @MainActor in guard self?.generation == token else { return }; self?.stopImmediately(reason: error) } }, meter: { [weak self] value in Task { @MainActor in guard let self, self.generation == token, self.phase == .capturing else { return }; if self.level != value { self.level = value } } })
    }
    /// Downstream upload/playback gates must also close synchronously at pause.
    func stopAdmission(preservingAdmittedFrames: Bool = false) { sink?.stop(preservingAdmittedFrames: preservingAdmittedFrames) }
    func pause(reason: String = "用户已暂停；请手动继续") async { if let task = beginPause(reason: reason) { await task.value } }
    private func beginPause(reason: String) -> Task<Void, Never>? {
        guard phase != .ended else { return nil }; if let drainTask { return drainTask }
        generation = UUID(); frozenOffset = currentOffset
        startupWatchdog?.cancel(); startupWatchdog = nil; durationWatchdog?.cancel(); durationWatchdog = nil; captureDeadline = nil
        sink?.stop(); stopPlayback()
        let oldSink = sink; sink = nil; draining = true
        var gap: AudioGap?
        if pauseAt == nil { pauseAt = frozenOffset; if let sessionID { gap = AudioGap(id: UUID().uuidString, sessionID: sessionID, epochID: epochID, reason: reason, start: frozenOffset, end: frozenOffset) } }
        let task = Task { @MainActor in
            do { try await self.backend.stop() } catch { self.stopFailed = true; self.status = "音频硬件停止失败；请退出重开，不能自动继续。" }
            if let error = await oldSink?.finish() {
                self.lastRecordingError = error
                self.status = error
                if let sessionID = self.sessionID { self.onGap?(AudioGap(id: UUID().uuidString, sessionID: sessionID, epochID: self.epochID, reason: "recording-finalization-failed", start: self.frozenOffset, end: self.frozenOffset)) }
            }
            if self.ownsCaptureLease { await self.onDrain?() }
            await withCheckedContinuation { continuation in DispatchQueue.main.async { continuation.resume() } }
            self.draining = false; if self.level != -80 { self.level = -80 }
            if !self.stopFailed { self.coordinator.release(owner: self.ownerID) }
            self.drainTask = nil
        }
        drainTask = task; setPhase(.paused, reason); if let gap { onGap?(gap) }; return task
    }
    func end() async { guard phase != .ended else { return }; stopAdmission(preservingAdmittedFrames: true); await pause(reason: "正在完成音频尾部"); guard !stopFailed else { return }; frozenOffset = currentOffset; originUptime = nil; setPhase(.ended, lastRecordingError ?? "课堂已结束；采集和回听已停止") }
    func interrupt(reason: String) async { await pause(reason: reason) }
    func stopImmediately(reason: String) { _ = beginPause(reason: reason) }
    private func checkMicrophoneHealth() {
        guard phase == .capturing, configuration.source == .microphone, !healthCheckPending else { return }
        healthCheckPending = true; let token = generation, config = configuration
        Task { [weak self] in guard let self else { return }; let reason = await self.backend.microphoneHealth(configuration: config); self.healthCheckPending = false; guard self.generation == token, self.phase == .capturing else { return }; if let reason { self.stopImmediately(reason: reason) } }
    }
    func playRecording(url: URL, from seconds: Double = 0) throws {
        guard phase != .capturing, phase != .starting, !draining, coordinator.owner == nil else { throw AudioFailure.message("请先暂停采集，再明确回听已保存录音。") }
        stopPlayback(); let next = try AVAudioPlayer(contentsOf: url); next.currentTime = max(0, min(seconds, next.duration)); player = next
        guard next.play() else { player = nil; playbackPosition = nil; throw AudioFailure.message("录音无法播放。") }; playbackPosition = next.currentTime
    }
    func pausePlayback() { guard let player else { return }; player.pause(); playbackPaused = true; playbackPosition = player.currentTime }
    func resumePlayback() throws { guard phase != .capturing && phase != .starting, !draining, coordinator.owner == nil, let player else { return }; guard player.play() else { throw AudioFailure.message("录音无法播放。") }; playbackPaused = false; playbackPosition = player.currentTime }
    func stopPlayback() { player?.stop(); player = nil; if playbackPosition != nil { playbackPosition = nil }; if playbackPaused { playbackPaused = false } }
    private func updatePlaybackPosition() { let next = player.flatMap { $0.isPlaying || playbackPaused ? $0.currentTime : nil }; if playbackPosition != next { playbackPosition = next } }
    private func setPhase(_ value: AudioPhase, _ message: String) { let changed = phase != value; if changed { phase = value }; if status != message { status = message }; if changed { onPhaseChanged?(value) } }
    #if AUDIO_TESTING
    func beginSyntheticCapture(sessionID: String, recordingDirectory: URL?, onFrame: @escaping @Sendable (CapturedAudioFrame) -> Bool) async throws -> @Sendable (AVAudioPCMBuffer) -> Void {
        try coordinator.acquire(owner: ownerID, sessionID: sessionID)
        self.sessionID = sessionID; epochID = UUID().uuidString; configuration.saveRecording = recordingDirectory != nil; generation = UUID()
        let next = try await prepareSink(recordingDirectory: recordingDirectory, drainAdmittedFrames: true, onFrame: onFrame)
        sink = next; setPhase(.capturing, "Explicit silent development input")
        return { next.consume($0) }
    }
    func captureBarrierForChecks() async { await sink?.barrier() }
    #endif
}
