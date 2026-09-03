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
        // Guard lives on AppModel — see `AppModel.autoReconnectIfNeeded()`'s doc comment.
        await model.autoReconnectIfNeeded()
    }

    /// Don't leave the user on the Bolus tab after read-only hides it. Only tag `1` is conditional;
    /// 0/2/3/4 always exist. Internal so `RootTabSelectionGuardTests` can call it.
    static func resolveSelection(current: Int, phoneReadOnly: Bool) -> Int {
        (phoneReadOnly && current == 1) ? 0 : current
    }

    /// SwiftUI presents at most one `.alert` per view. Pick one by priority so the remote-bolus
    /// confirm is never the alert that gets dropped.
    enum RootAlert { case remoteBolus, remoteControl }
    static func activeAlert(hasRemoteBolus: Bool, hasRemoteControl: Bool) -> RootAlert? {
        if hasRemoteBolus { return .remoteBolus }
        if hasRemoteControl { return .remoteControl }
        return nil
    }
    private var active: RootAlert? {
        Self.activeAlert(
            hasRemoteBolus: model.pendingRemoteBolus != nil,
            hasRemoteControl: model.pendingRemoteControl != nil)
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
        .tabViewStyle(.sidebarAdaptable)
        .task { await autoReconnectIfNeeded() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { Task { await autoReconnectIfNeeded() } }
        }
        .onChange(of: model.openBolusRequested) { _, requested in
            // Widget deep link → Bolus tab (no-op in read-only, where the tab is hidden).
            if requested {
                if !settings.phoneReadOnly { selection = 1 }
                model.openBolusRequested = false
            }
        }
        .onChange(of: settings.phoneReadOnly) { _, isReadOnly in
            // Never strand the user on a tab the toggle just hid.
            selection = Self.resolveSelection(current: selection, phoneReadOnly: isReadOnly)
        }
        // `presenting:` captures one snapshot of the pending request for both closures so the
        // confirmed amount can't drift if the model updates while the alert is on screen.
        .alert(
            String(localized: "Remote bolus request"), isPresented: .constant(active == .remoteBolus),
            presenting: model.pendingRemoteBolus
        ) { p in
            Button(
                String(format: String(localized: "Deliver %@"), String(format: "%.2f U", p.units)),
                role: .destructive
            ) {
                Task { await model.confirmRemoteBolus() }
            }
            Button(String(localized: "Reject"), role: .cancel) { model.rejectRemoteBolus() }
        } message: { p in
            // Frozen dose + the inputs it was computed from — never a live 0.00 U re-read.
            var parts = [String(format: String(localized: "A remote requested %@."), String(format: "%.2f U", p.units))]
            if let c = p.carbsGrams, c > 0 {
                parts.append(String(format: String(localized: "Carbs: %@."), String(format: "%.0f g", c)))
            }
            if let bg = p.bgMgdl {
                // Display-unit funnel: this confirm approves insulin; BG must match every other
                // glucose number on screen, never a bare mg/dL literal.
                let unit = settings.glucoseDisplayUnit
                let bgStr = "\(unit.format(mgdl: bg)) \(unit == .mmol ? "mmol/L" : "mg/dL")"
                if let bgDate = p.bgDate {
                    let ageStr = "\(max(0, Int(Date().timeIntervalSince(bgDate) / 60)))"
                    parts.append(String(format: String(localized: "BG: %@ (%@ min ago)."), bgStr, ageStr))
                } else {
                    parts.append(String(format: String(localized: "BG: %@."), bgStr))
                }
            } else if let c = p.carbsGrams, c > 0 {
                parts.append(String(localized: "No fresh CGM — carbs only, no correction."))
            }
            if let iob = p.iobUnits {
                parts.append(String(format: String(localized: "IOB: %@."), String(format: "%.2f U", iob)))
            }
            parts.append(String(localized: "Confirm to deliver."))
            return Text(parts.joined(separator: " "))
        }
        .alert("Remote pump-control request", isPresented: .constant(active == .remoteControl)) {
            let action = model.pendingRemoteControl?.action
            Button(
                action == .suspend ? "Suspend insulin" : "Resume insulin", role: action == .suspend ? .destructive : nil
            ) {
                Task { await model.confirmRemoteControl() }
            }
            Button("Reject", role: .cancel) { model.rejectRemoteControl() }
        } message: {
            Text(
                "A remote requested to \(model.pendingRemoteControl?.action == .suspend ? "suspend" : "resume") insulin delivery. Confirm on the phone to proceed."
            )
        }
    }
}
