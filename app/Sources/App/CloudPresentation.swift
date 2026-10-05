import Foundation

// Presentation facts remain independent of network, credentials and playback.
struct CloudQueueOverview {
    let completed: Int
    let pending: Int
    let currentPending: Int
    let historicalPending: Int
    let needsAttention: Int
    let historicalRunning: Int
    init(jobs: [CloudTranslationJob]) {
        let active = jobs.filter { $0.status != .obsolete }
        let waiting = active.filter { $0.status != .completed }
        completed = active.count - waiting.count; pending = waiting.count
        currentPending = waiting.filter { !$0.historical }.count
        historicalPending = waiting.filter(\.historical).count
        needsAttention = waiting.filter { $0.status == .needsAttention }.count
        historicalRunning = waiting.filter { $0.historical && $0.status == .running }.count
    }
}

struct CloudUsageTotals {
    let records: [CloudUsage]
    let inputTokens: Int
    let outputTokens: Int
    let unknownRequests: Int
    init(_ usage: [CloudUsage]) {
        // A request can appear through more than one view; count its ID once.
        records = Dictionary(usage.map { ($0.id, $0) }, uniquingKeysWith: { first, second in
            if first.status == "providerReported" { return first }
            return second
        }).values.sorted { $0.at > $1.at }
        inputTokens = records.compactMap(\.inputTokens).reduce(0) { $0 + max(0, $1) }
        outputTokens = records.compactMap(\.outputTokens).reduce(0) { $0 + max(0, $1) }
        unknownRequests = records.filter { $0.status != "providerReported" || $0.inputTokens == nil || $0.outputTokens == nil }.count
    }
}

struct SummarySourceCoverage: Identifiable {
    let source: SummarySource
    let processedCharacters: Int
    let totalCharacters: Int
    var id: String { source.id }
    var isComplete: Bool { processedCharacters == totalCharacters && totalCharacters > 0 }
}

enum SummaryPresentation {
    static func matchesCurrentTranscript(_ source: SummarySource, _ segment: CloudSegment) -> Bool {
        source.kind == .transcript && source.entityID == segment.id && source.version == segment.revision && source.text == segment.text && source.startMS == segment.startMS && source.endMS == segment.endMS
    }
    static func coverage(_ summary: CloudSummary) -> [SummarySourceCoverage] {
        let completed = Set(summary.completedChunkIDs)
        let spans = summary.chunks.filter { completed.contains($0.id) && $0.status == "completed" }.flatMap(\.spans)
        return summary.snapshot.sources.map { source in
            let length = source.text.count
            let ranges = spans.filter { $0.sourceID == source.id }.compactMap { span -> Range<Int>? in
                guard span.startCharacter >= 0, span.characterCount > 0, span.startCharacter < length else { return nil }
                return span.startCharacter..<(span.startCharacter + min(span.characterCount, length - span.startCharacter))
            }.sorted { $0.lowerBound < $1.lowerBound }
            var count = 0, end = 0
            for range in ranges {
                count += max(0, range.upperBound - max(end, range.lowerBound)); end = max(end, range.upperBound)
            }
            return SummarySourceCoverage(source: source, processedCharacters: count, totalCharacters: length)
        }
    }
    static func compactPages(_ pages: [Int]) -> String {
        let pages = Set(pages.filter { $0 > 0 }).sorted()
        guard let first = pages.first else { return "—" }
        var result: [String] = [], start = first, last = first
        for page in pages.dropFirst() {
            if page == last + 1 { last = page }
            else { result.append(start == last ? "\(start)" : "\(start)–\(last)"); start = page; last = page }
        }
        result.append(start == last ? "\(start)" : "\(start)–\(last)")
        return result.joined(separator: ", ")
    }
}
