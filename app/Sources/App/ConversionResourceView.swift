import SwiftUI
import AppKit
import UniformTypeIdentifiers

@MainActor final class ConversionResourceController: ObservableObject {
    @Published private(set) var status = "conversionUnchecked"
    @Published private(set) var progress = 0.0
    @Published private(set) var error: String?
    @Published private(set) var busy = false
    private let store: ConversionResourceStore
    private var task: Task<Void, Never>?
    private var generation = UUID()
    init(store: ConversionResourceStore = .standard) { self.store = store }
    func check() { run(source: nil) }
    func repair(from source: URL) { run(source: source) }
    func cancel() { task?.cancel() }
    private func run(source: URL?) {
        guard !busy else { return }
        busy = true; progress = 0; error = nil; status = source == nil ? "conversionChecking" : "conversionRepairing"
        generation = UUID(); let token = generation, store = store
        task = Task { [weak self] in
            let scoped = source?.startAccessingSecurityScopedResource() ?? false
            defer { if scoped { source?.stopAccessingSecurityScopedResource() } }
            let progressTarget = self
            let worker = Task.detached {
                let progress: @Sendable (Double) -> Void = { value in Task { @MainActor in if progressTarget?.generation == token { progressTarget?.progress = value } } }
                if let source { _ = try store.repair(from: source, progress: progress) }
                else { _ = try store.verify(store.effectiveRoot, progress: progress) }
            }
            do {
                try await withTaskCancellationHandler(operation: { try await worker.value }, onCancel: { worker.cancel() })
                guard let self, self.generation == token else { return }
                self.progress = 1; self.status = "conversionReady"
            } catch {
                guard let self, self.generation == token else { return }
                self.status = error is CancellationError ? "conversionCancelled" : "conversionFailedCheck"
                self.error = (error as? ConversionResourceFailure).map { "conversion." + $0.rawValue }
                    ?? (error is CancellationError ? nil : "conversion.persistence")
            }
            guard let self, self.generation == token else { return }
            self.busy = false; self.task = nil
        }
    }
}

struct ConversionResourceView: View {
    @StateObject private var controller = ConversionResourceController()
    let language: String
    private func t(_ key: String) -> String { ConversionText.t(key, language) }
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(t("conversionTitle"), systemImage: "doc.badge.gearshape").font(.headline)
            Text(t("conversionHelp")).font(.callout).foregroundStyle(.secondary)
            Text(t(controller.status)).font(.callout).accessibilityIdentifier("conversionResources.status")
            if controller.busy {
                ProgressView(value: controller.progress)
                Button(t("cancel")) { controller.cancel() }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack { actions }
                    VStack(alignment: .leading, spacing: 8) { actions }
                }
            }
            if let error = controller.error { Text(t(error)).font(.caption).foregroundStyle(.red) }
            Text(t("conversionRepairHelp")).font(.caption).foregroundStyle(.secondary)
        }.task { if controller.status == "conversionUnchecked" { controller.check() } }
    }
    @ViewBuilder private var actions: some View {
        Button(t("conversionCheck")) { controller.check() }.accessibilityIdentifier("conversionResources.check")
        Button(t("conversionRepair")) {
            let panel = NSOpenPanel(); panel.allowedContentTypes = [.application]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url { controller.repair(from: url) }
        }.accessibilityIdentifier("conversionResources.repair")
    }
}
