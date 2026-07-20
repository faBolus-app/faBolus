import SwiftUI

/// Alerts page: active pump alerts/alarms, each clearable (relayed to the phone, which sends the
/// signed dismiss). Notes that CGM alerts are condition-based, matching the phone.
struct WatchAlertsView: View {
    @Bindable var model: WatchModel

    var body: some View {
        ScrollView {
            VStack(spacing: 8) {
                Text("Alerts").font(.headline).frame(maxWidth: .infinity, alignment: .leading)

                if model.alerts.isEmpty {
                    Image(systemName: "checkmark.circle").font(.title2).foregroundStyle(.secondary)
                    Text("No active alerts").font(.caption).foregroundStyle(.secondary)
                } else {
                    ForEach(model.alerts, id: \.id) { a in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack(alignment: .top) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                Text(a.title).font(.caption).lineLimit(3)
                                Spacer()
                            }
                            Button("Clear") { model.dismissAlert(a) }
                                .font(.caption2).buttonStyle(.bordered).tint(.orange)
                        }
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
                    }
                    // kind 3 == CGM alert (condition-based).
                    if model.alerts.contains(where: { $0.kind == 3 }) {
                        Text("A CGM alert can’t clear on the pump until glucose is back in range; clearing snoozes it here.")
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(6)
        }
    }
}
