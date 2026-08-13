import AppIntents
import Foundation

/// D-18 (05-05) — safe, NON-DOSING Live Activity interactivity, plus the machine-enforced Phase 7
/// boundary ("an ambient surface never reaches a signed delivery command"). Every intent below
/// conforms to `LiveActivityIntent`, which the system runs IN THE APP'S PROCESS — not the widget
/// extension — once the user taps a `Button(intent:)` on the Live Activity (05-PUMP-SURFACE-
/// RESEARCH.md §3, High confidence).
///
/// This file compiles into BOTH the `faBolus` app target AND the `faBolusWidgets` extension target
/// (`project.yml`) — the extension needs the intent TYPES to build `Button(intent:)` in
/// `GlucoseLiveActivity.swift`, even though its own compiled copy of `perform()` never actually runs
/// (the OS always executes the app-target's copy). Because of that dual membership, this file must
/// NOT import anything the extension can't see: `AppModel`/`NotificationCoordinator`/
/// `NotificationRuntime` all live under `ios/faBolus/Data/`, which is NOT in the extension's
/// `project.yml` source list (confirmed empirically — see the plan's own Deviations). Reaching them
/// is done through `LiveActivityIntentBridge` below: a pair of optional hooks the APP wires at
/// launch, mirroring the exact precedent `AppModel.shared`'s weak-reference doc comment already
/// describes for this class of problem ("headless App Intents... can reach it when the app is
/// running... nil when the app process isn't alive"). Nil in the extension process (never populated
/// there); the app installs both closures once, in `FaBolusApp`'s `onAppear`. This keeps the actual
/// call a DIRECT in-process call once installed — no Darwin-notification hop, matching the plan's
/// own "no Darwin hop needed" design intent.
///
/// Phase 7 boundary: NONE of the three intents below may reference `BolusGate`, `deliverWidgetBolus`,
/// `WidgetBolusStore`/its `setPending`, or `darwinPending`. `LiveActivityBoundaryTests` (app test
/// target) source-scans this file for exactly those symbols and fails the build if any ever appears.

/// App-installed hooks so these in-process intents can reach `AppModel`/`NotificationCoordinator`
/// state without this file importing either type directly (see the file-level note above). The whole
/// enum is `@MainActor` (mirrors `AppModel.shared`'s own isolation — both `AppModel` and
/// `NotificationRuntime`/`NotificationCoordinator` are `@MainActor`-isolated classes) so the static
/// hook storage itself is concurrency-safe, not just the closures' bodies.
@MainActor
enum LiveActivityIntentBridge {
    /// Reconnects the pump link if a pairing exists and it's currently disconnected — the exact guard
    /// now on `AppModel.autoReconnectIfNeeded()` (promoted there from a private `RootTabView` helper
    /// of the same name, so both callers share ONE implementation). Pure link maintenance — no dose.
    static var reconnect: (() async -> Void)?
    /// Snoozes the local `.pumpAlert` notification category for the standard window — but ONLY when
    /// no `.alarm`-kind pump alert is currently active (`PumpAlertKind.isAutoRuleEligible`). Mutates
    /// LOCAL notification state only; never a pump write (05-PUMP-SURFACE-RESEARCH.md §3b). The app
    /// re-checks this exact guard when the closure runs, so an alarm can never be silenced from the
    /// Live Activity even in the (should-be-impossible) case the button was still visible.
    static var snoozeAlertIfSafe: (() -> Void)?

    /// Reads AND calls `reconnect` in one MainActor-isolated step — never returns the closure value
    /// itself across the actor boundary (the closure type isn't `Sendable`; only `Void` crosses back).
    static func performReconnect() async { await reconnect?() }
    /// Reads AND calls `snoozeAlertIfSafe` in one MainActor-isolated step, same rationale as above.
    static func performSnoozeIfSafe() { snoozeAlertIfSafe?() }
}

/// "Open Bolus" — bare navigation to the bolus ENTRY screen, carrying NO dose/carb. Reuses the exact
/// seam Siri's `OpenBolusScreenIntent` (`ios/faBolus/Intents/ShortcutsIntents.swift`) and the widget
/// deep link already use: `WidgetStore.requestOpenBolus()` → drained on the app becoming active →
/// `AppModel.openBolusRequested = true` → `RootTabView` switches to the Bolus tab (a no-op under
/// `phoneReadOnly`, where that tab is hidden). `openAppWhenRun = true` foregrounds the app so any
/// real bolus is driven through the normal in-app SIGNED confirm flow — never a background dispense.
struct LAOpenBolusIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Open Bolus Screen"
    static let description = IntentDescription("Open faBolus to the bolus entry screen. You still confirm the dose in the app.")
    static let openAppWhenRun = true

    func perform() async throws -> some IntentResult {
        WidgetStore.requestOpenBolus()
        return .result()
    }
}

/// "Snooze" — mutates LOCAL notification/alert state only, never a pump write. Never offered on (and,
/// via `LiveActivityIntentBridge.snoozeAlertIfSafe`'s own re-check, never ACTS on) a non-auto-
/// dismissable `.alarm` (05-PUMP-SURFACE-RESEARCH.md §3b, D-18). Does not foreground the app — the
/// result is visible on the LA's own alert-eligibility flag at the next publish.
struct LASnoozeAlertIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Snooze Pump Alert"
    static let description = IntentDescription("Silences the pump alert on this device only, for a couple of hours. It never acknowledges an alarm, and never writes to the pump.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await LiveActivityIntentBridge.performSnoozeIfSafe()
        return .result()
    }
}

/// "Refresh" — kicks the app's existing reconnect entry point. Pure link maintenance: no dose, no
/// pump write beyond the normal BLE connect handshake the app already performs on every launch/
/// foreground.
struct LAReconnectIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Reconnect"
    static let description = IntentDescription("Reconnect to your pump if the link has dropped.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        await LiveActivityIntentBridge.performReconnect()
        return .result()
    }
}
