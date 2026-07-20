import SwiftUI

/// Glance page: big glucose + trend (hidden when stale), a compact IOB/reservoir line, the
/// iPhone-reachability state, and the Bolus button. Swipe for Chart / Details / Alerts.
struct WatchGlanceView: View {
    @Bindable var model: WatchModel
    @Binding var showBolus: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(model.displayGlucose)
                        .font(.system(size: 44, weight: .bold, design: .rounded))
                        .foregroundStyle(watchGlucoseColor(model.glucose, stale: model.isGlucoseStale))
                    if !model.isGlucoseStale { Text(model.trend).font(.title2) }
                }
                Text(model.isGlucoseStale ? "no recent CGM"
                     : (model.ageMinutes.map { "\($0) min ago" } ?? "mg/dL"))
                    .font(.caption2).foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Label(String(format: "%.2f U", model.iobUnits), systemImage: "syringe")
                    Label("\(Int(model.reservoirUnits)) U", systemImage: "drop")
                }.font(.caption2).foregroundStyle(.secondary)

                if !model.alerts.isEmpty {
                    Label("\(model.alerts.count) alert\(model.alerts.count == 1 ? "" : "s")",
                          systemImage: "bell.badge.fill")
                        .font(.caption2).foregroundStyle(.orange)
                }

                Label(model.reachable ? "iPhone connected" : "iPhone out of range",
                      systemImage: model.reachable ? "iphone" : "iphone.slash")
                    .font(.caption2)
                    .foregroundStyle(model.reachable ? .green : .orange)

                Button { showBolus = true } label: { Label("Bolus", systemImage: "drop.fill") }
                    .tint(.indigo)
                    .disabled(!model.reachable)
            }
            .padding(.top, 4)
        }
    }
}
