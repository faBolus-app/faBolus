import Foundation
import faBolusCore
import WidgetKit

/// Publishes the current pump state to the App Group so the Lock/Home Screen widgets can render
/// it, and asks WidgetKit to refresh their timelines. Called on every snapshot update.
enum WidgetPublisher {
    /// Throttle timeline reloads — WidgetKit budgets refreshes, and the pump updates ~every 60 s.
    @MainActor private static var lastReload = Date.distantPast
    /// Whether a trailing reload is already scheduled (A4 fix — see `scheduleReload`).
    @MainActor private static var reloadPending = false

    /// Build the App-Group snapshot from a pump snapshot + history. Pure (no I/O, no WidgetKit) so the
    /// mapping — including P10's freshness policy — is unit-testable without the shared store or a
    /// racing sibling test. `staleAfterSec`/`hideAfterSec` are passed in (from `GlucoseFreshness` at the
    /// call site) so the test can pin them deterministically.
    @MainActor
    static func makeSnapshot(_ s: PumpSnapshot, history: [GlucoseReading], alerts: [String],
                             staleAfterSec: TimeInterval, hideAfterSec: TimeInterval?,
                             hasSnoozeEligibleAlert: Bool = false) -> WidgetSnapshot {
        // Phase 09.26-04 (D-14) — widened from 48 (~4h @ 5-min cadence) to 96 (~8h) so the App-Group
        // snapshot carries enough raw history for consumers that want a denser series (originally
        // added for the since-removed Live Activity's 6h plot-range option, Phase 7 07-01 FEAT-01).
        // The Home Screen widget's own `Sparkline` renders whatever density it's given, so keeping
        // the wider window is harmless and still useful there — no behavior change from narrowing it
        // back down.
        let points = history.suffix(96).map { WidgetSnapshot.Point(t: $0.date, mgdl: $0.mgdl) }
        return WidgetSnapshot(
            glucose: s.glucose,
            glucoseDate: s.glucoseDate,
            trendArrow: s.trend,          // Unicode arrow, same as the HUD
            iobUnits: s.iobUnits,
            reservoirUnits: s.reservoirUnits,
            batteryPercent: s.batteryPercent,
            // Phase 09.27-02 (D-04/D-05) — carried verbatim from the host snapshot; fail-closed
            // decode default (`false`) on the App-Group carrier handles the legacy/absent case.
            batteryCharging: s.batteryCharging,
            lastBolusUnits: s.lastBolusUnits,
            lastBolusDate: s.lastBolusDate,
            connected: s.connection == .connected || s.connection == .bolusing,
            updatedAt: Date(),
            recentPoints: Array(points),
            activeAlerts: alerts,
            cgmActive: s.cgmActive,
            carbRatio: s.carbRatio,
            isf: s.isf,
            targetBg: s.targetBg,
            maxBolusUnits: s.maxBolusUnits,
            // P10 (group A): carry the phone's freshness policy so the iOS widgets grey/hide off the
            // SAMPLE age exactly like the app + the Mac widget — instead of silently falling back to the
            // 6-min hardcode regardless of the user's setting (the iOS staleness defect).
            staleAfterSec: staleAfterSec, hideAfterSec: hideAfterSec,
            // Phase 04-03: the active display unit, as the wire token ("mgdl"|"mmol") — never
            // GlucoseUnit itself (Pitfall 6). The widget/complication island resolves it via the
            // WidgetGlucoseUnit mirror; nil (impossible here, but legacy-safe) ⇒ mgdl.
            displayUnit: AppSettings.shared.glucoseDisplayUnit.wireToken,
            // Phase 5 pump surfaces (D-17, 05-02) — the five faBolus-differentiator fields, mapped
            // straight from PumpSnapshot alongside the existing iobUnits/reservoirUnits mapping above.
            iobDate: s.iobDate,
            basalRateUnitsPerHour: s.basalRateUnitsPerHour,
            deliverySuspended: s.deliverySuspended,
            controlIQMode: s.controlIQMode,
            controlIQEnabled: s.controlIQEnabled,
            // Phase 5 (D-18, 05-05) — app-computed snooze-eligibility gate (see the field's own doc
            // comment on `WidgetSnapshot`); passed in from the caller, which has `PumpAlertKind` on
            // `activeNotifications` (this function only receives bare `alerts: [String]` titles).
            hasSnoozeEligibleAlert: hasSnoozeEligibleAlert,
            // Owner-requested toggle — stamped straight from the setting so the widget/complication/
            // Live Activity gate their persistent unit CAPTION the same way the phone does.
            showUnitLabel: AppSettings.shared.showGlucoseUnitLabels,
            // Phase 09.9-04 (D-05) — the pump's cartridge-ready DISPLAY signal for the widget.
            // WR-04 (debug pump-pairing-loop-api25, deep review): present a positive "ready" ONLY for a
            // CONFIRMED `.ready` reply — `.unknown` (op-20 never answered / auto-excluded) maps to the
            // non-positive `false`, never a fail-open "ready" from a state that was never read (the widget
            // Bool can't carry a third "unknown", so `false` = "omit the positive badge"; Guardrail B's
            // transparency contract, Models.swift). The legacy App-Group DECODE default (absent ⇒ true)
            // is unchanged, so an older widget binary never renders a false "not ready" from a missing key.
            // Dose-path unaffected — the gate reads `cartridgeReadyForBolus`, not this display flag.
            cartridgeReady: s.cartridgeReadiness == .ready)
    }

    @MainActor
    static func publish(_ s: PumpSnapshot, history: [GlucoseReading], alerts: [String] = [],
                        bolusLocked: Bool = false, bolusLockReason: String = "",
                        hasSnoozeEligibleAlert: Bool = false) {
        let snap = makeSnapshot(s, history: history, alerts: alerts,
                                staleAfterSec: GlucoseFreshness.staleAfter, hideAfterSec: GlucoseFreshness.hideAfter,
                                hasSnoozeEligibleAlert: hasSnoozeEligibleAlert)
        WidgetStore.save(snap)
        // Phase 5 (D-13, 05-03) — the same choke point drives the opt-in app-icon badge. The opt-in
        // gate + freshness live inside GlucoseBadge, so this stays a thin call; the arbiter timer
        // re-runs refresh()->publish every ~20s, so the badge re-evaluates and clears to 0 as a
        // reading ages past stale even with no new pump data. WR-01 (R2-08): that ~20s heartbeat is
        // now armed for EVERY config (see AppModel.init) — previously it existed only when a failover
        // glucose source was selected, so a pump-only user's badge never aged; this comment was false
        // for that config until the heartbeat was hoisted unconditionally.
        GlucoseBadge.apply(snap)
        // Keep the Quick-Bolus widget's amount picker in sync with the pump's max + the increment.
        if s.maxBolusUnits > 0 { WidgetBolusStore.maxBolus = s.maxBolusUnits }
        WidgetBolusStore.increment = AppSettings.shared.bolusIncrement
        // A-05: mirror the bolus-lock decision so the widget greys/disables its pad. Written inline here
        // (the caller passes the evaluator's result) — the throttled reload below covers it.
        WidgetBolusStore.bolusLocked = bolusLocked
        WidgetBolusStore.bolusLockReason = bolusLocked ? bolusLockReason : ""

        scheduleReload()
    }

    /// Reload now if outside the 30 s coalesce window; otherwise ensure exactly ONE trailing reload
    /// fires when the window elapses. A4 fix: the old code dropped a throttled reload with no
    /// reschedule, so the LAST snapshot in a burst (e.g. the one that finally crosses stale) never
    /// refreshed the widgets — they stayed on an outdated timeline until the next unthrottled publish.
    @MainActor private static func scheduleReload() {
        let elapsed = Date().timeIntervalSince(lastReload)
        if elapsed > 30 {
            lastReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
        } else if !reloadPending {
            reloadPending = true
            let delay = max(0, 30 - elapsed)
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                reloadPending = false
                lastReload = Date()
                WidgetCenter.shared.reloadAllTimelines()
            }
        }
    }

    /// A-05: mirror ONLY the Quick-Bolus lock state (no pump snapshot needed) and reload the widget now,
    /// so a read-only / child-mode toggle greys the pad immediately rather than at the next pump update.
    /// The decision is the app's single AccessPolicy evaluator's — see `AppModel.publishWidgetLockState()`.
    @MainActor
    static func publishBolusLock(locked: Bool, reason: String) {
        WidgetBolusStore.bolusLocked = locked
        WidgetBolusStore.bolusLockReason = locked ? reason : ""
        WidgetCenter.shared.reloadTimelines(ofKind: "FaBolusQuickBolus")
    }

    /// Phase 04-03: re-stamp `displayUnit` on the most recently published snapshot and reload the
    /// widget timelines immediately — like `publishBolusLock`, this needs no `PumpSnapshot` (the
    /// setting toggle isn't a pump event), so it patches the App-Group value already on disk rather
    /// than waiting for the next `publish(_:)` from a pump update. Called from `AppSettings
    /// .glucoseDisplayUnit`'s `didSet`. Uses the SAME WidgetSnapshot vehicle every glucose render
    /// already reads (Pattern 3) — never `syncWidgetConfig()`, which is the unrelated bolus-increment
    /// channel. A no-op if nothing has been published yet (the next real publish carries the unit).
    @MainActor
    static func republishDisplayUnit() {
        guard var snap = WidgetStore.load() else { return }
        snap.displayUnit = AppSettings.shared.glucoseDisplayUnit.wireToken
        WidgetStore.save(snap)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Owner-requested toggle: re-stamp `showUnitLabel` on the most recently published snapshot and
    /// reload the widget timelines immediately — same idiom as `republishDisplayUnit()` above, called
    /// from `AppSettings.showGlucoseUnitLabels`'s setter (via the `@Stored` `onChange` hook). A no-op if
    /// nothing has been published yet (the next real publish carries the flag).
    @MainActor
    static func republishShowUnitLabel() {
        guard var snap = WidgetStore.load() else { return }
        snap.showUnitLabel = AppSettings.shared.showGlucoseUnitLabels
        WidgetStore.save(snap)
        WidgetCenter.shared.reloadAllTimelines()
    }
}
