import SwiftUI

struct ClassroomTerminologyView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var cloud: CloudController
    @ObservedObject var terminology: TextTranslationController
    let classID: String
    let courseID: String
    private var candidate: ClassroomTerminologySnapshot {
        ClassroomTerminologySnapshot(scopeID: courseID, revision: terminology.glossary.revision,
                                     terms: terminology.glossary.terms.filter { $0.scopeID == courseID && $0.enabled })
    }
    var body: some View {
        DisclosureGroup(model.t("classTerminology")) {
            VStack(alignment: .leading, spacing: 8) {
                Toggle(model.t("enableClassTerminology"), isOn: Binding(get: { cloud.state.terminologySelection != nil }, set: { enabled in
                    Task { do { try await model.configureClassTerminology(classID, enabled: enabled) } catch { model.report(error) } }
                }))
                Text(model.t("classTerminologyHelp")).font(.caption2).foregroundStyle(.secondary)
                if let saved = cloud.state.terminologySelection {
                    Text("v\(saved.revision) · \(saved.terms.count) " + model.t("terminologyEntries")).font(.caption.monospacedDigit())
                    if saved != candidate {
                        Button(model.t("updateTerminologySnapshot")) {
                            Task { do { try await model.configureClassTerminology(classID, enabled: true) } catch { model.report(error) } }
                        }.controlSize(.small)
                    }
                }
                if candidate.terms.isEmpty { Text(model.t("noCourseTerminology")).font(.caption2).foregroundStyle(.secondary) }
                Button(model.t("manageCourseTerminology")) { terminology.setScope(courseID); model.route = "textTool" }.controlSize(.small)
            }.padding(.top, 8).disabled(model.busy || model.library?.isReadOnly != false)
        }.font(.caption)
    }
}

@MainActor extension AppModel {
    func configureClassTerminology(_ classID: String, enabled: Bool) async throws {
        guard let library else { throw LibraryError.message(t("chooseProjectFirst")) }
        try library.checkWritable()
        ensureCloud(classID)
        guard let cloud = clouds[classID], let courseID = items.first(where: { $0.id == classID })?.courseID else { throw LibraryError.message(t("chooseProjectFirst")) }
        let snapshot = enabled ? ClassroomTerminologySnapshot(scopeID: courseID, revision: textTranslation.glossary.revision,
                                                              terms: textTranslation.glossary.terms.filter { $0.scopeID == courseID && $0.enabled }) : nil
        try await cloud.configureTerminology(snapshot)
    }
}
