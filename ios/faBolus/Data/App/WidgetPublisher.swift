import Foundation
import faBolusCore
import WidgetKit

/// Publishes the current pump state to the App Group so the Lock/Home Screen widgets can render
/// it, and asks WidgetKit to refresh their timelines. Called on every snapshot update.
enum WidgetPublisher {
    /// Throttle timeline reloads — WidgetKit budgets refreshes, and the pump updates ~every 60 s.
    @MainActor private static var lastReload = Date.distantPast
    /// Whether a trailing reload is already scheduled (see `scheduleReload`).
    @MainActor private static var reloadPending = false

    /// Build the App-Group snapshot from a pump snapshot + history. Pure (no I/O, no WidgetKit) so the
    /// mapping — including P10's freshness policy — is unit-testable without the shared store or a
    /// racing sibling test. `staleAfterSec`/`hideAfterSec` are passed in (from `GlucoseFreshness` at the
    /// call site) so the test can pin them deterministically.
    @MainActor
    static func makeSnapshot(
        _ s: PumpSnapshot, history: [GlucoseReading], alerts: [String],
        staleAfterSec: TimeInterval, hideAfterSec: TimeInterval?,
        hasSnoozeEligibleAlert: Bool = false
    ) -> WidgetSnapshot {
        // ~8h of 5-min-cadence points so the App-Group snapshot carries enough raw history for a
        // denser series. The Home Screen widget's own `Sparkline` renders whatever density it's given.
        let points = history.suffix(96).map { WidgetSnapshot.Point(t: $0.date, mgdl: $0.mgdl) }
        return WidgetSnapshot(
            glucose: s.glucose,
            glucoseDate: s.glucoseDate,
            trendArrow: s.trend,  // Unicode arrow, same as the HUD
            iobUnits: s.iobUnits,
            reservoirUnits: s.reservoirUnits,
            batteryPercent: s.batteryPercent,
            // Fail-closed decode default (`false`) on the App-Group carrier handles the
            // legacy/absent case.
            batteryCharging: s.batteryCharging,
            // Read receipts travel with the values so the widget/complication can render "—" for a
            // read the pump never answered instead of a fabricated 0
            // (debug `tslim-reservoir-battery-zero`). Declared order in `WidgetSnapshot.init` is
            // batteryCharging -> reservoirDate -> batteryDate; Swift requires call order to match.
            reservoirDate: s.reservoirDate,
            batteryDate: s.batteryDate,
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
            // Carry the phone's freshness policy so the iOS widgets grey/hide off the SAMPLE age
            // exactly like the app — instead of silently falling back to the 6-min hardcode
            // regardless of the user's setting.
            staleAfterSec: staleAfterSec, hideAfterSec: hideAfterSec,
            // The active display unit, as the wire token ("mgdl"|"mmol") — never GlucoseUnit itself.
            // The widget island resolves it via the WidgetGlucoseUnit mirror; nil ⇒ mgdl.
            displayUnit: AppSettings.shared.glucoseDisplayUnit.wireToken,
            // Pump-surface fields, mapped straight from PumpSnapshot alongside iobUnits/reservoirUnits.
            iobDate: s.iobDate,
            basalRateUnitsPerHour: s.basalRateUnitsPerHour,
            // The op-77 read receipt for the line above. Published even though no widget family renders
            // basal today: the carrier was otherwise publishing a fabricated `0.00 U/hr` for a pump that
            // had never answered the read, and a receipt that ships with the value can't be forgotten
            // later. Declared order in `WidgetSnapshot.init` is basalRateUnitsPerHour -> basalRateKnown
            // -> deliverySuspended; Swift requires call order to match.
            basalRateKnown: s.basalRateKnown,
            deliverySuspended: s.deliverySuspended,
            controlIQMode: s.controlIQMode,
            controlIQEnabled: s.controlIQEnabled,
            // App-computed snooze-eligibility gate (see the field's own doc comment on
            // `WidgetSnapshot`); passed in from the caller, which has `PumpAlertKind` on
            // `activeNotifications` (this function only receives bare `alerts: [String]` titles).
            hasSnoozeEligibleAlert: hasSnoozeEligibleAlert,
            // Owner-requested toggle — stamped straight from the setting so the widget/complication/
            // Live Activity gate their persistent unit CAPTION the same way the phone does.
            showUnitLabel: AppSettings.shared.showGlucoseUnitLabels,
            // The pump's cartridge-ready DISPLAY signal for the widget. Present a positive "ready"
            // ONLY for a CONFIRMED `.ready` reply — `.unknown` (op-20 never answered / auto-excluded)
            // maps to the non-positive `false`, never a fail-open "ready" from a state that was never
            // read (the widget Bool can't carry a third "unknown", so `false` = "omit the positive
            // badge"). The legacy App-Group DECODE default (absent ⇒ true) is unchanged, so an older
            // widget binary never renders a false "not ready" from a missing key. Dose-path unaffected
            // — the gate reads `cartridgeReadyForBolus`, not this display flag.
            cartridgeReady: s.cartridgeReadiness == .ready)
    }

    @MainActor
    static func publish(
        _ s: PumpSnapshot, history: [GlucoseReading], alerts: [String] = [],
        bolusLocked: Bool = false, bolusLockReason: String = "",
        hasSnoozeEligibleAlert: Bool = false
    ) {
        let snap = makeSnapshot(
            s, history: history, alerts: alerts,
            staleAfterSec: GlucoseFreshness.staleAfter, hideAfterSec: GlucoseFreshness.hideAfter,
            hasSnoozeEligibleAlert: hasSnoozeEligibleAlert)
        WidgetStore.save(snap)
        // Same choke point drives the opt-in app-icon badge. The opt-in gate + freshness live
        // inside GlucoseBadge (currently an inert stub). The arbiter timer re-runs
        // refresh()->publish every ~20s for EVERY config, so a pump-only user's badge would still
        // age past stale even with no new pump data.
        GlucoseBadge.apply(snap)
        // Keep the Quick-Bolus widget's amount picker in sync with the pump's max + the increment.
        if s.maxBolusUnits > 0 { WidgetBolusStore.maxBolus = s.maxBolusUnits }
        WidgetBolusStore.increment = AppSettings.shared.bolusIncrement
        // Mirror the bolus-lock decision so the widget greys/disables its pad. Written inline here
        // (the caller passes the evaluator's result) — the throttled reload below covers it.
        WidgetBolusStore.bolusLocked = bolusLocked
        WidgetBolusStore.bolusLockReason = bolusLocked ? bolusLockReason : ""

        scheduleReload()
    }

    /// Reload now if outside the 30 s coalesce window; otherwise ensure exactly ONE trailing reload
    /// fires when the window elapses. Dropping a throttled reload with no reschedule would leave the
    /// LAST snapshot in a burst (e.g. the one that finally crosses stale) unrefreshed until the next
    /// unthrottled publish.
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

    /// Mirror ONLY the Quick-Bolus lock state (no pump snapshot needed) and reload the widget now,
    /// so a read-only / child-mode toggle greys the pad immediately rather than at the next pump update.
    /// The decision is the app's single AccessPolicy evaluator's — see `AppModel.publishWidgetLockState()`.
    @MainActor
    static func publishBolusLock(locked: Bool, reason: String) {
        WidgetBolusStore.bolusLocked = locked
        WidgetBolusStore.bolusLockReason = locked ? reason : ""
        WidgetCenter.shared.reloadTimelines(ofKind: "FaBolusQuickBolus")
    }

    /// Re-stamp `displayUnit` on the most recently published snapshot and reload the widget timelines
    /// immediately — like `publishBolusLock`, this needs no `PumpSnapshot` (the setting toggle isn't a
    /// pump event), so it patches the App-Group value already on disk rather than waiting for the next
    /// `publish(_:)` from a pump update. Called from `AppSettings.glucoseDisplayUnit`'s `didSet`. Uses
    /// the SAME WidgetSnapshot vehicle every glucose render already reads — never `syncWidgetConfig()`,
    /// which is the unrelated bolus-increment channel. A no-op if nothing has been published yet.
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
