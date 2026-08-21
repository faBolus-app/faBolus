import SwiftUI
import faBolusCore

@main
struct FaBolusApp: App {
    // The pump backend is chosen from the compile-time BackendRegistry (Tandem on device, mock in
    // the Simulator by default; user-selectable when more than one backend is compiled in).
    @State private var model = AppModel(source: BackendRegistry.makeSelected())
    @State private var remoteHost: PhoneRemoteHost?
    @State private var garmin: GarminRemoteBridge?
    @State private var notifier: NotificationCoordinator?
    @State private var widgetBolus: WidgetBolusReceiver?
    @State private var settings = AppSettings.shared
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootContainerView(model: model)
                .alert("Save this pump's PIN?", isPresented: Binding(
                    get: { model.savePinPrompt != nil },
                    set: { if !$0 { model.dismissSavePinPrompt() } }
                )) {
                    Button("Save PIN") { model.saveOfferedPin() }
                    Button("Not now", role: .cancel) { model.dismissSavePinPrompt() }
                } message: {
                    Text("This looks like a Tandem Mobi — its PIN doesn't change. faBolus can save it so you don't re-type it next time you connect. You can change or clear it later on the Connect screen.")
                }
                .onAppear {
                    // Start listening for remote commands (double-confirm host).
                    if remoteHost == nil { remoteHost = PhoneRemoteHost(model: model) }       // Apple Watch
                    if garmin == nil { garmin = GarminRemoteBridge(model: model) }             // Garmin venu3s
                    if notifier == nil { notifier = NotificationCoordinator(model: model) }      // broker-owned notification path (§6)
                    if widgetBolus == nil { widgetBolus = WidgetBolusReceiver(model: model) }    // Quick-Bolus widget delivery
                    // D-18 (05-05): install the Live Activity intents' in-process hooks — see
                    // `Shared/LiveActivityIntents.swift`'s file-level note on why that file can't
                    // import AppModel directly (it also compiles into the faBolusWidgets extension).
                    LiveActivityIntentBridge.reconnect = { [weak model] in await model?.autoReconnectIfNeeded() }
                    // WR-02 (05-06): the action gate now reads the SAME `AppModel.snoozeGateAllows`
                    // predicate as the button's visibility gate (`hasSnoozeEligibleAlert`, computed in
                    // `AppModel.refresh()`) — previously this used a subtly different "none is .alarm"
                    // check while visibility used "at least one is non-.alarm", so a button could render
                    // and then dead-tap when an alarm and a snoozeable alert were both active at once.
                    LiveActivityIntentBridge.snoozeAlertIfSafe = { [weak model] in
                        guard let model, AppModel.snoozeGateAllows(model.activeNotifications) else { return }
                        NotificationRuntime().snooze(.pumpAlert, until: Date().addingTimeInterval(NotificationCoordinator.snoozeSeconds))
                    }
                    ICloudSettingsSync.shared.start()   // optional; no-op unless built with FABOLUS_ICLOUD
                    AppSettings.shared.syncWidgetConfig()
                    model.publishWidgetLockState()   // A-05: seed the Quick-Bolus widget's lock flag
                    AppSettings.shared.applyFreshness()   // stale/hide thresholds → faBolusCore
                    widgetBolus?.handlePending()   // deliver any queued widget bolus (suspended-app fallback)
                    if WidgetStore.takeOpenBolusRequest() { model.openBolusRequested = true }
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        widgetBolus?.handlePending()
                        if WidgetStore.takeOpenBolusRequest() { model.openBolusRequested = true }
                    } else if phase == .background {
                        ICloudSettingsSync.shared.push()   // optional; no-op unless built with FABOLUS_ICLOUD
                        // debug pump-background-disconnect: no app-side action needed on background. A drop
                        // that happens while suspended is recovered by the kit's INLINE background-safe
                        // connect (H1, PumpBLEClient.planUnintendedDropRecovery); the app-side belt-and-
                        // suspenders bg window is armed by the reconnect-ladder delegate (onWillRetryReconnect
                        // → PumpBackgroundSession.willAttemptReconnect), not from here. H2 (link stays warm)
                        // is battery-neutral: the kit keeps its notification subscriptions across background.
                    }
                }
                // A-05: republish the Quick-Bolus widget's lock the instant a gate that governs it toggles
                // (local read-only, or child mode / its allowed set), so the pad greys without waiting for
                // the next pump update. Only the gates that affect `.deliverBolus` from a local surface.
                .onChange(of: settings.phoneReadOnly) { _, _ in model.publishWidgetLockState() }
                .onChange(of: settings.childModeEnabled) { _, _ in model.publishWidgetLockState() }
                .onChange(of: settings.childAllowed) { _, _ in model.publishWidgetLockState() }
                .onOpenURL { url in
                    if url.scheme == FaBolusDeepLink.scheme {
                        // Widget tap-to-bolus / open (fabolus://bolus). Opens the confirm flow.
                        if url.host == "bolus" { model.openBolusRequested = true }
                    } else {
                        garmin?.handleOpenURL(url)   // Connect IQ device-selection callback
                    }
                }
        }
    }
}
