import SwiftUI
import faBolusCore

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
                        if !model.capabilities.supportsRemoteAlertDismiss {
                            Text("This pump model (t:slim X2) doesn’t allow dismissing notifications from a phone — Tandem’s own app disables it too. “Snooze” silences the alert here in faBolus; you’ll still need to clear it on the pump.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal)
                        }
                        if model.activeNotifications.contains(where: { $0.kind == .cgmAlert }) {
                            Text("A CGM alert like “high glucose” is condition-based: the pump keeps re-raising it while the reading is actually high, so it can’t be cleared on the pump until glucose comes back in range. Clearing here snoozes it on your phone.")
                                .font(.caption2).foregroundStyle(.secondary)
                                .padding(.horizontal)
                        }
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
