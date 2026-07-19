import SwiftUI

/// Modern iOS tab bar: Dashboard · Bolus · Alerts · Settings. Cross-tab concerns (auto-reconnect,
/// the remote-bolus confirm, the widget deep link) live here.
struct RootTabView: View {
    @Bindable var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection = 0

    private func autoReconnectIfNeeded() async {
        guard model.hasStoredPairing, model.snapshot.connection == .disconnected else { return }
        await model.connect()
    }

    var body: some View {
        TabView(selection: $selection) {
            DashboardView(model: model)
                .tabItem { Label("Dashboard", systemImage: "gauge.with.dots.needle.bottom.50percent") }.tag(0)
            NavigationStack { BolusEntryView(model: model, embedded: true) }
                .tabItem { Label("Bolus", systemImage: "drop.fill") }.tag(1)
            AlertsScreenView(model: model)
                .tabItem { Label("Alerts", systemImage: "bell.fill") }
                .badge(model.activeNotifications.count).tag(2)
            SettingsView(model: model)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(3)
        }
        .task { await autoReconnectIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await autoReconnectIfNeeded() } }
        }
        .onChange(of: model.openBolusRequested) { _, requested in
            if requested { selection = 1; model.openBolusRequested = false }  // widget deep link → Bolus
        }
        .alert("Remote bolus request", isPresented: .constant(model.pendingRemoteBolus != nil)) {
            Button("Deliver \(String(format: "%.2f U", model.pendingRemoteBolus?.units ?? 0))", role: .destructive) {
                Task { await model.confirmRemoteBolus() }
            }
            Button("Reject", role: .cancel) { model.rejectRemoteBolus() }
        } message: {
            Text("A remote requested \(String(format: "%.2f U", model.pendingRemoteBolus?.units ?? 0)) of SALINE. Confirm to deliver on the bench.")
        }
    }
}
