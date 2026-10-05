import AVFoundation
import Foundation

@MainActor private final class FakePlaybackSink: InterpretationPlaybackSink {
    struct Scheduled {
        let rate: Double
        let channels: [[Float]]
        let played: @MainActor () -> Void
    }
    private(set) var isPlaying = false
    var volume: Float = 0
    private(set) var preparedFormats: [AVAudioFormat] = []
    private(set) var scheduled: [Scheduled] = []
    private(set) var activeIndices: [Int] = []
    private(set) var plays = 0, clears = 0, stops = 0
    var failPreparation = false
    func prepare(format: AVAudioFormat) throws {
        if failPreparation { throw InterpretationFailure.invalidAudio }
        preparedFormats.append(format)
    }
    func schedule(_ buffer: AVAudioPCMBuffer, played: @escaping @MainActor () -> Void) {
        let channels = (0..<Int(buffer.format.channelCount)).map { index in
            Array(UnsafeBufferPointer(start: buffer.floatChannelData![index], count: Int(buffer.frameLength)))
        }
        activeIndices.append(scheduled.count)
        scheduled.append(Scheduled(rate: buffer.format.sampleRate, channels: channels, played: played))
    }
    func play() { isPlaying = true; plays += 1 }
    func clear() { activeIndices.removeAll(); isPlaying = false; clears += 1 }
    func stop() { activeIndices.removeAll(); isPlaying = false; stops += 1 }
    /// Deliberately permits duplicate/late callbacks after clear/stop.
    func complete(_ index: Int) {
        activeIndices.removeAll { $0 == index }
        scheduled[index].played()
    }
}

@MainActor private final class ManualPlaybackClock {
    private struct Deadline {
        let time: TimeInterval
        let action: @MainActor () -> Void
        var cancelled = false
        var fired = false
    }
    private var deadlines: [Deadline] = []
    private(set) var now = 0.0
    private(set) var requestedDelays: [TimeInterval] = []
    var activeCount: Int { deadlines.filter { !$0.cancelled && !$0.fired }.count }
    var count: Int { deadlines.count }
    func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> @MainActor () -> Void {
        let index = deadlines.count
        deadlines.append(Deadline(time: now + delay, action: action))
        requestedDelays.append(delay)
        return { [weak self] in self?.deadlines[index].cancelled = true }
    }
    func advance(to time: TimeInterval) {
        precondition(time >= now); now = time
        let due = deadlines.indices.filter { !deadlines[$0].cancelled && !deadlines[$0].fired && deadlines[$0].time <= now }
        for index in due { deadlines[index].fired = true; deadlines[index].action() }
    }
    /// Simulates a cancellation race in a scheduler that already queued its work.
    func fireEvenIfCancelled(_ index: Int) { deadlines[index].action() }
}

@main struct InterpretationAudioPlayerChecks {
    @MainActor static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1])
        var cases: [String] = []
        func require(_ condition: Bool, _ message: String) throws { if !condition { throw InterpretationFailureCheck(message: message) } }
        func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 0.00000001 }
        func pcm(_ samples: [Int16]) -> Data {
            var result = Data(capacity: samples.count * 2)
            for sample in samples {
                let bits = UInt16(bitPattern: sample)
                result.append(UInt8(bits & 255)); result.append(UInt8(bits >> 8))
            }
            return result
        }
        func silence(frames: Int, channels: Int = 1) -> Data { Data(repeating: 0, count: frames * channels * 2) }
        func fixture() -> (InterpretationAudioPlayer, FakePlaybackSink, ManualPlaybackClock) {
            let sink = FakePlaybackSink(), clock = ManualPlaybackClock()
            let player = InterpretationAudioPlayer(sink: sink, schedule: { delay, action in clock.schedule(after: delay, action: action) })
            return (player, sink, clock)
        }

        do {
            let (player, sink, _) = fixture(); let generation = UUID(); player.begin(generation: generation)
            try player.enqueue(pcm([Int16.min, -1, 0, 1, 16384, Int16.max]), sampleRate: 24000, channels: 1, generation: generation)
            let values = sink.scheduled[0].channels[0]
            let expectedMono: [Float] = [-1, Float(-1) / 32768, 0, Float(1) / 32768, 0.5, Float(32767) / 32768]
            try require(values == expectedMono, "Signed PCM16 little-endian decoding changed")
            try require(sink.scheduled[0].rate == 24000 && sink.scheduled[0].channels.count == 1, "Mono format changed")
            try player.enqueue(pcm([Int16.min, Int16.max, 16384, -16384]), sampleRate: 48000, channels: 2, generation: generation)
            let stereo = sink.scheduled[1]
            let expectedStereo: [[Float]] = [[-1, 0.5], [Float(32767) / 32768, -0.5]]
            try require(stereo.rate == 48000 && stereo.channels == expectedStereo, "Stereo interleaving or rate changed")
            try require(sink.activeIndices == [1], "Changing format retained incompatible scheduled audio")
            var played = 0.0; player.onPlayed = { played += $0 }
            sink.complete(0)
            try require(played == 0 && close(player.queuedSeconds, 2 / 48000.0), "Old-format completion changed new queue accounting")
            player.stop(); cases.append("PCM16 LE signed extrema, mono/stereo channel mapping and sample-rate change")
        }
        do {
            let (player, sink, _) = fixture(); let generation = UUID(); player.begin(generation: generation)
            let invalid: [(Data, Int, Int)] = [
                (Data(), 24000, 1), (Data([0]), 24000, 1), (Data([0, 0]), 24000, 2),
                (Data([0, 0]), 7999, 1), (Data([0, 0]), 96001, 1), (Data([0, 0]), 24000, 0),
                (Data([0, 0]), 24000, -1), (Data(repeating: 0, count: 6), 24000, 3)
            ]
            for (bytes, rate, channels) in invalid {
                var rejected = false
                do { try player.enqueue(bytes, sampleRate: rate, channels: channels, generation: generation) }
                catch InterpretationFailure.invalidAudio { rejected = true }
                try require(rejected, "Invalid PCM format reached the sink")
            }
            try require(sink.preparedFormats.isEmpty && sink.scheduled.isEmpty && player.queuedSeconds == 0, "Invalid input opened a sink or changed queued audio")
            sink.failPreparation = true
            var failed = false
            do { try player.enqueue(silence(frames: 4800), sampleRate: 24000, channels: 1, generation: generation) }
            catch InterpretationFailure.invalidAudio { failed = true }
            try require(failed && sink.scheduled.isEmpty && player.queuedSeconds == 0, "Sink start failure scheduled or counted unplayed audio")
            player.stop(); cases.append("Invalid frame alignment/rate/channels/empty PCM and sink start failure")
        }
        do {
            let (player, sink, clock) = fixture(); let generation = UUID(); player.begin(generation: generation)
            try player.enqueue(silence(frames: 1592), sampleRate: 8000, channels: 1, generation: generation)
            try require(sink.plays == 0 && close(player.queuedSeconds, 0.199), "199 ms audio played before the 200 ms buffer threshold")
            try require(clock.requestedDelays == [0.2] && clock.activeCount == 1, "Prebuffer deadline differs from 200 ms")
            clock.advance(to: 0.199)
            try require(sink.plays == 0, "Short-buffer deadline fired early")
            try player.enqueue(silence(frames: 8), sampleRate: 8000, channels: 1, generation: generation)
            try require(sink.plays == 1 && close(player.queuedSeconds, 0.2) && clock.activeCount == 0, "Exactly 200 ms did not begin playback/cancel deadline")
            clock.fireEvenIfCancelled(0)
            try require(sink.plays == 1, "Cancelled prebuffer timer started playback twice")
            var played: [Double] = []; player.onPlayed = { played.append($0) }
            sink.complete(0); sink.complete(0); sink.complete(1)
            try require(played.count == 2 && close(played.reduce(0, +), 0.2) && close(player.queuedSeconds, 0), "Played accounting duplicated or retained a completed buffer")
            player.stop(); cases.append("Actual 200 ms threshold, timer cancellation, played accounting and duplicate completion")
        }
        do {
            let (player, sink, clock) = fixture(); let generation = UUID(); player.begin(generation: generation)
            try player.enqueue(silence(frames: 1200), sampleRate: 24000, channels: 1, generation: generation)
            clock.advance(to: 0.199)
            try require(sink.plays == 0 && close(player.queuedSeconds, 0.05), "50 ms utterance played early")
            clock.advance(to: 0.2)
            try require(sink.plays == 1, "Sub-threshold utterance was stranded after 200 ms")
            player.stop(); cases.append("Short 50 ms utterance plays at the 200 ms deadline")
        }
        do {
            let (player, sink, _) = fixture(); let generation = UUID(); player.begin(generation: generation)
            var skipped: [Double] = [], played: [Double] = []
            player.onSkipped = { skipped.append($0) }; player.onPlayed = { played.append($0) }
            try player.enqueue(silence(frames: 48000), sampleRate: 24000, channels: 1, generation: generation)
            try player.enqueue(silence(frames: 24000), sampleRate: 24000, channels: 1, generation: generation)
            try require(skipped.isEmpty && close(player.queuedSeconds, 3), "Exactly three seconds was rejected")
            try player.enqueue(silence(frames: 4800), sampleRate: 24000, channels: 1, generation: generation)
            try require(skipped == [3] && sink.activeIndices == [2] && close(player.queuedSeconds, 0.2), "Accumulated backlog did not clear to fresh audio/report skipped duration")
            sink.complete(0); sink.complete(1)
            try require(played.isEmpty && close(player.queuedSeconds, 0.2), "Backlog completion counted discarded audio")
            let before = sink.scheduled.count
            try player.enqueue(silence(frames: 72001), sampleRate: 24000, channels: 1, generation: generation)
            try require(sink.scheduled.count == before && skipped.count == 2 && close(skipped[1], 72001 / 24000.0) && close(player.queuedSeconds, 0.2), "One oversized chunk was scheduled or erased fresh audio")
            sink.complete(2)
            try require(played == [0.2] && player.queuedSeconds == 0, "Fresh audio accounting after backlog reset failed")
            player.stop(); cases.append("Three-second backlog cap, one oversized chunk, skipped duration and old-queue callbacks")
        }
        do {
            let (player, sink, clock) = fixture(); let generation = UUID(); player.begin(generation: generation)
            var played = 0.0; player.onPlayed = { played += $0 }
            try player.enqueue(silence(frames: 1200), sampleRate: 24000, channels: 1, generation: generation)
            player.enabled = false
            try require(sink.activeIndices.isEmpty && player.queuedSeconds == 0 && clock.activeCount == 0, "Disabling playback did not clear audio/deadline")
            try player.enqueue(silence(frames: 4800), sampleRate: 24000, channels: 1, generation: generation)
            try require(sink.scheduled.count == 1, "Disabled playback buffered later audio")
            player.enabled = true
            clock.fireEvenIfCancelled(0); sink.complete(0)
            try require(sink.plays == 0 && played == 0, "Re-enabling resurrected old timer/audio/completion")
            try player.enqueue(silence(frames: 4800), sampleRate: 24000, channels: 1, generation: generation)
            try require(sink.plays == 1 && sink.activeIndices == [1], "Re-enabling did not accept only new audio")
            sink.complete(1)
            try require(close(played, 0.2), "New playback after enable was not counted")
            player.stop(); cases.append("Playback off/on clears previous audio and only plays newly received data")
        }
        do {
            let (player, sink, clock) = fixture(); let old = UUID(), new = UUID(); player.begin(generation: old)
            var played = 0.0; player.onPlayed = { played += $0 }
            try player.enqueue(silence(frames: 1200), sampleRate: 24000, channels: 1, generation: old)
            player.begin(generation: new)
            try player.enqueue(silence(frames: 4800), sampleRate: 24000, channels: 1, generation: old)
            clock.fireEvenIfCancelled(0); sink.complete(0)
            try require(sink.scheduled.count == 1 && sink.plays == 0 && played == 0, "Previous session audio/deadline/completion escaped generation guard")
            try player.enqueue(silence(frames: 1200), sampleRate: 24000, channels: 1, generation: new)
            player.stop()
            let stoppedPlays = sink.plays
            clock.fireEvenIfCancelled(1); sink.complete(1)
            try player.enqueue(silence(frames: 4800), sampleRate: 24000, channels: 1, generation: new)
            try require(sink.plays == stoppedPlays && sink.scheduled.count == 2 && played == 0 && player.queuedSeconds == 0 && !sink.isPlaying, "Stop allowed late playback/accounting or accepted more data")
            cases.append("Session generation and stopped epoch reject late timer/buffer callbacks and new input")
        }
        do {
            let (player, sink, _) = fixture()
            try require(sink.volume == 0.8, "Default volume was not forwarded")
            for (input, expected): (Float, Float) in [(0, 0), (0.35, 0.35), (1, 1), (-1, 0), (2, 1), (.nan, 0), (.infinity, 0), (-.infinity, 0)] {
                player.volume = input
                try require(sink.volume == expected, "Volume was not clamped/forwarded")
            }
            player.stop(); cases.append("Default volume, valid changes, clamping and non-finite values")
        }
        let report: [String: Any] = [
            "suite": "InterpretationAudioPlayerChecks", "checks": cases, "passed": cases.count,
            "productionPlayer": true, "injectedSink": true, "deterministicManualClock": true,
            "prebufferSeconds": 0.2, "maximumQueueSeconds": 3,
            "realAVAudioEngineConstructed": false, "physicalPlayback": false, "microphoneCapture": false, "providerRequests": 0,
            "doesNotProve": "Physical speaker/device behavior, actual audible quality, real-world timing or ScreenCaptureKit feedback exclusion"
        ]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: directory.appendingPathComponent("audio-player-checks.json"))
        print("PASS: \(cases.count) actual InterpretationAudioPlayer scenarios; deterministic sink/clock; zero audio engines, playback, capture or network")
    }
}

private struct InterpretationFailureCheck: Error { let message: String }
