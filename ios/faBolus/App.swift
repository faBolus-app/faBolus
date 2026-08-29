import SwiftUI
import faBolusCore

@main
struct FaBolusApp: App {
    // The pump backend is chosen from the compile-time BackendRegistry (Tandem on device, mock in
    // the Simulator by default; user-selectable when more than one backend is compiled in).
    @State private var model = AppModel(source: BackendRegistry.makeSelected())
    @State private var garmin: GarminRemoteBridge?
    @State private var notifier: NotificationCoordinator?
    @State private var widgetBolus: WidgetBolusReceiver?
    // Always-on Mobi reject-at-pairing backstop, owned here (outside the SwiftUI
    // view tree) so it runs regardless of which screen is on screen and while backgrounded — see
    // `AppModel+MobiRejectBackstop.swift`.
    @State private var mobiRejectBackstop: MobiRejectBackstop?
    @State private var settings = AppSettings.shared
    @Environment(\.scenePhase) private var scenePhase

    init() {
        // Construct the Garmin bridge at process launch — including a background BLE relaunch,
        // where no view (and thus no `.onAppear`) ever runs — so a remote request always has a
        // live bridge to answer, and (in a GARMIN build) so ConnectIQ's CoreBluetooth state-restoration
        // init happens at launch. Constructed AFTER `model` (the bridge holds a weak model ref and wires
        // echo/status listeners) and retained in the @State below so its `Self.shared` weak ref survives.
        // Same reason the Mobi reject backstop lives outside the view tree.
        let bridge = GarminRemoteBridge(model: model)
        _garmin = State(initialValue: bridge)
        #if GARMIN
        // Re-seed the terminal-echo outbox from the durable ledger at launch, so a bolus outcome
        // recorded but never echoed to the watch across an app kill/relaunch is replayed once the watch is
        // message-ready. Called right after the bridge is built.
        bridge.seedTerminalEchoesFromLedger()
        // Re-seed any authenticated dismiss receipt whose ack was never transport-confirmed across an
        // app kill/relaunch — same launch-time idea as the terminal-echo re-seed, on its own durable
        // lane so the two cannot collide.
        bridge.seedUnsentDismissAcksFromReceiptStore()
        #endif
        // Construct + retain the safety-notification pipeline at process launch too — including a
        // viewless CoreBluetooth cold-restoration relaunch, where no scene/view (and thus no `.onAppear`)
        // ever runs — so a `postSafety` (pump disconnect / CGM data loss / bolus reconciliation) always has
        // a live sink to reach instead of being silently dropped. Same pattern as `GarminRemoteBridge`
        // above. Constructed AFTER `model` (the coordinator wires `model.notificationSink` against it,
        // and flushes any safety alert buffered before this ran). The `.onAppear` `if notifier == nil`
        // guard below stays as double-construct protection — it is a no-op on every launch this `init()`
        // already ran on.
        let notif = NotificationCoordinator(model: model)
        _notifier = State(initialValue: notif)
    }

    var body: some Scene {
        WindowGroup {
            RootContainerView(model: model)
                .alert(
                    "Save this pump's PIN?",
                    isPresented: Binding(
                        get: { model.savePinPrompt != nil },
                        set: { if !$0 { model.dismissSavePinPrompt() } }
                    )
                ) {
                    Button("Save PIN") { model.saveOfferedPin() }
                    Button("Not now", role: .cancel) { model.dismissSavePinPrompt() }
                } message: {
                    Text(
                        "This looks like a Tandem Mobi — its PIN doesn't change. faBolus can save it so you don't re-type it next time you connect. You can change or clear it later on the Connect screen."
                    )
                }
                .onAppear {
                    // The Garmin bridge is constructed at launch in `init()` (above),
                    // not lazily here, so a background BLE relaunch has a live bridge before any view appears.
                    if notifier == nil { notifier = NotificationCoordinator(model: model) }  // broker-owned notification path (§6)
                    if widgetBolus == nil { widgetBolus = WidgetBolusReceiver(model: model) }  // Quick-Bolus widget delivery
                    // Start the always-on Mobi reject backstop exactly once — it
                    // then runs for the process's lifetime independent of any view's presence.
                    if mobiRejectBackstop == nil {
                        let backstop = MobiRejectBackstop(model: model)
                        backstop.start()
                        mobiRejectBackstop = backstop
                    }
                    #if FABOLUS_BACKUP
                    ICloudSettingsSync.shared.start()  // optional; no-op unless built with FABOLUS_ICLOUD
                    #endif
                    AppSettings.shared.syncWidgetConfig()
                    model.publishWidgetLockState()  // seed the Quick-Bolus widget's lock flag
                    AppSettings.shared.applyFreshness()  // stale/hide thresholds → faBolusCore
                    // Apply pinned history retention at every launch. The Data/History view that used
                    // to be the only caller of `applyRetention` is gone, so without this the setting
                    // would read as pinned but nothing would prune older glucose.
                    model.applyRetention(days: AppSettings.shared.historyRetentionDays)
                    widgetBolus?.handlePending()  // deliver any queued widget bolus (suspended-app fallback)
                }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active {
                        widgetBolus?.handlePending()
                        // Force a fresh status on foreground-resume even when the snapshot already says
                        // connected. `RootTabView.autoReconnectIfNeeded()` returns early on a warm
                        // `.connected` link, and while suspended the poll timers didn't tick — so
                        // HUD/widget/Garmin can show pre-suspension IOB/reservoir/battery as current.
                        // `publicRefresh()` (re-publish + staleness re-eval, no BLE read) is always safe and
                        // runs unconditionally; a REAL read via `refreshGlucoseNow()` runs ONLY when the link
                        // is genuinely usable — post-auth `.connected` (`.connected` is no longer published
                        // at bare BLE `.ready`), so a resume never sends BLE I/O into a dead or pre-auth link.
                        Task { @MainActor in
                            model.publicRefresh()
                            if model.snapshot.connection == .connected { await model.refreshGlucoseNow() }
                        }
                    } else if phase == .background {
                        #if FABOLUS_BACKUP
                        ICloudSettingsSync.shared.push()  // optional; no-op unless built with FABOLUS_ICLOUD
                        #endif
                        // debug pump-background-disconnect: no app-side action needed on background. A drop
                        // that happens while suspended is recovered by the kit's INLINE background-safe
                        // connect (H1, PumpBLEClient.planUnintendedDropRecovery); the app-side belt-and-
                        // suspenders bg window is armed by the reconnect-ladder delegate (onWillRetryReconnect
                        // → PumpBackgroundSession.willAttemptReconnect), not from here. H2 (link stays warm)
                        // is battery-neutral: the kit keeps its notification subscriptions across background.
                    }
                }
                // Republish the Quick-Bolus widget's lock the instant a gate that governs it toggles
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
                        garmin?.handleOpenURL(url)  // Connect IQ device-selection callback
                    }
                }
        }
    }
}
