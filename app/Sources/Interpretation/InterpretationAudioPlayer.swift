import AVFoundation
import Foundation

@MainActor protocol InterpretationAudioPlaying: AnyObject {
    var enabled: Bool { get set }
    var volume: Float { get set }
    var onPlayed: ((Double) -> Void)? { get set }
    var onSkipped: ((Double) -> Void)? { get set }
    func begin(generation: UUID)
    func enqueue(_ data: Data, sampleRate: Int, channels: Int, generation: UUID) throws
    func stop()
}

/// The only boundary allowed to touch an output device. The player owns PCM
/// validation, buffering and completion accounting; a sink only plays buffers.
@MainActor protocol InterpretationPlaybackSink: AnyObject {
    var isPlaying: Bool { get }
    var volume: Float { get set }
    func prepare(format: AVAudioFormat) throws
    func schedule(_ buffer: AVAudioPCMBuffer, played: @escaping @MainActor () -> Void)
    func play()
    func clear()
    func stop()
}

/// In-process output remains covered by ScreenCaptureKit's app exclusion.
@MainActor private final class AVAudioInterpretationPlaybackSink: InterpretationPlaybackSink {
    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    var isPlaying: Bool { node.isPlaying }
    var volume: Float { get { node.volume } set { node.volume = newValue } }
    init() { engine.attach(node) }
    func prepare(format: AVAudioFormat) throws {
        if self.format != format {
            node.stop(); engine.stop(); engine.disconnectNodeOutput(node)
            engine.connect(node, to: engine.mainMixerNode, format: format)
            self.format = format
        }
        if !engine.isRunning { try engine.start() }
    }
    func schedule(_ buffer: AVAudioPCMBuffer, played: @escaping @MainActor () -> Void) {
        node.scheduleBuffer(buffer, completionCallbackType: .dataPlayedBack) { _ in Task { @MainActor in played() } }
    }
    func play() { node.play() }
    func clear() { node.stop() }
    func stop() { node.stop(); engine.stop() }
}

/// Returns a cancellation closure. An injected clock can deterministically
/// advance the production player's actual deadline without opening audio output.
typealias InterpretationPlaybackSchedule = @MainActor (TimeInterval, @escaping @MainActor () -> Void) -> (@MainActor () -> Void)

/// Playback accounting is distinct from provider generation and billable use.
@MainActor final class InterpretationAudioPlayer: InterpretationAudioPlaying {
    var enabled = true { didSet { if !enabled { clearQueue() } } }
    var volume: Float = 0.8 { didSet { sink.volume = Self.clampedVolume(volume) } }
    var onPlayed: ((Double) -> Void)?
    var onSkipped: ((Double) -> Void)?
    private let sink: InterpretationPlaybackSink
    private let schedule: InterpretationPlaybackSchedule
    private var generation: UUID?
    private var playbackEpoch = UUID()
    private var format: AVAudioFormat?
    private var pendingBuffers: [UUID: Double] = [:]
    private(set) var queuedSeconds = 0.0
    private let prebufferSeconds = 0.2
    private let maximumQueueSeconds = 3.0
    private var cancelPrebuffer: (@MainActor () -> Void)?

    init(sink: InterpretationPlaybackSink? = nil, schedule: InterpretationPlaybackSchedule? = nil) {
        self.sink = sink ?? AVAudioInterpretationPlaybackSink()
        self.schedule = schedule ?? Self.scheduleDeadline
        self.sink.volume = Self.clampedVolume(volume)
    }

    private static func clampedVolume(_ value: Float) -> Float { max(0, min(1, value.isFinite ? value : 0)) }
    private static func scheduleDeadline(after seconds: TimeInterval, action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let task = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) } catch { return }
            guard !Task.isCancelled else { return }
            action()
        }
        return { task.cancel() }
    }

    func begin(generation: UUID) {
        stop()
        self.generation = generation
    }

    func enqueue(_ data: Data, sampleRate: Int, channels: Int, generation: UUID) throws {
        guard self.generation == generation, enabled else { return }
        guard (8_000...96_000).contains(sampleRate), (1...2).contains(channels),
              !data.isEmpty, data.count % (2 * channels) == 0,
              let nextFormat = AVAudioFormat(standardFormatWithSampleRate: Double(sampleRate), channels: AVAudioChannelCount(channels)) else {
            throw InterpretationFailure.invalidAudio
        }
        let frames = data.count / (2 * channels)
        let duration = Double(frames) / Double(sampleRate)
        if duration > maximumQueueSeconds { onSkipped?(duration); return }
        if queuedSeconds + duration > maximumQueueSeconds {
            let skipped = queuedSeconds
            clearQueue()
            onSkipped?(skipped)
        }
        if format != nextFormat {
            clearQueue()
            format = nextFormat
        }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: nextFormat, frameCapacity: AVAudioFrameCount(frames)), let destination = buffer.floatChannelData else {
            throw InterpretationFailure.invalidAudio
        }
        buffer.frameLength = AVAudioFrameCount(frames)
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for frame in 0..<frames {
                for channel in 0..<channels {
                    let offset = (frame * channels + channel) * 2
                    let value = Int16(bitPattern: UInt16(bytes[offset]) | (UInt16(bytes[offset + 1]) << 8))
                    destination[channel][frame] = Float(value) / 32768
                }
            }
        }
        try sink.prepare(format: nextFormat)
        let bufferID = UUID(), epoch = playbackEpoch
        pendingBuffers[bufferID] = duration
        queuedSeconds += duration
        sink.schedule(buffer) { [weak self] in
            guard let self, self.playbackEpoch == epoch, self.generation == generation, self.enabled,
                  let playedDuration = self.pendingBuffers.removeValue(forKey: bufferID) else { return }
            self.queuedSeconds = max(0, self.queuedSeconds - playedDuration)
            self.onPlayed?(playedDuration)
        }
        if !sink.isPlaying {
            if queuedSeconds >= prebufferSeconds {
                cancelPrebuffer?(); cancelPrebuffer = nil; sink.play()
            } else if cancelPrebuffer == nil {
                // A final short utterance must not wait forever below 200 ms.
                cancelPrebuffer = schedule(prebufferSeconds) { [weak self] in
                    guard let self, self.playbackEpoch == epoch, self.generation == generation, self.enabled else { return }
                    self.cancelPrebuffer = nil
                    if self.queuedSeconds > 0, !self.sink.isPlaying { self.sink.play() }
                }
            }
        }
    }

    func stop() {
        generation = nil
        clearQueue()
        sink.stop()
    }

    private func clearQueue() {
        cancelPrebuffer?(); cancelPrebuffer = nil
        playbackEpoch = UUID()
        pendingBuffers.removeAll()
        sink.clear()
        queuedSeconds = 0
    }
}
