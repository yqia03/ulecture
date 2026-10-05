import SwiftUI

/// Workspace reading preferences are local UI state, separate from classroom content and cloud settings.
@MainActor final class WorkspaceLayoutPreferences: ObservableObject {
    static let shared = WorkspaceLayoutPreferences(defaults: AppPreferences.shared.defaults)
    private let defaults: UserDefaults
    @Published var showNotes: Bool { didSet { defaults.set(showNotes, forKey: "workspace.showNotes") } }
    @Published var pdfWidth: Double { didSet { defaults.set(pdfWidth, forKey: "workspace.pdfWidth") } }
    @Published var notesWidth: Double { didSet { defaults.set(notesWidth, forKey: "workspace.notesWidth") } }
    init(defaults: UserDefaults) {
        self.defaults = defaults
        showNotes = defaults.object(forKey: "workspace.showNotes") as? Bool ?? true
        pdfWidth = defaults.object(forKey: "workspace.pdfWidth") as? Double ?? 460
        notesWidth = defaults.object(forKey: "workspace.notesWidth") as? Double ?? 340
    }
}

struct WorkspaceDivider: View {
    let label: String
    @Binding var width: Double
    let range: ClosedRange<Double>
    @State private var dragOrigin: Double?
    var body: some View {
        Rectangle().fill(Color.clear).frame(width: 7)
            .overlay(Rectangle().fill(Color.primary.opacity(0.10)).frame(width: 1))
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { value in
                if dragOrigin == nil { dragOrigin = min(range.upperBound, max(range.lowerBound, width)) }
                width = min(range.upperBound, max(range.lowerBound, (dragOrigin ?? width) + value.translation.width))
            }.onEnded { _ in dragOrigin = nil })
            .focusable()
            .onMoveCommand { direction in
                if direction == .left || direction == .right { width = min(range.upperBound, max(range.lowerBound, width + (direction == .right ? 20 : -20))) }
            }
            .accessibilityElement().accessibilityLabel(label)
            .accessibilityValue("\(Int(width))")
            .accessibilityAdjustableAction { direction in
                width = min(range.upperBound, max(range.lowerBound, width + (direction == .increment ? 20 : -20)))
            }
    }
}
