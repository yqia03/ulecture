import Foundation

@main struct ProductUIFixture {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1]), fm = FileManager.default
        let first = root.appendingPathComponent("课程一 · Learning"), second = root.appendingPathComponent("Course 2 · 日本語")
        for directory in [first, second] { try fm.createDirectory(at: directory, withIntermediateDirectories: true) }
        try Data("# Working memory\n\n课堂笔记 · 日本語ノート\n\n- Review the evidence\n- [ ] Revisit the examples\n".utf8).write(to: first.appendingPathComponent("阅读与思考.md"))
        try Data("Text for drag, rename and restart verification.\n".utf8).write(to: first.appendingPathComponent("移动测试.txt"))
        try Data("Visible second course.\n".utf8).write(to: second.appendingPathComponent("Second.txt"))
        try fm.copyItem(at: URL(fileURLWithPath: CommandLine.arguments[2]), to: first.appendingPathComponent("Memory lecture.pdf"))
        let library = try LibraryStore(rootURL: root.appendingPathComponent("Workspace")), catalog = WorkspaceCatalog(library: library)
        let c1 = try catalog.createCourse(title: first.lastPathComponent), c2 = try catalog.createCourse(title: second.lastPathComponent)
        for filename in ["阅读与思考.md", "移动测试.txt", "Memory lecture.pdf"] { _ = try catalog.importDocument(from: first.appendingPathComponent(filename), parentID: c1.id) }
        _ = try catalog.importDocument(from: second.appendingPathComponent("Second.txt"), parentID: c2.id)
        _ = try catalog.create(kind: .folder, title: "资料文件夹", parentID: c1.id)
        try library.configureTranscriptStorage(rootURL: root.appendingPathComponent("Transcripts"))
        let session = try catalog.create(kind: .classroom, title: "English lecture · 第一节", parentID: c1.id)
        for doc in try library.items().filter({ $0.courseID == c1.id && ($0.kind == .pdf || $0.kind == .note) }) { try catalog.link(documentID: doc.id, sessionID: session.id) }
        try library.saveTranscript(TranscriptRecord(id: UUID().uuidString, classroomID: session.id, epochID: UUID().uuidString, startMS: 2000, endMS: 6300, text: "Working memory helps us reason about information while we learn.", language: "en"))
        var state = try library.classroom(id: session.id)!; state.state = "ended"; state.timelineMilliseconds = 7000; state.translationUserPaused = true; try library.saveClassroom(state)
        print(root.path)
    }
}
