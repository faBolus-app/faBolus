import SwiftUI

/// Loop-style watch glance: glucose + trend, Active Insulin, phone reachability, and a Bolus
/// button leading to the Digital Crown dial.
struct WatchHUDView: View {
    @Bindable var model: WatchModel
    @State private var showBolus = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 8) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(model.glucose.map { "\($0)" } ?? "—")
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .foregroundStyle(model.glucose.map { glucoseColor($0) } ?? .gray)
                    Text(model.trend).font(.title3)
                }
                Text("mg/dL").font(.caption2).foregroundStyle(.secondary)

                HStack {
                    Image(systemName: "drop.fill").foregroundStyle(.indigo)
                    Text(String(format: "%.2f U", model.iobUnits)).font(.footnote)
                }

                Label(model.reachable ? "iPhone connected" : "iPhone out of range",
                      systemImage: model.reachable ? "iphone" : "iphone.slash")
                    .font(.caption2)
                    .foregroundStyle(model.reachable ? .green : .orange)

                Button { showBolus = true } label: {
                    Label("Bolus", systemImage: "drop.fill")
                }
                .tint(.indigo)
                .disabled(!model.reachable)
            }
            .navigationTitle("ControlX2")
            .sheet(isPresented: $showBolus) { WatchBolusView(model: model) }
            .onAppear { model.requestStatus() }
        }
    }

    private func glucoseColor(_ mgdl: Int) -> Color {
        switch mgdl {
        case ..<70: return .red
        case 70..<180: return .green
        case 180..<250: return .yellow
        default: return .orange
        }
    }
}
