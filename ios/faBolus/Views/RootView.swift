import PhoneApp
import SwiftUI
import faBolusCore

/// The tabs: Dashboard, Bolus, Alerts, Logbook, Settings. The Bolus tab is there only when the phone may
/// bolus this pump (not read-only, and a model that takes a dose or none paired yet), so a pump without its
/// own screen can get its own screens later without a redesign.
struct RootView: View {
    @Bindable var model: AppModel
    @State private var selection = Tab.dashboard

    enum Tab: Hashable { case dashboard, bolus, alerts, logbook, settings }

    var body: some View {
        // Read here, in the body, so a change re-renders and the cover and sheet follow it.
        let showOnboarding = model.launched && !model.settings.hasCompletedOnboarding && model.pairing == nil
        let showDisclosure =
            model.launched && model.settings.hasCompletedOnboarding
            && !model.settings.notificationDisclosureShown
        return TabView(selection: $selection) {
            DashboardView(model: model)
                .tabItem { Label("Dashboard", systemImage: "gauge.with.dots.needle.bottom.50percent") }.tag(
                    Tab.dashboard)
            if showsBolus {
                NavigationStack { BolusEntryView(model: model) }
                    .tabItem { Label("Bolus", systemImage: "drop.fill") }.tag(Tab.bolus)
            }
            AlertsScreenView(model: model)
                .tabItem { Label("Alerts", systemImage: "bell.fill") }
                .badge(model.display.alerts?.value.count ?? 0).tag(Tab.alerts)
            LogbookView(model: model)
                .tabItem { Label("Logbook", systemImage: "clock.arrow.circlepath") }.tag(Tab.logbook)
            SettingsView(model: model)
                .tabItem { Label("Settings", systemImage: "gearshape.fill") }.tag(Tab.settings)
        }
        .onChange(of: model.openBolusRequested) { _, requested in
            guard requested else { return }
            if showsBolus { selection = .bolus }
            model.openBolusRequested = false
        }
        .onChange(of: showsBolus) { _, shows in
            if !shows, selection == .bolus { selection = .dashboard }
        }
        .fullScreenCover(isPresented: .init(get: { showOnboarding }, set: { _ in })) {
            ConnectPumpOnboardingView(model: model)
        }
        .sheet(
            isPresented: .init(
                get: { showDisclosure }, set: { if !$0 { model.settings.notificationDisclosureShown = true } })
        ) {
            NotificationDisclosureView { model.settings.notificationDisclosureShown = true }
        }
    }

    private var showsBolus: Bool { model.showsBolusTab }
}

/// Shown once, after onboarding: what faBolus's notifications are and aren't.
struct NotificationDisclosureView: View {
    let onDismiss: () -> Void

    var body: some View {
        VStack(spacing: 20) {
            Spacer()
            Image(systemName: "bell.badge").font(.system(size: 48)).foregroundStyle(.tint).accessibilityHidden(true)
            Text("About faBolus notifications").font(.title2).bold()
            Text(
                "Your pump alarms and alerts on its own screen. That's what keeps you safe, with or without a paired phone. faBolus mirrors the pump's alerts here as a convenience, and adds its own for a few things only it can see, like a bolus whose outcome is unknown."
            )
            .foregroundStyle(.secondary)
            Text(
                "Bolus results, a pump that stays disconnected and the backup urgent low can break through Focus when iOS allows it. Turn each kind on or off in Settings → Notifications."
            )
            .foregroundStyle(.secondary)
            Spacer()
            Button("Got it", action: onDismiss).buttonStyle(.borderedProminent)
        }
        .padding()
    }
}
