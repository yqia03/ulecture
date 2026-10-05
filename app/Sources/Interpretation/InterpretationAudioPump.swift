import Foundation
import AVFoundation

/// At most two seconds are admitted, including the chunk currently being sent.
/// Only one send task exists. Capture never creates a task per PCM sample/buffer.
final class InterpretationAudioPump: @unchecked Sendable {
    private let lock = NSLock()
    private let conversionLock = NSLock()
    private let converter: AudioPCMConverter
    private var chunker: InterpretationPCMChunker
    private var pending: [Data] = []
    private var pendingSeconds = 0.0
    private var sendingSeconds = 0.0
    private var accepting = true
    private var draining = false
    private var drainResult: Bool?
    private var drainWaiters: [CheckedContinuation<Bool, Never>] = []
    private var pumping = false
    private let format: InterpretationPCMFormat
    private let send: @MainActor (Data) async throws -> Void
    private let failed: @MainActor (InterpretationFailure) -> Void

    init(provider: InterpretationProvider, send: @escaping @MainActor (Data) async throws -> Void,
         failed: @escaping @MainActor (InterpretationFailure) -> Void) {
        format = provider.inputFormat
        converter = AudioPCMConverter(targetSampleRate: Double(provider.inputFormat.sampleRate))
        chunker = InterpretationPCMChunker(format: provider.inputFormat, chunkMilliseconds: provider.inputChunkMilliseconds)
        self.send = send; self.failed = failed
    }

    func append(_ frame: CapturedAudioFrame) -> Bool {
        lock.lock()
        guard accepting else { lock.unlock(); return false }
        guard pendingSeconds + frame.duration <= 2 else {
            accepting = false; pending.removeAll(); lock.unlock()
            Task { @MainActor in self.failed(.bufferOverflow) }
            return false
        }
        pendingSeconds += frame.duration
        lock.unlock()
        conversionLock.lock(); defer { conversionLock.unlock() }
        do {
            let samples = try converter.convert(frame.pcm)
            let chunks = chunker.append(Self.encode(samples))
            lock.lock()
            guard accepting else { lock.unlock(); return false }
            pending.append(contentsOf: chunks)
            let launch = !pumping && !pending.isEmpty
            if launch { pumping = true }
            lock.unlock()
            if launch { Task { @MainActor in await self.pump() } }
            return true
        } catch {
            stop()
            Task { @MainActor in self.failed(.invalidAudio) }
            return false
        }
    }

    /// Synchronous admission barrier. In-flight writes cannot be recalled, but
    /// no queued or later frame may initiate another send after this returns.
    @discardableResult func stop() -> Double {
        lock.lock()
        let dropped = max(0, pendingSeconds - sendingSeconds)
        accepting = false; draining = false; pending.removeAll(); pendingSeconds = 0
        if drainResult == nil { drainResult = false }
        let waiters = drainWaiters; drainWaiters.removeAll()
        lock.unlock()
        for waiter in waiters { waiter.resume(returning: false) }
        return dropped
    }

    /// Only normal end drains already admitted input. Pause always calls stop().
    /// The caller first closes capture admission and waits for its frame barrier.
    @MainActor func finish(timeout: TimeInterval = 2) async -> Bool {
        prepareFinish()
        let watchdog = Task { @MainActor in
            do { try await Task.sleep(nanoseconds: UInt64(max(0.001, timeout) * 1_000_000_000)) } catch { return }
            self.stop()
        }
        defer { watchdog.cancel() }
        return await withCheckedContinuation { continuation in
            lock.lock()
            if let result = drainResult { lock.unlock(); continuation.resume(returning: result) }
            else { drainWaiters.append(continuation); lock.unlock() }
        }
    }

    private func prepareFinish() {
        conversionLock.lock(); defer { conversionLock.unlock() }
        lock.lock()
        guard accepting else { lock.unlock(); return }
        accepting = false; draining = true
        lock.unlock()
        do {
            var chunks = chunker.append(Self.encode(try converter.finish()))
            if let tail = try chunker.flush() { chunks.append(tail) }
            lock.lock()
            guard draining else { lock.unlock(); return }
            pending.append(contentsOf: chunks)
            let launch = !pumping
            if launch { pumping = true }
            lock.unlock()
            if launch { Task { @MainActor in await self.pump() } }
        } catch {
            stop()
            Task { @MainActor in self.failed(.invalidAudio) }
        }
    }

    private static func encode(_ samples: [Float]) -> Data {
        var bytes = Data(capacity: samples.count * 2)
        for sample in samples {
            let finite = sample.isFinite ? max(-1, min(1, sample)) : 0
            let pcm = Int16(max(-32768, min(32767, Int((finite * 32768).rounded()))))
            let bits = UInt16(bitPattern: pcm)
            bytes.append(UInt8(bits & 255)); bytes.append(UInt8(bits >> 8))
        }
        return bytes
    }

    private func next() -> Data? {
        lock.lock()
        guard accepting || draining, !pending.isEmpty else {
            pumping = false
            let successful = draining && pending.isEmpty
            if successful { draining = false; drainResult = true }
            let waiters = successful ? drainWaiters : []; if successful { drainWaiters.removeAll() }
            lock.unlock()
            for waiter in waiters { waiter.resume(returning: true) }
            return nil
        }
        let bytes = pending.removeFirst()
        sendingSeconds = Double(bytes.count) / Double(format.bytesPerSecond)
        lock.unlock()
        return bytes
    }
    private func sent(_ seconds: Double) {
        lock.lock(); sendingSeconds = 0; pendingSeconds = max(0, pendingSeconds - seconds); lock.unlock()
    }
    @MainActor private func pump() async {
        while let bytes = next() {
            do {
                try await send(bytes)
                sent(Double(bytes.count) / Double(format.bytesPerSecond))
            } catch {
                stop(); failed(InterpretationFailure.fromTransport(error)); return
            }
        }
    }
}
