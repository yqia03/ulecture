import Foundation

extension LibraryStore {
    /// Root-level legacy files stay reachable under an explicit logical course until its work folder
    /// is chosen. Only the new catalog is reorganized; legacy source IDs and bytes are retained.
    func organizeLegacyRoots(title: String) throws -> WorkspaceItem? {
        try withTransaction {
            let all = try items(includeDeleted: true)
            let roots = all.filter { $0.parentID == nil && $0.courseID == nil && $0.kind != .course && $0.kind != .classroom }
            guard !roots.isEmpty else { return nil }
            let course = try createItem(kind: .course, title: title)
            for root in roots {
                for var item in [root] + descendantsOf(root.id, in: all) {
                    if item.id == root.id { item.parentID = course.id }
                    item.courseID = course.id
                    try writeItem(item)
                }
            }
            return course
        }
    }
}
