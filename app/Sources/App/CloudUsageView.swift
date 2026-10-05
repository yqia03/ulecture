import SwiftUI

struct CloudUsageView: View {
    @EnvironmentObject var model: AppModel
    let usage: [CloudUsage]
    @State private var expanded = false
    @State private var visibleCount = 30
    var totals: CloudUsageTotals { CloudUsageTotals(usage) }
    var body: some View {
        DisclosureGroup(model.t("recordedUsage"), isExpanded: $expanded) {
            VStack(alignment: .leading, spacing: 9) {
                Text(model.t("usageScope")).font(.caption).foregroundStyle(.secondary)
                if totals.records.isEmpty { Text(model.t("noUsage")).font(.caption) }
                else {
                    Text("\(model.t("requests")): \(totals.records.count) · \(model.t("unknownUsage")): \(totals.unknownRequests)").font(.caption)
                    Text("\(model.t("knownTokens")) · \(model.t("inputTokens")): \(totals.inputTokens) · \(model.t("outputTokens")): \(totals.outputTokens)").font(.caption).textSelection(.enabled)
                    ForEach(totals.records.prefix(visibleCount)) { row in
                        VStack(alignment: .leading, spacing: 3) {
                            Text(row.at.formatted() + " · " + row.provider.displayName).font(.caption)
                            Text(row.model).font(.caption2).foregroundStyle(.secondary).textSelection(.enabled)
                            Text("\(model.t("inputTokens")): \(token(row.inputTokens)) · \(model.t("outputTokens")): \(token(row.outputTokens)) · \(model.t(row.status == "providerReported" ? "providerReported" : "unknownUsage"))").font(.caption2)
                        }.padding(.vertical, 3)
                    }
                    if visibleCount < totals.records.count { Button(model.t("showMore")) { visibleCount += 30 }.font(.caption) }
                }
                Text(model.t("unknownCost")).font(.caption).foregroundStyle(.secondary)
                Text(model.t("sentMayCharge")).font(.caption2).foregroundStyle(.secondary)
            }.padding(.top, 8)
        }
    }
    private func token(_ value: Int?) -> String { value.map { String(max(0, $0)) } ?? model.t("unknownUsage") }
}
