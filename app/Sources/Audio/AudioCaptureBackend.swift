import Foundation
import AppKit
import AVFoundation
import AudioToolbox
import CoreAudio
import CoreMedia
import ScreenCaptureKit

/// An app-wide lease. View navigation and individual controllers cannot create
/// concurrent classroom, interpretation, and sound-check capture owners.
@MainActor final class CaptureSessionCoordinator {
    static let shared = CaptureSessionCoordinator()
    private(set) var owner: UUID?
    private(set) var sessionID: String?
    func acquire(owner: UUID, sessionID: String) throws {
        guard self.owner == nil else { throw AudioFailure.message("另一个音频会话正在启动、采集或停止；请先暂停并等待保存完成。") }
        self.owner = owner; self.sessionID = sessionID
    }
    func release(owner: UUID) { if self.owner == owner { self.owner = nil; sessionID = nil } }
}

/// The actual start/pause lifecycle uses this boundary. Tests inject a silent
/// backend here; they do not replace the state machine or native ASR pipeline.
protocol AudioCaptureBackend: AnyObject, Sendable {
    func requestPermission(for source: AudioSource) async throws
    func prepare(requestID: UUID) async throws
    func start(requestID: UUID, configuration: AudioConfiguration, receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void, failed: @escaping @Sendable (String) -> Void) async throws
    func stop() async throws
    func microphoneHealth(configuration: AudioConfiguration) async -> String?
}

private final class SystemAudioReceiver: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let receive: @Sendable (AVAudioPCMBuffer) -> Void
    let failed: @Sendable (String) -> Void
    init(receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void, failed: @escaping @Sendable (String) -> Void) { self.receive = receive; self.failed = failed }
    func stream(_ stream: SCStream, didOutputSampleBuffer sample: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sample.isValid, CMSampleBufferDataIsReady(sample),
              let description = CMSampleBufferGetFormatDescription(sample), let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let format = AVAudioFormat(streamDescription: asbd),
              let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(CMSampleBufferGetNumSamples(sample))) else { return }
        pcm.frameLength = pcm.frameCapacity
        guard CMSampleBufferCopyPCMDataIntoAudioBufferList(sample, at: 0, frameCount: Int32(pcm.frameLength), into: pcm.mutableAudioBufferList) == noErr else { failed("系统音频 PCM 解码失败"); return }
        receive(pcm)
    }
    func stream(_ stream: SCStream, didStopWithError error: Error) { failed("系统采集中断：\(error.localizedDescription)") }
}

/// All synchronous audio-unit/CoreAudio work is confined to this queue.
/// stop() waits for a pending system start to settle before reporting release;
/// a late start can therefore never escape the coordinator's capture lease.
final class HardwareAudioCaptureBackend: AudioCaptureBackend, @unchecked Sendable {
    private let worker = DispatchQueue(label: "local.ulecture.capture-hardware", qos: .userInitiated)
    private var microphone: AUAudioUnit?
    private var stream: SCStream?
    private var systemReceiver: SystemAudioReceiver?
    private var hardwareFormat: AVAudioFormat?, tapFormat: AVAudioFormat?
    private var epoch: UUID?
    private var startPending = false
    private var startWaiters: [CheckedContinuation<Void, Never>] = []

    private func perform<T>(_ work: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in worker.async { continuation.resume(with: Result { try work() }) } }
    }
    func requestPermission(for source: AudioSource) async throws {
        if source == .microphone {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return
            case .notDetermined:
                guard await AVCaptureDevice.requestAccess(for: .audio) else { throw AudioFailure.message("麦克风权限未授予；请在系统设置处理后手动继续。") }
            default: throw AudioFailure.message("麦克风权限不可用；请在系统设置处理。")
            }
        } else if !CGPreflightScreenCaptureAccess() {
            let permitted = try await perform { CGRequestScreenCaptureAccess() }
            guard permitted else { throw AudioFailure.message("系统音频权限未授予；请处理屏幕与系统音频录制权限后重开。") }
        }
    }
    func prepare(requestID: UUID) async throws {
        try await perform {
            guard !self.startPending, self.microphone == nil, self.stream == nil else { throw AudioFailure.message("采集硬件仍在使用或停止中。") }
            self.epoch = requestID
        }
    }
    func start(requestID token: UUID, configuration: AudioConfiguration, receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void, failed: @escaping @Sendable (String) -> Void) async throws {
        try await perform {
            guard self.epoch == token else { throw CancellationError() }
            guard !self.startPending, self.microphone == nil, self.stream == nil else { throw AudioFailure.message("采集硬件仍在使用或停止中。") }
            self.startPending = true
        }
        do {
            if configuration.source == .microphone {
                try await perform {
                    guard self.epoch == token else { throw CancellationError() }
                    try self.startMicrophone(configuration: configuration, receive: receive, failed: failed)
                }
            } else {
                let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
                let candidate: SCStream = try await perform {
                    guard self.epoch == token else { throw CancellationError() }
                    guard let display = content.displays.first else { throw AudioFailure.message("系统音频没有可用显示器捕获范围。") }
                    let own = content.applications.filter { $0.processID == getpid() }
                    let filter = SCContentFilter(display: display, excludingApplications: own, exceptingWindows: [])
                    let config = SCStreamConfiguration(); config.capturesAudio = true; config.excludesCurrentProcessAudio = true
                    // Preserve enough bandwidth for each consumer to resample directly.
                    config.sampleRate = 48000; config.channelCount = 1; config.width = 2; config.height = 2; config.queueDepth = 3
                    config.minimumFrameInterval = CMTime(value: 1, timescale: 1)
                    let receiver = SystemAudioReceiver(receive: receive, failed: failed)
                    let candidate = SCStream(filter: filter, configuration: config, delegate: receiver)
                    try candidate.addStreamOutput(receiver, type: .audio, sampleHandlerQueue: DispatchQueue(label: "local.ulecture.system-pcm"))
                    self.systemReceiver = receiver; self.stream = candidate
                    return candidate
                }
                try await candidate.startCapture()
                try await perform { guard self.epoch == token else { throw CancellationError() } }
            }
            await finishStart()
        } catch { await finishStart(); throw error }
    }
    private func finishStart() async {
        _ = try? await perform {
            self.startPending = false
            let waiters = self.startWaiters; self.startWaiters.removeAll()
            waiters.forEach { $0.resume() }
        }
    }
    private func startMicrophone(configuration: AudioConfiguration, receive: @escaping @Sendable (AVAudioPCMBuffer) -> Void, failed: @escaping @Sendable (String) -> Void) throws {
        dispatchPrecondition(condition: .onQueue(worker))
        guard let selected = configuration.deviceID, classroomInputDevices().contains(where: { $0.id == selected }) else { throw AudioFailure.message("所选输入设备失联；不会自动换设备。") }
        // AVAudioEngine can replace its input unit's device at start with an
        // aggregate based on the system default. Own an input-only AUHAL so the
        // selected device remains authoritative without changing system settings.
        let unit = try AUAudioUnit(componentDescription: AudioComponentDescription(
            componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_HALOutput,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0))
        do {
            unit.isInputEnabled = true
            unit.isOutputEnabled = false
            try unit.setDeviceID(selected)
            guard unit.deviceID == selected else { throw AudioFailure.message("设备回读不符；未切换到默认设备。") }
            // AUHAL element 1 carries input: hardware on the input scope,
            // client PCM on the output scope. Keep the native sample rate.
            let hardware = unit.inputBusses[1].format
            guard hardware.sampleRate > 0, hardware.channelCount > 0,
                  let format = AVAudioFormat(standardFormatWithSampleRate: hardware.sampleRate, channels: hardware.channelCount) else { throw AudioFailure.message("麦克风格式无效。") }
            try unit.outputBusses[1].setFormat(format)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: unit.maximumFramesToRender) else { throw AudioFailure.message("麦克风格式无效。") }
            let render = unit.renderBlock
            var reportedFailure = false // Accessed only by the serial hardware input callback.
            unit.inputHandler = { flags, timestamp, frames, bus in
                guard !reportedFailure else { return }
                guard frames <= buffer.frameCapacity else {
                    reportedFailure = true; failed("麦克风输入超过缓冲容量"); return
                }
                buffer.frameLength = frames
                let status = render(flags, timestamp, frames, bus, buffer.mutableAudioBufferList, nil)
                guard status == noErr else {
                    reportedFailure = true; failed("麦克风 PCM 读取失败：\(status)"); return
                }
                // Consumers copy synchronously before this reusable buffer returns.
                receive(buffer)
            }
            try unit.allocateRenderResources()
            try unit.startHardware()
            guard unit.deviceID == selected else { throw AudioFailure.message("设备回读不符；未切换到默认设备。") }
            microphone = unit; hardwareFormat = hardware; tapFormat = format
        } catch {
            unit.stopHardware(); unit.inputHandler = nil; unit.deallocateRenderResources()
            throw error
        }
    }
    func stop() async throws {
        try await perform { self.epoch = nil }
        await withCheckedContinuation { continuation in
            worker.async {
                if self.startPending { self.startWaiters.append(continuation) }
                else { continuation.resume() }
            }
        }
        let oldStream: SCStream? = try await perform {
            if let unit = self.microphone { unit.stopHardware(); unit.inputHandler = nil; unit.deallocateRenderResources(); self.microphone = nil }
            return self.stream
        }
        if let oldStream { try await oldStream.stopCapture() }
        try await perform { self.stream = nil; self.systemReceiver = nil; self.hardwareFormat = nil; self.tapFormat = nil }
    }
    func microphoneHealth(configuration: AudioConfiguration) async -> String? {
        try? await perform {
            guard let microphone = self.microphone else { return nil }
            if !microphone.isRunning { return "麦克风引擎已停止" }
            if AVCaptureDevice.authorizationStatus(for: .audio) != .authorized { return "麦克风权限已撤销" }
            if !classroomInputDevices().contains(where: { $0.id == configuration.deviceID }) { return "所选设备已拔出；不会自动换设备" }
            if microphone.deviceID != configuration.deviceID { return "麦克风设备与选择不符" }
            if microphone.inputBusses[1].format != self.hardwareFormat || microphone.outputBusses[1].format != self.tapFormat { return "麦克风硬件或采样格式改变" }
            return nil
        }
    }
}
