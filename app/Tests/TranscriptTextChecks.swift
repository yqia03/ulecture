import Foundation
import Darwin

@main enum TranscriptTextChecks {
    static func main() throws {
        let base = URL(fileURLWithPath: CommandLine.arguments[1]), fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        if CommandLine.arguments.count > 2 {
            try crashWorker(base: base, checkpoint: CommandLine.arguments[2])
            return
        }
        var checks: [String] = []
        func check(_ value: @autoclosure () throws -> Bool, _ label: String) throws {
            guard try value() else { throw LibraryError.message("FAILED: " + label) }
            checks.append(label)
        }
        func rejects(_ label: String, _ operation: () throws -> Void) throws {
            do { try operation() } catch { checks.append(label); return }
            throw LibraryError.message("FAILED: " + label)
        }
        func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }
        let library = try LibraryStore(rootURL: base.appendingPathComponent("catalog"))
        let transcriptRoot = base.appendingPathComponent("transcripts")
        try library.configureTranscriptStorage(rootURL: transcriptRoot)
        let session = try library.createStandaloneSession(title: "中文と日本語の授業")
        var store = library.transcriptStore!
        var txt = try store.fileURL(for: session, kind: .bilingual)
        try check(fm.fileExists(atPath: txt.deletingLastPathComponent().appendingPathComponent("transcript-bilingual.txt").path), "new session immediately maintains a separate bilingual TXT")
        try check(txt.lastPathComponent == "transcript-bilingual.txt" && txt.pathExtension == "txt", "stable transcript-bilingual.txt lives beside the original-only TXT")
        try check(try read(txt) == session.title + "\n", "new session immediately has a UTF-8 TXT before first caption")
        var source = TranscriptRecord(id: UUID().uuidString, classroomID: session.id, epochID: UUID().uuidString, startMS: 1234, endMS: 5678, text: "今日は晴れです。\r\n第二行中文\r第三行", language: "ja")
        try library.saveTranscript(source)
        var contents = try read(txt)
        try check(contents.contains("今日は晴れです。\n第二行中文\n第三行") && !contents.contains("\r"), "UTF-8 local text retains Chinese Japanese and normalized multiline content")
        try check(contents.contains("00:00:01.234 – 00:00:05.678"), "local TXT retains original audio timeline")
        let originalID = source.id
        source.revision += 1; source.text = "修訂后的日本語です。"
        try library.saveTranscript(source)
        contents = try read(txt)
        try check(!contents.contains("今日は晴れです") && contents.components(separatedBy: source.text).count == 2, "revisions atomically replace earlier text without appending duplicates")
        struct Translation: Encodable { var segmentID: String; var sourceRevision: Int; var text: String; var targetLanguage = "zh-Hans" }
        struct Job: Encodable { var status: String; var translation: Translation }
        struct CloudState: Encodable { var jobs: [Job] }
        func saveJobs(_ jobs: [Job]) throws {
            try library.putRecord(collection: "cloud-state", id: session.id, ownerID: session.id, value: CloudState(jobs: jobs))
        }
        let stale = Job(status: "completed", translation: Translation(segmentID: originalID, sourceRevision: 1, text: "过期译文不得出现"))
        let pending = Job(status: "running", translation: Translation(segmentID: originalID, sourceRevision: source.revision, text: "未完成译文不得出现"))
        let completed = Job(status: "completed", translation: Translation(segmentID: originalID, sourceRevision: source.revision, text: "最新中文翻译\r\n译文第二行"))
        try saveJobs([stale, pending])
        try check(try !read(txt).contains("译文不得出现"), "stale revision and incomplete local translations are omitted")
        try saveJobs([stale, pending, completed])
        contents = try read(txt)
        try check(contents.contains("最新中文翻译\n译文第二行") && !contents.contains("译文不得出现"), "completed translation update automatically writes only matching source revision")
        try check(try !read(store.fileURL(for: session)).contains("最新中文翻译") && read(store.fileURL(for: session)).contains(source.text), "original-only automatic TXT never contains the translation")
        let exported = try library.transcriptExportFiles(itemID: session.id, format: .txt, bilingual: true)
        try check(exported.values.contains { contents.contains(String(decoding: $0, as: UTF8.self)) }, "automatic local TXT reuses the explicit TXT export format")
        var traditional = completed
        traditional.translation.targetLanguage = "zh-Hant"; traditional.translation.text = "繁體對應譯文"
        try saveJobs([completed, traditional])
        try check(try read(txt).contains("最新中文翻译") && !read(txt).contains("繁體對應譯文"), "bilingual TXT chooses the configured target rather than the last completed job")
        let mismatchedTarget = String(decoding: try JSONSerialization.data(withJSONObject: ["jobs": [["status": "completed", "targetLanguage": "zh-Hans", "translation": ["segmentID": source.id, "sourceRevision": source.revision, "targetLanguage": "zh-Hant", "text": "錯配目標語言"]]]]), as: UTF8.self)
        try check(try TranscriptTextFormatter.translations(rows: [source], cloudJSON: [mismatchedTarget], targetLanguage: "zh-Hans").isEmpty, "a conflicting job and result target language never enters bilingual TXT")
        var targetConfig = try library.classroom(id: session.id)!
        targetConfig.targetLanguage = "zh-Hant"; try library.saveClassroom(targetConfig)
        try check(try read(txt).contains("繁體對應譯文") && !read(txt).contains("最新中文翻译"), "target language changes select the matching saved translation without losing other jobs")
        targetConfig.targetLanguage = "zh-Hans"; try library.saveClassroom(targetConfig)
        source.revision += 1; source.text = "再次修訂。"
        try library.saveTranscript(source)
        try check(try !read(txt).contains("最新中文翻译"), "new source revision removes now-stale completed translation")
        let previousModification = try fm.attributesOfItem(atPath: txt.path)[.modificationDate] as! Date
        var classroom = try library.classroom(id: session.id)!
        classroom.timelineMilliseconds += 1000
        try library.saveClassroom(classroom)
        try check(try fm.attributesOfItem(atPath: txt.path)[.modificationDate] as! Date == previousModification, "unrelated session metadata saves do not rewrite unchanged TXT")

        for provider in ["google", "openAI"] {
            let online = try library.createStandaloneSession(title: provider + " simultaneous interpretation")
            let onlineTXT = try store.fileURL(for: online, kind: .bilingual)
            let runtime = InterpretationRuntimeRecord(sessionID: online.id, mode: provider == "google" ? "googleOnline" : "openAIOnline", provider: provider, modelID: "fixture-model")
            try library.saveInterpretationRuntime(runtime)
            var caption = InterpretationCaptionRecord(sessionID: online.id, generation: 1, track: "source", text: "Original partial", language: "en", receivedAtMS: 100, startMS: 0, endMS: 400, timingSource: "estimated")
            try library.saveInterpretationCaption(caption)
            let translation = InterpretationCaptionRecord(sessionID: online.id, generation: 1, track: "translation", text: "独立中文译文\r\n第二行", language: "zh-Hans", isFinal: true, completionBasis: "provider", receivedAtMS: 800, timingSource: "unknown")
            try library.saveInterpretationCaption(translation)
            var onlineText = try read(onlineTXT)
            try check(onlineText.contains("Source · en · estimated display timing · partial") && onlineText.contains("Translation · zh-Hans · untimed · provider final"), provider + " TXT preserves independent tracks with honest timing and completion labels")
            try check(onlineText.contains("独立中文译文\n第二行"), provider + " translation writes independently of source timing")
            try check(try !read(store.fileURL(for: online)).contains("独立中文译文") && read(store.fileURL(for: online)).contains("Original partial"), provider + " original-only TXT preserves source track without translation")
            caption.revision += 1; caption.text = "Final source"; caption.isFinal = true; caption.completionBasis = "provider"
            try library.saveInterpretationCaption(caption)
            onlineText = try read(onlineTXT)
            try check(!onlineText.contains("Original partial") && onlineText.components(separatedBy: "Final source").count == 2 && onlineText.contains("独立中文译文\n第二行"), provider + " final caption revision replaces its partial without changing translation track")
        }

        let beforeFailure = try Data(contentsOf: txt)
        try fm.setAttributes([.posixPermissions: 0o400], ofItemAtPath: txt.path)
        source.revision += 1; source.text = "Permission retry 日本語"
        try rejects("TXT permission failure propagates through saveTranscript") { try library.saveTranscript(source) }
        try check(try Data(contentsOf: txt) == beforeFailure, "failed TXT write keeps the complete previous file")
        try check(try library.transcripts(classroomID: session.id).first?.revision == source.revision - 1, "TXT preflight failure rolls back catalog rather than acknowledging save")
        let durable = try store.records(for: session)!.first { $0.collection == "transcripts" }!
        try check(try JSONDecoder().decode(TranscriptRecord.self, from: Data(durable.json.utf8)).revision == source.revision - 1, "TXT preflight failure also preserves previous session database snapshot")
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: txt.path)
        try library.saveTranscript(source)
        try check(try read(txt).contains(source.text), "retry after restoring write access succeeds")
        let correctJSON = String(decoding: try JSONEncoder().encode(source), as: UTF8.self)
        let mismatched = PortableRecord(collection: "transcripts", id: UUID().uuidString, ownerID: session.id, json: correctJSON)
        let matching = PortableRecord(collection: "transcripts", id: source.id, ownerID: session.id, json: correctJSON)
        try rejects("malformed restored records with duplicate inner transcript identities throw instead of crashing") {
            try store.persist(session: session, records: [matching, mismatched])
        }
        try rejects("shared export formatter rejects duplicate segment identities without a fatal dictionary assertion") {
            _ = try TranscriptTextFormatter.translations(rows: [source, source], cloudJSON: [])
        }
        try check(try read(txt).contains(source.text), "rejected malformed snapshot leaves existing TXT intact")
        source.revision += 1; source.text = "Directory sync retry 中文"
        var syncAttempts = 0
        store.onTextFileWillSynchronize = {
            syncAttempts += 1
            if syncAttempts == 1 { throw LibraryError.message("Injected directory fsync failure after rename") }
        }
        try rejects("directory durability failure after atomic TXT publication propagates to the caller") { try library.saveTranscript(source) }
        try check(try read(txt).contains(source.text) && library.transcripts(classroomID: session.id).first?.revision == source.revision - 1, "post-publication failure retains new recoverable TXT while catalog does not acknowledge success")
        let retryIdentity = try WorkspaceCatalog.fileIdentity(txt)
        let retryModification = try fm.attributesOfItem(atPath: txt.path)[.modificationDate] as! Date
        try library.saveTranscript(source)
        store.onTextFileWillSynchronize = nil
        try check(syncAttempts == 2, "equal-content retry reattempts directory fsync before reporting saved")
        try check(try WorkspaceCatalog.fileIdentity(txt) == retryIdentity && fm.attributesOfItem(atPath: txt.path)[.modificationDate] as! Date == retryModification, "directory-fsync retry preserves TXT identity and mtime without needless rewrite")
        source.revision += 1; source.text = "New fact survives partial pair publication"
        store.onPublicationCheckpoint = { if $0 == "published-source" { throw LibraryError.message("Injected failure between files") } }
        try rejects("failure between the two publications never acknowledges the whole save") { try library.saveTranscript(source) }
        try check(try read(store.fileURL(for: session)).contains(source.text) && !read(txt).contains(source.text), "fault fixture observes exactly the recoverable between-files boundary")
        store.onPublicationCheckpoint = nil
        var nextMetadata = try library.classroom(id: session.id)!
        nextMetadata.timelineMilliseconds += 5000
        try library.saveClassroom(nextMetadata)
        try check(try library.transcripts(classroomID: session.id).first?.revision == source.revision && read(txt).contains(source.text), "a later metadata save first reconciles the new durable source instead of overwriting it from the old catalog")
        source.revision += 1; source.text = "Publication retains an external edit"
        let externallyChanged = Data("User edit during publication must survive".utf8)
        store.onPublicationCheckpoint = { if $0 == "snapshot-committed" { try externallyChanged.write(to: txt, options: .atomic) } }
        try rejects("external TXT modification after staging prevents a false successful publication") { try library.saveTranscript(source) }
        store.onPublicationCheckpoint = nil
        try check(try Data(contentsOf: txt) == externallyChanged, "an observed external edit is not replaced during the interrupted save")
        try library.saveTranscript(source)
        let changedRecovery = try fm.contentsOfDirectory(at: store.directory(for: session).appendingPathComponent("text-recovery"), includingPropertiesForKeys: nil)
        try check(try changedRecovery.contains { try Data(contentsOf: $0) == externallyChanged } && read(txt).contains(source.text), "retry retains exact externally edited bytes before repairing the pair")
        let sessionDirectory = try store.directory(for: session)
        try check(try !fm.contentsOfDirectory(atPath: sessionDirectory.path).contains { $0.hasPrefix(".transcript-") }, "successful and failed saves leave no temporary TXT files")

        let outside = base.appendingPathComponent("outside.txt")
        try Data("Do not replace external file".utf8).write(to: outside)
        try fm.removeItem(at: txt)
        try fm.createSymbolicLink(at: txt, withDestinationURL: outside)
        try rejects("Finder file resolution rejects a TXT symlink escaping the session") { _ = try store.fileURL(for: session, kind: .bilingual) }
        try rejects("TXT synchronization rejects an external symlink") { _ = try store.synchronizeTextFile(for: session) }
        try check(try read(outside) == "Do not replace external file", "TXT path validation leaves external bytes unchanged")
        try fm.removeItem(at: txt)
        try store.synchronizeTextFile(for: session)
        try check(try read(txt).contains(source.text), "Finder synchronization reconstructs a missing TXT from committed session data")
        try fm.removeItem(at: txt)
        try library.configureTranscriptStorage(rootURL: transcriptRoot)
        store = library.transcriptStore!
        try check(try read(txt).contains(source.text), "startup upgrades old SQLite-only session to TXT automatically")
        try Data("stale TXT from interrupted publication".utf8).write(to: txt)
        try library.configureTranscriptStorage(rootURL: transcriptRoot)
        store = library.transcriptStore!
        try check(try read(txt).contains(source.text) && !read(txt).contains("stale TXT"), "startup reconciles stale TXT with authoritative session records")
        let recoveryRoot = try store.directory(for: session).appendingPathComponent("text-recovery")
        let recoveryFiles = try fm.contentsOfDirectory(at: recoveryRoot, includingPropertiesForKeys: nil)
        try check(try recoveryFiles.contains { try read($0) == "stale TXT from interrupted publication" }, "unexpected old TXT bytes remain in an immutable recovery copy before replacement")
        let recoveryHashes = try WorkspaceCatalog.manifest(recoveryRoot)

        let readonly = try LibraryStore(rootURL: library.rootURL, readOnly: true)
        let nonexistentRoot = base.appendingPathComponent("readonly-must-not-create")
        try rejects("read-only catalog refuses transcript configuration before filesystem mutation") { try readonly.configureTranscriptStorage(rootURL: nonexistentRoot) }
        try check(!fm.fileExists(atPath: nonexistentRoot.path), "read-only configuration does not create a transcript directory")
        let newRoot = base.appendingPathComponent("relocated")
        try fm.createDirectory(at: newRoot, withIntermediateDirectories: true)
        let beforeMove = try Data(contentsOf: txt)
        try library.moveTranscriptStorage(to: newRoot)
        store = library.transcriptStore!
        let relocatedTXT = try store.fileURL(for: session, kind: .bilingual)
        try check(try WorkspaceCatalog.manifest(store.directory(for: session).appendingPathComponent("text-recovery")) == recoveryHashes, "storage relocation preserves every original TXT recovery asset")
        try check(relocatedTXT.path.hasPrefix(newRoot.path + "/") && (try Data(contentsOf: relocatedTXT)) == beforeMove, "storage relocation publishes TXT matching its database snapshot")
        try check(try Data(contentsOf: txt) == beforeMove, "storage relocation retains original TXT as rollback copy")
        txt = relocatedTXT
        source.revision += 1; source.text = "After relocation"
        try library.saveTranscript(source)
        try check(try read(txt).contains(source.text), "continued capture updates TXT under the selected new root")

        let oldLibrary = try LibraryStore(rootURL: base.appendingPathComponent("legacy-catalog"))
        let oldSession = try oldLibrary.createStandaloneSession(title: "Pre-upgrade session")
        try oldLibrary.saveTranscript(TranscriptRecord(id: UUID().uuidString, classroomID: oldSession.id, epochID: UUID().uuidString, startMS: 0, endMS: 1000, text: "Only in catalog before upgrade", language: "en"))
        try oldLibrary.configureTranscriptStorage(rootURL: base.appendingPathComponent("legacy-transcripts"))
        try check(try read(oldLibrary.transcriptStore!.fileURL(for: oldSession)).contains("Only in catalog before upgrade"), "first storage configuration migrates existing catalog records to automatic TXT")
        let oldStore = oldLibrary.transcriptStore!, oldOriginal = try oldStore.fileURL(for: oldSession)
        let legacyBytes = Data("Legacy original\n旧版译文必须保留\n".utf8)
        try legacyBytes.write(to: oldOriginal)
        let oldDB = try SQLiteDatabase(url: oldStore.directory(for: oldSession).appendingPathComponent("session.sqlite"), readOnly: false)
        try oldDB.execute("DELETE FROM metadata WHERE key='text_publication'")
        try oldStore.synchronizeTextFiles(for: oldSession)
        let legacyCopies = try fm.contentsOfDirectory(at: oldStore.directory(for: oldSession).appendingPathComponent("text-recovery"), includingPropertiesForKeys: nil)
        try check(try legacyCopies.contains { try Data(contentsOf: $0) == legacyBytes }, "first dual-file upgrade preserves exact old bilingual transcript.txt bytes")
        let priorLegacyHashes = try WorkspaceCatalog.manifest(oldStore.directory(for: oldSession).appendingPathComponent("text-recovery"))
        try oldStore.synchronizeTextFiles(for: oldSession)
        try check(try WorkspaceCatalog.manifest(oldStore.directory(for: oldSession).appendingPathComponent("text-recovery")) == priorLegacyHashes, "repeating the legacy upgrade does not duplicate or modify recovery assets")

        let archiveURL = base.appendingPathComponent("session.ulbackup")
        try WorkspaceArchive(catalog: WorkspaceCatalog(library: library)).backup(itemID: session.id, to: archiveURL)
        let restoredLibrary = try LibraryStore(rootURL: base.appendingPathComponent("restore-catalog"))
        try restoredLibrary.configureTranscriptStorage(rootURL: base.appendingPathComponent("restore-transcripts"))
        let restoreTarget = base.appendingPathComponent("restore-projects")
        try fm.createDirectory(at: restoreTarget, withIntermediateDirectories: true)
        _ = try WorkspaceArchive(catalog: WorkspaceCatalog(library: restoredLibrary)).restore(from: archiveURL, into: restoreTarget)
        let restoredSession = try restoredLibrary.items().first { $0.kind == .classroom }!
        try check(try read(restoredLibrary.transcriptStore!.fileURL(for: restoredSession)).contains(source.text), "portable backup restore regenerates TXT for the restored stable session identity")
        try check(try WorkspaceCatalog.manifest(restoredLibrary.transcriptStore!.directory(for: restoredSession).appendingPathComponent("text-recovery")) == recoveryHashes, "portable backup preserves original TXT recovery bytes without rewriting their content")
        for checkpoint in ["snapshot-committed", "published-source", "published-bilingual", "directory-synchronized", "receipt-published"] {
            let root = base.appendingPathComponent("crash-" + checkpoint)
            let child = Process()
            child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
            child.arguments = [root.path, checkpoint]
            try child.run(); child.waitUntilExit()
            try check(child.terminationStatus == 87, "real process exits at " + checkpoint)
            let reopened = try LibraryStore(rootURL: root.appendingPathComponent("catalog"))
            try reopened.configureTranscriptStorage(rootURL: root.appendingPathComponent("transcripts"))
            let recoveredSession = try reopened.items().first { $0.kind == .classroom }!
            let recoveredStore = reopened.transcriptStore!
            let original = try read(recoveredStore.fileURL(for: recoveredSession))
            let bilingual = try read(recoveredStore.fileURL(for: recoveredSession, kind: .bilingual))
            try check(original.contains("Crash durable original 原文") && !original.contains("新的译文") && bilingual.contains("新的译文") && !bilingual.contains("Older source"), "restart repairs a same-generation pair after " + checkpoint)
            try check(try reopened.transcripts(classroomID: recoveredSession.id).first?.revision == 2, "restart reconciles durable revision after " + checkpoint)
            let files = try fm.contentsOfDirectory(atPath: recoveredStore.directory(for: recoveredSession).path)
            try check(!files.contains { $0.hasPrefix(".transcript-") && $0.hasSuffix(".tmp") }, "restart cleans orphan publication staging after " + checkpoint)
        }
        let concurrent = try LibraryStore(rootURL: base.appendingPathComponent("concurrent-catalog"))
        try concurrent.configureTranscriptStorage(rootURL: base.appendingPathComponent("concurrent-transcripts"))
        let concurrentSession = try concurrent.createStandaloneSession(title: "Concurrent fictional lecture")
        let concurrentRow = TranscriptRecord(id: UUID().uuidString, classroomID: concurrentSession.id, epochID: UUID().uuidString, startMS: 0, endMS: 1000, text: "Concurrent original 1", language: "en")
        try concurrent.saveTranscript(concurrentRow)
        let concurrencyErrors = ConcurrentFailureBox()
        DispatchQueue.concurrentPerform(iterations: 4) { worker in
            do {
                for revision in 1...24 {
                    switch worker {
                    case 0:
                        var row = concurrentRow; row.revision = revision; row.text = "Concurrent original \(revision)"
                        try concurrent.saveTranscript(row)
                    case 1:
                        try concurrent.withTransaction {
                            let row = try concurrent.transcripts(classroomID: concurrentSession.id)[0]
                            let translation = Translation(segmentID: row.id, sourceRevision: row.revision, text: "Concurrent translation \(row.revision)")
                            try concurrent.putRecord(collection: "cloud-state", id: concurrentSession.id, ownerID: concurrentSession.id, value: CloudState(jobs: [Job(status: "completed", translation: translation)]))
                        }
                    case 2:
                        try concurrent.withReadSnapshot {
                            let current = concurrent.transcriptStore!
                            let expected = try TranscriptTextFormatter.sessionFiles(concurrentSession, records: current.records(for: concurrentSession)!)
                            for kind in TranscriptTextKind.allCases {
                                guard try Data(contentsOf: current.fileURL(for: concurrentSession, kind: kind)) == expected[kind] else { throw LibraryError.message("concurrent read observed a mixed generation") }
                            }
                        }
                    default:
                        _ = try concurrent.transcriptStore!.synchronizeTextFiles(for: concurrentSession)
                        _ = concurrent.recoveryWarnings
                    }
                }
            } catch { concurrencyErrors.append(error.localizedDescription) }
        }
        try check(concurrencyErrors.messages.isEmpty, "simultaneous confirmed-source, translation, Finder repair and catalog read queues preserve committed pair consistency")
        try check(try concurrent.transcripts(classroomID: concurrentSession.id).first?.revision == 24, "concurrent metadata and translation saves retain the newest confirmed source revision")
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["passed": checks.count, "checks": checks], options: [.prettyPrinted, .sortedKeys]), as: UTF8.self))
    }
    private static func crashWorker(base: URL, checkpoint: String) throws {
        let library = try LibraryStore(rootURL: base.appendingPathComponent("catalog"))
        try library.configureTranscriptStorage(rootURL: base.appendingPathComponent("transcripts"))
        let session = try library.createStandaloneSession(title: "Fictional interruption fixture")
        var row = TranscriptRecord(id: UUID().uuidString, classroomID: session.id, epochID: UUID().uuidString, startMS: 0, endMS: 1000, text: "Older source", language: "en")
        try library.saveTranscript(row)
        row.revision = 2; row.text = "Crash durable original 原文"
        library.transcriptStore!.onPublicationCheckpoint = { reached in if reached == checkpoint { _exit(87) } }
        struct Translation: Encodable { var segmentID: String; var sourceRevision: Int; var targetLanguage = "zh-Hans"; var text = "新的译文" }
        struct Job: Encodable { var status = "completed"; var translation: Translation }
        struct State: Encodable { var jobs: [Job] }
        try library.withTransaction {
            try library.saveTranscript(row)
            try library.putRecord(collection: "cloud-state", id: session.id, ownerID: session.id, value: State(jobs: [Job(translation: Translation(segmentID: row.id, sourceRevision: 2))]))
        }
        throw LibraryError.message("crash checkpoint was not reached")
    }

}

private final class ConcurrentFailureBox: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    var messages: [String] { lock.lock(); defer { lock.unlock() }; return values }
    func append(_ message: String) { lock.lock(); defer { lock.unlock() }; values.append(message) }
}
