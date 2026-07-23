import SwiftUI
import faBolusCore

/// Modern iOS tab bar: Dashboard · Bolus · Alerts · Settings. Cross-tab concerns (auto-reconnect,
/// the remote-bolus confirm, the widget deep link) live here.
struct RootTabView: View {
    @Bindable var model: AppModel
    @State private var settings = AppSettings.shared
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
            if !settings.phoneReadOnly {
                NavigationStack { BolusEntryView(model: model, embedded: true) }
                    .tabItem { Label("Bolus", systemImage: "drop.fill") }.tag(1)
            }
            AlertsScreenView(model: model)
                .tabItem { Label("Alerts", systemImage: "bell.fill") }
                .badge(model.activeNotifications.count).tag(2)
            LogbookView(model: model)
                .tabItem { Label("Logbook", systemImage: "clock.arrow.circlepath") }.tag(3)
            SettingsView(model: model)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(4)
        }
        .task { await autoReconnectIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await autoReconnectIfNeeded() } }
        }
        .onChange(of: model.openBolusRequested) { _, requested in
            // Widget deep link → Bolus tab (no-op in read-only, where the tab is hidden).
            if requested { if !settings.phoneReadOnly { selection = 1 }; model.openBolusRequested = false }
        }
        .alert("Remote bolus request", isPresented: .constant(model.pendingRemoteBolus != nil)) {
            Button("Deliver \(String(format: "%.2f U", model.pendingRemoteBolus?.units ?? 0))", role: .destructive) {
                Task { await model.confirmRemoteBolus() }
            }
            Button("Reject", role: .cancel) { model.rejectRemoteBolus() }
        } message: {
            // Show the FROZEN dose + the exact inputs it was computed from (audit C-02) — never "0.00 U".
            if let p = model.pendingRemoteBolus {
                var parts = [String(format: "A remote requested %.2f U.", p.units)]
                if let c = p.carbsGrams, c > 0 { parts.append(String(format: "Carbs: %.0f g.", c)) }
                if let bg = p.bgMgdl {
                    let age = p.bgDate.map { max(0, Int(Date().timeIntervalSince($0) / 60)) }
                    parts.append(age != nil ? "BG: \(bg) mg/dL (\(age!) min ago)." : "BG: \(bg) mg/dL.")
                } else if let c = p.carbsGrams, c > 0 {
                    parts.append("No fresh CGM — carbs only, no correction.")
                }
                if let iob = p.iobUnits { parts.append(String(format: "IOB: %.2f U.", iob)) }
                parts.append("Confirm to deliver.")
                return Text(parts.joined(separator: " "))
            }
            return Text("Confirm to deliver.")
        }
        .alert("Remote pump-control request", isPresented: .constant(model.pendingRemoteControl != nil)) {
            let action = model.pendingRemoteControl?.action
            Button(action == .suspend ? "Suspend insulin" : "Resume insulin", role: action == .suspend ? .destructive : nil) {
                Task { await model.confirmRemoteControl() }
            }
            Button("Reject", role: .cancel) { model.rejectRemoteControl() }
        } message: {
            Text("A remote requested to \(model.pendingRemoteControl?.action == .suspend ? "suspend" : "resume") insulin delivery. Confirm on the phone to proceed.")
        }
    }
}
