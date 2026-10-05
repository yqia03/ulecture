import Foundation
import AVFoundation

struct AudioTranscript: Codable, Identifiable {
    let id: String, sessionID: String, epochID: String, language: String, text: String
    let sequence: Int, revision: Int
    let start: Double, end: Double, confirmedAt: Date
    var replacesProvisionalID: String? = nil
}
/// A draft belongs to an utterance, never to the latest UI string.
struct AudioProvisional: Equatable {
    let id: String, epochID: String, text: String
    let revision: Int
    let start: Double
}
struct AudioGap: Codable, Identifiable {
    let id: String, sessionID: String, epochID: String, reason: String
    let start: Double, end: Double
}
struct AudioRecording: Codable, Identifiable {
    let id: String, sessionID: String, epochID: String, filename: String
    let start: Double, end: Double, frames: Int64, verified: Bool
}

final class AudioRecordingWriter {
    private let directory: URL, session: String, epoch: String, offset: Double
    private var file: AVAudioFile?, fileURL: URL?, chunkID = ""
    private var totalFrames: Int64 = 0, chunkFrames: Int64 = 0
    private let format = AVAudioFormat(standardFormatWithSampleRate: 16000, channels: 1)!
    let completed: (AudioRecording) -> Void
    init(directory: URL, session: String, epoch: String, offset: Double, completed: @escaping (AudioRecording) -> Void) throws {
        self.directory = directory; self.session = session; self.epoch = epoch; self.offset = offset; self.completed = completed
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    func append(_ samples: [Float]) throws {
        var cursor = 0
        while cursor < samples.count {
            if file == nil {
                chunkID = UUID().uuidString
                // Filename contains timing so interrupted files can be recovered by a scanner.
                fileURL = directory.appendingPathComponent("\(epoch)_\(Int((offset + Double(totalFrames) / 16000) * 1000))_\(chunkID).caf")
                file = try AVAudioFile(forWriting: fileURL!, settings: format.settings)
            }
            let count = min(samples.count - cursor, 160000 - Int(chunkFrames))
            let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!; buffer.frameLength = AVAudioFrameCount(count)
            samples.withUnsafeBufferPointer { source in buffer.floatChannelData![0].update(from: source.baseAddress!.advanced(by: cursor), count: count) }
            try file!.write(from: buffer); chunkFrames += Int64(count); totalFrames += Int64(count); cursor += count
            if chunkFrames == 160000 { try finishChunk() }
        }
    }
    private func finishChunk() throws {
        guard let url = fileURL else { return }
        file = nil
        let read = try AVAudioFile(forReading: url)
        guard read.length == chunkFrames else { throw AudioFailure.message("录音回读帧数不符；已暂停，损坏尾部保留。") }
        if chunkFrames > 0 {
            completed(AudioRecording(id: chunkID, sessionID: session, epochID: epoch, filename: url.lastPathComponent, start: offset + Double(totalFrames - chunkFrames) / 16000, end: offset + Double(totalFrames) / 16000, frames: chunkFrames, verified: true))
        }
        fileURL = nil; chunkFrames = 0
    }
    func finish() throws { try finishChunk() }
}

/// All inference receives Float32 mono PCM directly; the only disk-audio path is the explicit writer.
final class AudioPipeline: @unchecked Sendable {
    struct Limits { var maximumUtteranceSeconds: Double = 24; var silenceSeconds: Double = 0.7; var maximumQueuedFinals = 3; var provisionalSeconds: Double = 4 }
    private struct Window { let id: String; let samples: [Float]; let offset: Double; let final: Bool }
    private let queue = DispatchQueue(label: "local.uway.classroom.pcm", qos: .userInitiated)
    private let voiceDetector: UnsafeMutableRawPointer
    private let admission = NSLock()
    private var admittedSamples = 0, accepting = true
    private let engine: ASREngine, session: String, epoch: String, language: String, anchor: Double, limits: Limits
    private var cursor = 0, utteranceStart = 0, silence = 0, nextProvisional = 0
    private var pendingPCM: [Float] = [], preRoll: [Float] = [], utterance: [Float] = []
    private var finals: [Window] = [], provisionalWindow: Window?, busy = false
    private var stopped = false, stopCompletions: [() -> Void] = []
    private var previousText = ""
    private var utteranceID = UUID().uuidString, provisionalRevision = 0
    private var sequence = 0, emitted = Set<String>(), committedUntil: Double = 0
    private var recorder: AudioRecordingWriter?
    private var maxQueueObserved = 0, failureReported = false
    let onConfirmed: (AudioTranscript) -> Void, onProvisional: (String) -> Void, onGap: (AudioGap) -> Void, onError: (String) -> Void
    private let onCaptionProvisional: ((AudioProvisional) -> Void)?
    init(engine: ASREngine, sessionID: String, epochID: String, language: String, anchor: Double, recordingDirectory: URL?, limits: Limits = Limits(), onConfirmed: @escaping (AudioTranscript) -> Void, onProvisional: @escaping (String) -> Void, onGap: @escaping (AudioGap) -> Void, onRecording: @escaping (AudioRecording) -> Void, onError: @escaping (String) -> Void, onCaptionProvisional: ((AudioProvisional) -> Void)? = nil) throws {
        guard let detector = classroom_vad_open(engine.vadURL.path) else { throw AudioFailure.message("流式语音活动模型加载失败。") }; voiceDetector = detector
        self.engine = engine; session = sessionID; epoch = epochID; self.language = language; self.anchor = anchor; self.limits = limits
        self.onCaptionProvisional = onCaptionProvisional
        self.onConfirmed = onConfirmed; self.onProvisional = onProvisional; self.onGap = onGap; self.onError = onError
        if let recordingDirectory { recorder = try AudioRecordingWriter(directory: recordingDirectory, session: sessionID, epoch: epochID, offset: anchor, completed: onRecording) }
    }
    deinit { classroom_vad_close(voiceDetector) }
    /// Live input admission is capped at two seconds before work is enqueued.
    @discardableResult func append(_ samples: [Float], bounded: Bool = true) -> Bool {
        admission.lock()
        guard accepting else { admission.unlock(); return false }
        if bounded && admittedSamples + samples.count > 32000 {
            accepting = false; admission.unlock()
            queue.async { self.fail("输入缓冲超过两秒；已停止接收，请手动继续。", from: self.anchor + Double(self.cursor)/16000, length: Double(samples.count)/16000) }
            return false
        }
        admittedSamples += samples.count; admission.unlock()
        queue.async {
            self.admission.lock(); self.admittedSamples -= samples.count; self.admission.unlock()
            guard !self.stopped else { return }
            do { try self.recorder?.append(samples) } catch { self.fail("录音写入失败：\(error.localizedDescription)", from: self.anchor + Double(self.cursor)/16000, length: Double(samples.count)/16000); return }
            self.pendingPCM.append(contentsOf: samples)
            while self.pendingPCM.count >= 512 {
                let frame = Array(self.pendingPCM.prefix(512)); self.pendingPCM.removeFirst(512); self.process(frame)
            }
        }
        return true
    }
    func barrier() async { await withCheckedContinuation { continuation in queue.async { continuation.resume() } } }
    private func process(_ frame: [Float]) {
        let rms = sqrt(frame.reduce(0.0) { $0 + Double($1 * $1) } / Double(frame.count))
        let probability = frame.withUnsafeBufferPointer { classroom_vad_probability(voiceDetector, $0.baseAddress, Int32($0.count)) }
        if probability < 0 { fail("流式语音活动检测失败", from: anchor + Double(cursor)/16000, length: Double(frame.count)/16000); return }
        let voiced = rms >= 0.0002 && probability >= 0.5
        if utterance.isEmpty {
            if voiced {
                utteranceID = UUID().uuidString; utteranceStart = cursor - preRoll.count; utterance = preRoll; utterance.append(contentsOf: frame)
                preRoll.removeAll(keepingCapacity: true); silence = 0; nextProvisional = Int(limits.provisionalSeconds * 16000)
            } else { preRoll.append(contentsOf: frame); if preRoll.count > 3200 { preRoll.removeFirst(preRoll.count - 3200) } }
        } else {
            utterance.append(contentsOf: frame); silence = voiced ? 0 : silence + frame.count
            if silence >= Int(limits.silenceSeconds * 16000) {
                finalizeUtterance(carryOverlap: false)
            } else if utterance.count >= Int(limits.maximumUtteranceSeconds * 16000) {
                finalizeUtterance(carryOverlap: true)
            } else if utterance.count >= nextProvisional {
                provisionalWindow = Window(id: utteranceID, samples: utterance, offset: anchor + Double(utteranceStart)/16000, final: false)
                nextProvisional += Int(limits.provisionalSeconds * 16000); pump()
            }
        }
        cursor += frame.count
    }
    private func finalizeUtterance(carryOverlap: Bool) {
        guard !utterance.isEmpty else { return }
        let window = Window(id: utteranceID, samples: utterance, offset: anchor + Double(utteranceStart)/16000, final: true)
        if finals.count >= limits.maximumQueuedFinals {
            onGap(AudioGap(id: UUID().uuidString, sessionID: session, epochID: epoch, reason: "asr-overload-audio-not-transcribed", start: window.offset, end: window.offset + Double(window.samples.count)/16000))
        } else { finals.append(window); maxQueueObserved = max(maxQueueObserved, finals.count) }
        let overlap = carryOverlap ? Array(utterance.suffix(min(8000, max(0, utterance.count / 3)))) : []
        utteranceStart += utterance.count - overlap.count; utterance = overlap; utteranceID = UUID().uuidString
        silence = 0; nextProvisional = Int(limits.provisionalSeconds * 16000); provisionalWindow = nil; pump()
    }
    private func pump() {
        guard !busy else { return }
        let job: Window?
        if !finals.isEmpty { job = finals.removeFirst() }
        else { job = provisionalWindow; provisionalWindow = nil }
        guard let job else { finishIfDrained(); return }
        busy = true
        engine.recognize(job.samples, language: language) { result in
            self.queue.async {
                self.busy = false
                switch result {
                case .failure(let error): self.onGap(AudioGap(id: UUID().uuidString, sessionID: self.session, epochID: self.epoch, reason: "asr-failed-unconfirmed-tail", start: job.offset, end: job.offset + Double(job.samples.count)/16000)); self.onError(error.localizedDescription)
                case .success(let rows):
                    if job.final {
                        for (index, row) in rows.enumerated() {
                            let id = "\(self.epoch)-\(job.id)-\(index)"
                            // Forced-window overlap has one owner: previously committed time wins.
                            let end = job.offset + row.end
                            guard end > self.committedUntil + 0.02, self.emitted.insert(id).inserted else { continue }
                            let start = max(self.committedUntil, job.offset + row.start)
                            let overlaps = job.offset + row.start < self.committedUntil
                            let text = overlaps ? Self.removeRepeatedOverlap(previous: self.previousText, current: row.text, language: self.language) : row.text
                            self.committedUntil = end
                            guard !text.isEmpty else { continue }
                            self.sequence += 1; self.previousText = text
                            self.onConfirmed(AudioTranscript(id: id, sessionID: self.session, epochID: self.epoch, language: self.language, text: text, sequence: self.sequence, revision: 1, start: start, end: end, confirmedAt: Date(), replacesProvisionalID: "\(self.epoch)-draft-\(job.id)"))
                        }
                        self.onProvisional("")
                        self.provisionalRevision += 1
                        self.onCaptionProvisional?(AudioProvisional(id: "\(self.epoch)-draft-\(job.id)", epochID: self.epoch, text: "", revision: self.provisionalRevision, start: job.offset))
                    } else if !self.stopped && self.finals.isEmpty && job.id == self.utteranceID {
                        let text = rows.map(\.text).joined(separator: " ")
                        self.onProvisional(text); self.provisionalRevision += 1
                        self.onCaptionProvisional?(AudioProvisional(id: "\(self.epoch)-draft-\(job.id)", epochID: self.epoch, text: text, revision: self.provisionalRevision, start: job.offset))
                    }
                }
                self.pump()
            }
        }
    }
    private static func removeRepeatedOverlap(previous: String, current: String, language: String) -> String {
        guard !previous.isEmpty else { return current }
        if language == "ja" {
            let old = Array(previous), new = Array(current)
            for n in stride(from: min(old.count, new.count), through: 2, by: -1) where Array(old.suffix(n)) == Array(new.prefix(n)) {
                return String(new.dropFirst(n)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        } else {
            let old = previous.split(whereSeparator: \.isWhitespace), new = current.split(whereSeparator: \.isWhitespace)
            func normal(_ word: Substring) -> String { String(word).lowercased().trimmingCharacters(in: .punctuationCharacters) }
            if !old.isEmpty, !new.isEmpty {
                for n in stride(from: min(old.count, new.count), through: 1, by: -1) where old.suffix(n).map(normal) == new.prefix(n).map(normal) {
                    return new.dropFirst(n).joined(separator: " ")
                }
            }
        }
        return current
    }
    func finish(completion: @escaping () -> Void) {
        admission.lock(); accepting = false; admission.unlock()
        queue.async {
            self.stopCompletions.append(completion)
            if !self.stopped {
                if !self.pendingPCM.isEmpty { self.process(self.pendingPCM); self.pendingPCM.removeAll() }
                self.finalizeUtterance(carryOverlap: false); self.stopped = true; self.provisionalWindow = nil
                do { try self.recorder?.finish() } catch { self.onError(error.localizedDescription) }; self.recorder = nil
            }
            self.finishIfDrained()
        }
    }
    func finish() async { await withCheckedContinuation { continuation in finish { continuation.resume() } } }
    private func finishIfDrained() {
        guard stopped, !busy, finals.isEmpty else { return }
        onProvisional(""); let callbacks = stopCompletions; stopCompletions.removeAll(); callbacks.forEach { $0() }
    }
    private func fail(_ message: String, from: Double, length: Double) {
        guard !failureReported else { return }; failureReported = true
        admission.lock(); accepting = false; admission.unlock()
        onGap(AudioGap(id: UUID().uuidString, sessionID: session, epochID: epoch, reason: message, start: from, end: from + length)); onError(message)
    }
}

/// Uses Apple's resampler; state is retained for one capture epoch.
final class AudioPCMConverter {
    private var converter: AVAudioConverter?, inputFormat: AVAudioFormat?
    private let target: AVAudioFormat
    let targetSampleRate: Double
    private let live: Bool
    init(targetSampleRate: Double = 16000, live: Bool = true) {
        self.targetSampleRate = targetSampleRate
        self.live = live
        target = AVAudioFormat(standardFormatWithSampleRate: targetSampleRate, channels: 1)!
    }
    func convert(_ pcm: AVAudioPCMBuffer) throws -> [Float] {
        if pcm.format.sampleRate == targetSampleRate, pcm.format.channelCount == 1, pcm.format.commonFormat == .pcmFormatFloat32, let samples = pcm.floatChannelData { return Array(UnsafeBufferPointer(start: samples[0], count: Int(pcm.frameLength))) }
        if inputFormat != pcm.format {
            converter = AVAudioConverter(from: pcm.format, to: target); inputFormat = pcm.format
            // Apple's AVAudioConverterPrimeInfo documents .none for live input:
            // retain stream duration rather than consuming read-ahead priming frames.
            if live { converter?.primeMethod = .none }
        }
        guard let converter else { throw AudioFailure.message("输入格式无法转换为离线识别 PCM。") }
        let capacity = AVAudioFrameCount(ceil(Double(pcm.frameLength) * targetSampleRate / pcm.format.sampleRate) + 128)
        let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: capacity)!
        var supplied = false, error: NSError?
        let result = converter.convert(to: out, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }; supplied = true; status.pointee = .haveData; return pcm
        }
        if result == .error { throw error ?? AudioFailure.message("PCM 重采样失败") as NSError }
        return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
    }
    /// .noDataNow can retain a partial resampler block. Explicit EOS drains it;
    /// consumers must append this tail before their own normal session close.
    func finish() throws -> [Float] {
        guard let converter else { return [] }
        defer { self.converter = nil; inputFormat = nil }
        var samples: [Float] = []
        for _ in 0..<32 {
            let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: 4096)!
            var error: NSError?
            let result = converter.convert(to: out, error: &error) { _, status in status.pointee = .endOfStream; return nil }
            if result == .error { throw error ?? AudioFailure.message("PCM 重采样失败") as NSError }
            if out.frameLength > 0 { samples.append(contentsOf: UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength))) }
            if result == .endOfStream || result == .inputRanDry || out.frameLength == 0 { return samples }
        }
        throw AudioFailure.message("PCM 尾部超过缓冲上限。")
    }
    static func readFile(_ url: URL) throws -> [Float] {
        let file = try AVAudioFile(forReading: url); let converter = AudioPCMConverter(live: false); var result: [Float] = []
        while file.framePosition < file.length {
            let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
            try file.read(into: buffer); result.append(contentsOf: try converter.convert(buffer))
        }
        return result
    }
}
