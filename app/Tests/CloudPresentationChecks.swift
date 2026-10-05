import Foundation

@main enum CloudPresentationChecks {
    @MainActor static func main() throws {
        var checks: [String] = []
        func check(_ condition: @autoclosure () -> Bool, _ label: String) throws {
            guard condition() else { throw NSError(domain: "CloudPresentationChecks", code: 1, userInfo: [NSLocalizedDescriptionKey: label]) }
            checks.append(label)
        }
        let segment = CloudSegment(id: "source", classID: "class", revision: 1, text: "Saved", language: "en", startMS: 0, endMS: 1000, confirmedAt: Date())
        let queue = CloudQueueOverview(jobs: [
            CloudTranslationJob(segment: segment, targetLanguage: "zh-Hans", status: .completed),
            CloudTranslationJob(segment: segment, targetLanguage: "zh-Hans", status: .obsolete),
            CloudTranslationJob(segment: segment, targetLanguage: "zh-Hans", status: .running),
            CloudTranslationJob(segment: segment, targetLanguage: "zh-Hans", status: .running, historical: true),
            CloudTranslationJob(segment: segment, targetLanguage: "zh-Hans", status: .needsAttention, historical: true)
        ])
        try check(queue.completed == 1 && queue.pending == 3 && queue.currentPending == 1 && queue.historicalPending == 2 && queue.needsAttention == 1, "queue presentation excludes obsolete tasks and separates pending current history and failures")
        try check(queue.historicalRunning == 1, "historical active work distinguishable from live work")
        var failed = CloudTranslationJob(segment: segment, targetLanguage: "zh-Hans", status: .needsAttention)
        failed.errorCode = "permission"
        var completed = CloudTranslationJob(segment: segment, targetLanguage: "zh-Hans", status: .completed)
        completed.errorCode = "unavailable"
        var obsolete = CloudTranslationJob(segment: segment, targetLanguage: "zh-Hans", status: .obsolete)
        obsolete.errorCode = "authentication"
        var restoredState = CloudState(classID: "class")
        restoredState.jobs = [failed, completed, obsolete]
        let restored = CloudController(state: restoredState, monitorNetwork: false)
        try check(restored.queueErrorCode == "permission", "restored queue derives its active error from durable jobs and ignores completed or obsolete errors")
        restoredState.jobs = [completed, obsolete]
        let resolved = CloudController(state: restoredState, monitorNetwork: false)
        try check(resolved.queueErrorCode == nil, "resolved restored queue has no stale failure banner")
        let date = Date()
        let usage = CloudUsage(id: "one", provider: .openAI, model: "fixture", inputTokens: 12, outputTokens: 4, status: "providerReported", at: date)
        let unknown = CloudUsage(id: "two", provider: .openAI, model: "fixture", inputTokens: nil, outputTokens: nil, status: "unknown", at: date)
        let partial = CloudUsage(id: "three", provider: .googleCloudStandard, model: "fixture", inputTokens: 9, outputTokens: nil, status: "unknown", at: date)
        let totals = CloudUsageTotals([usage, unknown, usage, partial])
        try check(totals.records.count == 3 && totals.inputTokens == 21 && totals.outputTokens == 4 && totals.unknownRequests == 2, "usage deduplicates request IDs but retains partial and fully unknown request count")
        let source = SummarySource(kind: .note, entityID: "note", version: 1, text: "abcdefghij")
        let dispatch = CloudDispatch(version: 1, configuration: CloudConfiguration(provider: .openAI), preset: .current(for: .openAI), sentAt: date)
        var summary = CloudSummary(snapshot: SummarySnapshot(classID: "class", sources: [source]), dispatch: dispatch)
        let first = SummaryChunkCoverage(spans: [SummaryCoverageSpan(sourceID: source.id, startCharacter: 0, characterCount: 6)], status: "completed")
        let overlap = SummaryChunkCoverage(spans: [SummaryCoverageSpan(sourceID: source.id, startCharacter: 4, characterCount: 4)], status: "completed")
        let missing = SummaryChunkCoverage(spans: [SummaryCoverageSpan(sourceID: source.id, startCharacter: 8, characterCount: 2)], status: "failed")
        summary.chunks = [first, overlap, missing]; summary.completedChunkIDs = [first.id, overlap.id]; summary.missingChunkIDs = [missing.id]
        let coverage = SummaryPresentation.coverage(summary)[0]
        try check(coverage.processedCharacters == 8 && coverage.totalCharacters == 10 && !coverage.isComplete, "coverage unions overlap and excludes failed spans instead of showing complete source")
        summary.chunks[2].status = "completed"; summary.completedChunkIDs.append(missing.id); summary.missingChunkIDs = []
        try check(SummaryPresentation.coverage(summary)[0].isComplete, "coverage reaches complete only when all source characters are processed")
        try check(SummaryPresentation.compactPages([1,2,3,5,7,8,8,0]) == "1–3, 5, 7–8", "material preview uses exact compressed physical page ranges without duplicates or invalid page zero")
        try check(SummaryPresentation.compactPages([]) == "—", "zero readable PDF pages remain visibly empty")
        let citation = SummarySource(kind: .transcript, entityID: segment.id, version: segment.revision, text: segment.text, startMS: segment.startMS, endMS: segment.endMS)
        try check(SummaryPresentation.matchesCurrentTranscript(citation, segment), "matching fixed transcript citation may navigate to the current row")
        var changed = segment; changed.revision += 1
        var shifted = segment; shifted.startMS += 1
        try check(!SummaryPresentation.matchesCurrentTranscript(citation, changed) && !SummaryPresentation.matchesCurrentTranscript(citation, shifted), "changed revision or timestamp cannot redirect old citation away from its snapshot")
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["passed": checks.count, "checks": checks, "providerCalls":0, "keychainReads":0, "audioPlayback":0], options: [.prettyPrinted,.sortedKeys]), as: UTF8.self))
    }
}
