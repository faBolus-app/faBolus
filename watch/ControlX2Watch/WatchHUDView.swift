import SwiftUI

/// Loop-style watch glance: glucose + trend (hidden when stale), Active Insulin, reservoir,
/// last bolus, active alerts (with clear), and a Bolus button leading to the Digital Crown dial.
struct WatchHUDView: View {
    @Bindable var model: WatchModel
    @State private var showBolus = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 8) {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text(model.displayGlucose)
                            .font(.system(size: 40, weight: .bold, design: .rounded))
                            .foregroundStyle(model.glucose.map { glucoseColor($0) } ?? .gray)
                        if !model.isGlucoseStale { Text(model.trend).font(.title3) }
                    }
                    Text(model.isGlucoseStale ? "no recent CGM" : "mg/dL")
                        .font(.caption2).foregroundStyle(.secondary)

                    HStack(spacing: 12) {
                        Label(String(format: "%.2f U", model.iobUnits), systemImage: "syringe")
                        Label("\(Int(model.reservoirUnits)) U", systemImage: "drop")
                    }.font(.caption2).foregroundStyle(.secondary)
                    if let lb = model.lastBolusUnits {
                        Text("Last bolus \(String(format: "%.2f U", lb))")
                            .font(.caption2).foregroundStyle(.secondary)
                    }

                    // Active pump alerts, each with a Clear button.
                    ForEach(model.alerts, id: \.id) { a in
                        HStack {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(a.title).font(.caption2).lineLimit(2)
                            Spacer()
                            Button("Clear") { model.dismissAlert(a) }
                                .font(.caption2).buttonStyle(.bordered).tint(.orange)
                        }
                        .padding(6)
                        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    }

                    Label(model.reachable ? "iPhone connected" : "iPhone out of range",
                          systemImage: model.reachable ? "iphone" : "iphone.slash")
                        .font(.caption2)
                        .foregroundStyle(model.reachable ? .green : .orange)

                    Button { showBolus = true } label: { Label("Bolus", systemImage: "drop.fill") }
                        .tint(.indigo)
                        .disabled(!model.reachable)
                }
            }
            .navigationTitle("ControlX2")
            .sheet(isPresented: $showBolus) { WatchBolusView(model: model) }
            .onAppear { model.requestStatus() }
        }
    }

    private func glucoseColor(_ mgdl: Int) -> Color {
        if model.isGlucoseStale { return .gray }
        switch mgdl {
        case ..<70: return .red
        case 70..<180: return .green
        case 180..<250: return .yellow
        default: return .orange
        }
    }
}
