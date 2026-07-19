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
                        Text(model.alertDebug).font(.caption2).foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .center)
                    }
                }
                .padding(.vertical)
            }
            .navigationTitle("Alerts")
        }
    }
}
