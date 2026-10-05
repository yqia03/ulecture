import Foundation
import CoreGraphics
import Darwin

@main struct MigrationInterruptionChecks {
    static func main() throws {
        let fm = FileManager.default, base = URL(fileURLWithPath: CommandLine.arguments[1])
        let source = base.appendingPathComponent("old")
        if CommandLine.arguments.count > 2 {
            let phase = CommandLine.arguments[2], destination = try LibraryStore(rootURL: base.appendingPathComponent(phase))
            try destination.configureTranscriptStorage(rootURL: base.appendingPathComponent(phase + "-transcripts"))
            let migration = LegacyMigration(destination: destination)
            let snapshot = try migration.prepare(sourceRoot: source) { step in if phase == step { kill(getpid(), SIGKILL) } }
            if phase == "session-persisted" { destination.onSessionPersisted = { _ in kill(getpid(), SIGKILL) } }
            _ = try migration.install(snapshot: snapshot) { step in if phase == step { kill(getpid(), SIGKILL) } }
            if phase.hasPrefix("course-") {
                let course = try destination.items().first { $0.kind == .course }!
                let root = base.appendingPathComponent(phase + "-project"); try fm.createDirectory(at: root, withIntermediateDirectories: true)
                try WorkspaceCatalog(library: destination).materializeLegacyCourse(courseID: course.id, root: root, checkpoint: { step in
                    if phase == "course-" + step {
                        if step == "stage-output", let journal = try destination.record(collection: "course-migrations", id: course.id, as: CourseMigrationJournal.self), let files = fm.enumerator(at: URL(fileURLWithPath: journal.stagePath), includingPropertiesForKeys: nil) {
                            for case let file as URL in files where file.pathExtension == "md" { try Data("PARTIAL".utf8).write(to: file) }
                        }
                        kill(getpid(), SIGKILL)
                    }
                })
            }
            fatalError("checkpoint not reached")
        }
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        var original: LibraryStore? = try LibraryStore(rootURL: source)
        let course = try original!.createItem(kind: .course, title: "Course")
        let session = try original!.createItem(kind: .classroom, title: "Session", parentID: course.id)
        let note = try original!.createItem(kind: .note, title: "Note", parentID: session.id)
        _ = try original!.saveNote(noteID: note.id, markdown: "# Complete immutable source\n中文・日本語\n")
        try original!.saveTranscript(TranscriptRecord(id: UUID().uuidString, classroomID: session.id, epochID: UUID().uuidString, startMS: 10, endMS: 500, text: "Durable speech", language: "en"))
        let sidecar = source.appendingPathComponent("document-data/" + note.id)
        try fm.createDirectory(at: sidecar, withIntermediateDirectories: true)
        try Data(repeating: 0x42, count: 512_000).write(to: sidecar.appendingPathComponent("preserved.bin"))
        original = nil
        let phases = ["snapshot-published", "files-published", "session-persisted", "catalog-committed", "course-stage-output", "course-file-published"]
        var checks = [String]()
        for phase in phases {
            let child = Process(); child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); child.arguments = [base.path, phase]; try child.run(); child.waitUntilExit()
            guard child.terminationReason == .uncaughtSignal && child.terminationStatus == SIGKILL else { throw LibraryError.message("expected real SIGKILL " + phase) }
            let destination = try LibraryStore(rootURL: base.appendingPathComponent(phase))
            try destination.configureTranscriptStorage(rootURL: base.appendingPathComponent(phase + "-transcripts"))
            let migration = LegacyMigration(destination: destination), snapshot = try migration.prepare(sourceRoot: source)
            let receipt = try migration.install(snapshot: snapshot)
            _ = try migration.install(snapshot: snapshot)
            guard try destination.items().count == 3, try destination.noteRevision(noteID: note.id)?.markdown == "# Complete immutable source\n中文・日本語\n", try destination.transcripts(classroomID: session.id).count == 1,
                  try WorkspaceCatalog.manifest(sidecar) == WorkspaceCatalog.manifest(destination.rootURL.appendingPathComponent("document-data/" + note.id)), receipt.phase == "committed" else { throw LibraryError.message("failed migration retry " + phase) }
            checks.append("real SIGKILL and exact retry without duplicate IDs: " + phase)
            if phase.hasPrefix("course-") {
                let root = base.appendingPathComponent(phase + "-project"), catalog = WorkspaceCatalog(library: destination)
                try catalog.materializeLegacyCourse(courseID: course.id, root: root)
                guard try String(contentsOf: catalog.documentURL(id: note.id)) == "# Complete immutable source\n中文・日本語\n", try WorkspaceCatalog.manifest(sidecar) == WorkspaceCatalog.manifest(root.appendingPathComponent(".ulecture/documents/" + note.id)) else { throw LibraryError.message("partial course accepted") }
                checks.append("course resumes from intact source and retains complete sidecar: " + phase)
            }
        }
        print(String(decoding: try JSONSerialization.data(withJSONObject: ["passed":checks.count,"checks":checks], options:[.prettyPrinted,.sortedKeys]),as:UTF8.self))
    }
}
