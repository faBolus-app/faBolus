import SwiftUI

/// Alerts tab: the full list of active pump alerts/alarms, each clearable, plus the poll
/// diagnostic. (The same banner also appears on the Dashboard.)
struct AlertsScreenView: View {
    @Bindable var model: AppModel

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if model.activeNotifications.isEmpty {
                        ContentUnavailableView("No active alerts", systemImage: "checkmark.circle",
                                               description: Text("Pump alerts and alarms will appear here."))
                            .padding(.top, 40)
                    } else {
                        AlertsBannerView(model: model)
                    }
                    if model.snapshot.connection == .connected {
                        // Diagnostic: after tapping Clear, this shows the pump's ack — status 0
                        // usually means accepted; a non-zero status means the pump rejected it.
                        Label(model.alertDebug, systemImage: "stethoscope")
                            .font(.caption).foregroundStyle(.secondary)
                            .padding(8).background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))
                            .frame(maxWidth: .infinity)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Alerts")
        }
    }
}
