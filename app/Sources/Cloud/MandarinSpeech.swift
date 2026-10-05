import Foundation
import AVFoundation
import Combine

struct MandarinVoice: Identifiable, Equatable { var id: String; var name: String; var language: String }
struct SpeechCandidate: Equatable { var text: String; var confirmedAt: Date; var savedAt: Date; var historical: Bool }
struct MandarinSpeechPolicy {
    var enabledAt: Date?
    var classActive = false
    var queue: [SpeechCandidate] = []
    var skippedCount = 0
    let freshness: TimeInterval = 20
    let maxQueuedCharacters = 240
    let maxQueuedItems = 3
    mutating func offer(_ candidate: SpeechCandidate, now: Date) -> Bool {
        guard classActive, let enabledAt, !candidate.historical, candidate.confirmedAt >= enabledAt,
              candidate.savedAt >= enabledAt else { return false }
        discardExpired(now: now)
        guard now.timeIntervalSince(candidate.confirmedAt) <= freshness, candidate.text.count <= maxQueuedCharacters else { skippedCount += 1; return false }
        queue.append(candidate)
        while queue.count > maxQueuedItems || queue.reduce(0, { $0 + $1.text.count }) > maxQueuedCharacters { queue.removeFirst(); skippedCount += 1 }
        return true
    }
    mutating func discardExpired(now: Date) {
        let before = queue.count, cutoff = freshness
        queue.removeAll { now.timeIntervalSince($0.confirmedAt) > cutoff }
        skippedCount += before - queue.count
    }
    mutating func stop() { enabledAt = nil; queue = [] }
}

@MainActor final class MandarinSpeechController: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    @Published private(set) var enabled = false
    @Published private(set) var status = "关闭"
    @Published private(set) var voices: [MandarinVoice] = []
    @Published private(set) var skippedCount = 0
    @Published var selectedVoiceID: String?
    private var synthesizer: AVSpeechSynthesizer?
    private var policy = MandarinSpeechPolicy()
    private var current: SpeechCandidate?
    private var currentUtterance: AVSpeechUtterance?
    override init() { super.init() }
    func refreshVoices() {
        voices = AVSpeechSynthesisVoice.speechVoices().filter { ["zh-CN", "zh-TW"].contains($0.language) }.map { MandarinVoice(id: $0.identifier, name: $0.name, language: $0.language) }
        if !voices.contains(where: { $0.id == selectedVoiceID }) { selectedVoiceID = voices.first?.id }
    }
    func setClassActive(_ value: Bool) { policy.classActive = value; if !value { stop() } }
    func enable() {
        refreshVoices()
        guard policy.classActive, selectedVoiceID != nil else { status = "需要正在进行的课堂及可用普通话声音；可在系统设置 → 辅助功能 → 朗读内容准备声音"; return }
        policy.stop(); policy.skippedCount = 0; skippedCount = 0; policy.enabledAt = Date(); enabled = true; status = "仅朗读开启后的新译文"
        if synthesizer == nil { synthesizer = AVSpeechSynthesizer(); synthesizer?.delegate = self }
    }
    func stop() { enabled = false; policy.stop(); current = nil; currentUtterance = nil; synthesizer?.stopSpeaking(at: .immediate); status = "关闭" }
    func offer(saved translation: CloudTranslation, segment: CloudSegment) {
        let now = Date()
        let candidate = SpeechCandidate(text: translation.text, confirmedAt: segment.confirmedAt, savedAt: translation.savedAt, historical: translation.historical)
        let accepted = policy.offer(candidate, now: now); skippedCount = policy.skippedCount
        guard accepted else { return }
        if let current, now.timeIntervalSince(current.confirmedAt) > policy.freshness {
            currentUtterance = nil; synthesizer?.stopSpeaking(at: .immediate); self.current = nil
            policy.skippedCount += 1; skippedCount = policy.skippedCount
        }
        speakNext()
    }
    private func speakNext() {
        guard enabled, current == nil, let voiceID = selectedVoiceID,
              let voice = AVSpeechSynthesisVoice(identifier: voiceID) else { return }
        policy.discardExpired(now: Date()); skippedCount = policy.skippedCount
        guard !policy.queue.isEmpty else { status = "仅朗读开启后的新译文"; return }
        current = policy.queue.removeFirst()
        let utterance = AVSpeechUtterance(string: current!.text); utterance.voice = voice; utterance.rate = AVSpeechUtteranceDefaultSpeechRate
        currentUtterance = utterance; synthesizer?.speak(utterance); status = "正在朗读已保存译文"
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in guard self.currentUtterance === utterance else { return }; self.current = nil; self.currentUtterance = nil; self.speakNext() }
    }
    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
        Task { @MainActor in guard self.currentUtterance === utterance else { return }; self.current = nil; self.currentUtterance = nil; self.speakNext() }
    }
}
