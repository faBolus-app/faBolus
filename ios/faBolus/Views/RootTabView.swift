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
        // Guard lives on AppModel (D-18, 05-05) — see `AppModel.autoReconnectIfNeeded()`'s doc
        // comment. Originally shared with the Live Activity's Refresh intent (removed Phase 7,
        // 07-01, FEAT-01); the guard itself is unaffected.
        await model.autoReconnectIfNeeded()
    }

    /// SC3 tab-strand guard (D-03, T-09.2-07/T-09.2-08). Only tag `1` (Bolus) is conditionally removed
    /// from the TabView when `phoneReadOnly` is on (`:23-26` below) — tags 0/2/3/4 are always present.
    /// Pure function so it's unit-testable without instantiating the TabView (mirrors the
    /// `reenterMatches` static-for-test idiom in `BolusEntryView`). `internal` (not `private`) so
    /// `RootTabSelectionGuardTests` (`@testable import faBolus`) can call it directly.
    static func resolveSelection(current: Int, phoneReadOnly: Bool) -> Int {
        (phoneReadOnly && current == 1) ? 0 : current
    }

    /// WR-03 (VA-23): SwiftUI presents at most one `.alert` per view, so three sibling alerts on the
    /// TabView can drop the loser when two conditions hold at one render. Resolve a single active alert by
    /// priority — the high-stakes remote-bolus confirm always wins and is never the one dropped. Pure /
    /// static so it's unit-testable without the TabView (mirrors the `resolveSelection` idiom).
    enum RootAlert { case remoteBolus, remoteControl, pumpSwitch }
    static func activeAlert(hasRemoteBolus: Bool, hasRemoteControl: Bool, pumpSwitch: Bool) -> RootAlert? {
        if hasRemoteBolus   { return .remoteBolus }
        if hasRemoteControl { return .remoteControl }
        if pumpSwitch       { return .pumpSwitch }
        return nil
    }
    private var active: RootAlert? {
        Self.activeAlert(hasRemoteBolus: model.pendingRemoteBolus != nil,
                         hasRemoteControl: model.pendingRemoteControl != nil,
                         pumpSwitch: model.pendingPumpSwitch)
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
            if requested { if !settings.phoneReadOnly { selection = 1 }; model.openBolusRequested = false }
        }
        .onChange(of: settings.phoneReadOnly) { _, isReadOnly in
            // SC3 (D-03): never strand the user on a tab the toggle just hid.
            selection = Self.resolveSelection(current: selection, phoneReadOnly: isReadOnly)
        }
        .alert("Remote bolus request", isPresented: .constant(active == .remoteBolus)) {
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
                    // CR-01 gap closure (04-07): route through the display-unit funnel — this
                    // dialog is the highest-stakes confirm flow in the app (approving a
                    // remote-triggered insulin delivery); the audit BG figure must match every
                    // other glucose number the user sees, not stay a bare mg/dL literal.
                    let unit = settings.glucoseDisplayUnit
                    let bgStr = "\(unit.format(mgdl: bg)) \(unit == .mmol ? "mmol/L" : "mg/dL")"
                    let age = p.bgDate.map { max(0, Int(Date().timeIntervalSince($0) / 60)) }
                    parts.append(age != nil ? "BG: \(bgStr) (\(age!) min ago)." : "BG: \(bgStr).")
                } else if let c = p.carbsGrams, c > 0 {
                    parts.append("No fresh CGM — carbs only, no correction.")
                }
                if let iob = p.iobUnits { parts.append(String(format: "IOB: %.2f U.", iob)) }
                parts.append("Confirm to deliver.")
                return Text(parts.joined(separator: " "))
            }
            return Text("Confirm to deliver.")
        }
        .alert("Remote pump-control request", isPresented: .constant(active == .remoteControl)) {
            let action = model.pendingRemoteControl?.action
            Button(action == .suspend ? "Suspend insulin" : "Resume insulin", role: action == .suspend ? .destructive : nil) {
                Task { await model.confirmRemoteControl() }
            }
            Button("Reject", role: .cancel) { model.rejectRemoteControl() }
        } message: {
            Text("A remote requested to \(model.pendingRemoteControl?.action == .suspend ? "suspend" : "resume") insulin delivery. Confirm on the phone to proceed.")
        }
        // B4 (owner 2026-08-09): a DIFFERENT pump connected. Its therapy values were already refreshed
        // automatically; offer to also reset pump-specific app settings so two pumps' configs don't mix.
        .alert("A different pump is connected", isPresented: Binding(
            get: { active == .pumpSwitch },
            set: { if !$0 { model.pendingPumpSwitch = false } })) {
            Button("Reset pump settings", role: .destructive) { model.resetPumpRelevantSettingsAfterSwitch() }
            Button("Keep everything", role: .cancel) { model.keepSettingsAfterPumpSwitch() }
        } message: {
            Text("This pump is different from the one faBolus last used, so its therapy values were refreshed automatically. Reset pump-specific app settings too — Control-IQ automation, pump time-sync, alert rules, and the therapy change history — back to defaults? Your display preferences and CGM setup are kept either way.")
        }
    }
}
