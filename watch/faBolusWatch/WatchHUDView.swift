import SwiftUI
import faBolusCore

/// Glance page: big glucose + trend (hidden when stale), a compact IOB/reservoir line, the
/// iPhone-reachability state, and the Bolus button. Swipe for Chart / Details / Alerts.
struct WatchGlanceView: View {
    @Bindable var model: WatchModel
    @Binding var showBolus: Bool

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                // Re-evaluate age/staleness on a timer so a reading visibly ages, greys, then hides.
                TimelineView(.periodic(from: .now, by: 20)) { ctx in
                    let present = GlucoseFreshness.presentation(of: model.glucoseDate, now: ctx.date)
                    let stale = present == .stale
                    VStack(spacing: 8) {
                        if model.glucose != nil, present != .hidden {
                            HStack(alignment: .firstTextBaseline, spacing: 4) {
                                Text(model.displayGlucose)
                                    .font(.system(size: 44, weight: .bold, design: .rounded))
                                    .foregroundStyle(watchGlucoseColor(model.glucose, stale: stale))
                                Text(model.trend).font(.title2)
                                    .foregroundStyle(stale ? .gray : .primary)
                            }
                            Text(model.glucoseDate.map { GlucoseFreshness.ageLabel(for: $0, now: ctx.date) } ?? "mg/dL")
                                .font(.caption2)
                                .fontWeight(stale ? .semibold : .regular)
                                .foregroundStyle(stale ? .orange : .secondary)
                        } else {
                            Text("—").font(.system(size: 44, weight: .bold, design: .rounded))
                            Text(model.glucose == nil ? "mg/dL" : "no recent CGM")
                                .font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }

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
