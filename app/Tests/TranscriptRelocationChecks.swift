import Foundation
import Darwin

@main struct TranscriptRelocationChecks {
    static func main() throws {
        let base = WorkspaceCatalog.canonicalURL(URL(fileURLWithPath: CommandLine.arguments[1])), fm = FileManager.default
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        let catalogRoot = base.appendingPathComponent("catalog"), oldRoot = base.appendingPathComponent("original"), newRoot = base.appendingPathComponent("new")
        if CommandLine.arguments.count > 2 {
            let library = try LibraryStore(rootURL: catalogRoot)
            try library.configureTranscriptStorage(rootURL: oldRoot)
            let session = try library.createStandaloneSession(title: "Test")
            try library.saveTranscript(TranscriptRecord(id: UUID().uuidString, classroomID: session.id, epochID: UUID().uuidString, startMS: 1000, endMS: 2300, text: "durable before kill", language: "en"))
            try fm.createDirectory(at: newRoot, withIntermediateDirectories: true)
            _ = try TranscriptRelocation(library: library, current: library.transcriptStore!).move(to: newRoot) { if $0 == "published" { kill(getpid(), SIGKILL) } }
            fatalError("kill checkpoint not reached")
        }
        var checks = [String]()
        func check(_ value: @autoclosure () throws -> Bool, _ name: String) throws { guard try value() else { throw LibraryError.message(name) }; checks.append(name) }
        func rejects(_ name: String, _ work: () throws -> Void) throws { do { try work() } catch { checks.append(name); return }; throw LibraryError.message(name) }
        let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); child.arguments = [base.path, "crash"]
        try child.run(); child.waitUntilExit()
        try check(child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL, "real process killed after target publication before root switch")
        let library = try LibraryStore(rootURL: catalogRoot)
        try library.configureTranscriptStorage(rootURL: oldRoot)
        try check(try library.savedTranscriptRoot() == nil, "crash retains original durable root selection")
        let session = try library.items().first { $0.kind == .classroom }!
        try library.moveTranscriptStorage(to: newRoot)
        try check(try library.transcripts(classroomID: session.id).first?.text == "durable before kill", "retry after kill keeps exact confirmed text")
        try check(try library.savedTranscriptRoot()?.path == newRoot.path, "successful retry atomically persists independent root selection")
        try check(try library.transcriptStore!.records(for: session)?.contains { $0.collection == "transcripts" } == true, "selected target session database is readable")
        try check(fm.fileExists(atPath: oldRoot.appendingPathComponent("Standalone/" + session.id + "/session.sqlite").path), "old database remains intact as rollback copy")
        let changedTarget = base.appendingPathComponent("after-change")
        try fm.createDirectory(at: changedTarget, withIntermediateDirectories: true)
        try rejects("injected interruption after frozen snapshots retains retry journal") {
            _ = try TranscriptRelocation(library: library, current: library.transcriptStore!).move(to: changedTarget) { if $0 == "verified" { throw LibraryError.message("fixture interruption") } }
        }
        let addition = TranscriptRecord(id: UUID().uuidString, classroomID: session.id, epochID: UUID().uuidString, startMS: 5000, endMS: 6400, text: "subsequent save must survive", language: "en")
        try library.saveTranscript(addition)
        try library.moveTranscriptStorage(to: changedTarget)
        try check(try library.transcriptStore!.records(for: session)?.contains { $0.id == addition.id } == true, "source change creates a fresh generation instead of losing subsequent saves")
        try check(fm.fileExists(atPath: changedTarget.appendingPathComponent(".ulecture-relocation-recovery").path), "interrupted generation retained separately for recovery")
        var pending = addition; pending.revision += 1; pending.text = "Committed session must reconcile before relocation"
        library.transcriptStore!.onPublicationCheckpoint = { if $0 == "published-source" { throw LibraryError.message("partial pair") } }
        try rejects("partial pair publication leaves a recoverable newer session before relocation") { try library.saveTranscript(pending) }
        library.transcriptStore!.onPublicationCheckpoint = nil
        let repairedRoot = base.appendingPathComponent("repaired-move")
        try fm.createDirectory(at: repairedRoot, withIntermediateDirectories: true)
        try library.moveTranscriptStorage(to: repairedRoot)
        try check(try library.transcripts(classroomID: session.id).first { $0.id == pending.id }?.revision == pending.revision, "moving storage first reconciles the latest committed session into its catalog")
        try check(try String(contentsOf: library.transcriptStore!.fileURL(for: session, kind: .bilingual), encoding: .utf8).contains(pending.text), "relocated pair includes the previously unacknowledged durable fact")
        let catalog = WorkspaceCatalog(library: library), course = try catalog.createCourse(title: "course")
        let project = try catalog.projectRoot(course.id)
        let nested = project.appendingPathComponent("Transcripts")
        try fm.createDirectory(at: nested, withIntermediateDirectories: true)
        try rejects("course-nested transcript root rejected without moving current storage") { try library.moveTranscriptStorage(to: nested) }
        try check(WorkspaceCatalog.canonicalURL(library.transcriptStore!.rootURL).path == repairedRoot.path, "failed root switch keeps previous active store")
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["passed":checks.count,"checks":checks], options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
    }
}
