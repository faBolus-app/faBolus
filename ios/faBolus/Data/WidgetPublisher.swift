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
    static func makeSnapshot(_ s: PumpSnapshot, history: [GlucoseReading], alerts: [String],
                             staleAfterSec: TimeInterval, hideAfterSec: TimeInterval?) -> WidgetSnapshot {
        let points = history.suffix(48).map { WidgetSnapshot.Point(t: $0.date, mgdl: $0.mgdl) }
        return WidgetSnapshot(
            glucose: s.glucose,
            glucoseDate: s.glucoseDate,
            trendArrow: s.trend,          // Unicode arrow, same as the HUD
            iobUnits: s.iobUnits,
            reservoirUnits: s.reservoirUnits,
            batteryPercent: s.batteryPercent,
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
            staleAfterSec: staleAfterSec, hideAfterSec: hideAfterSec)
    }

    @MainActor
    static func publish(_ s: PumpSnapshot, history: [GlucoseReading], alerts: [String] = [],
                        bolusLocked: Bool = false, bolusLockReason: String = "") {
        let snap = makeSnapshot(s, history: history, alerts: alerts,
                                staleAfterSec: GlucoseFreshness.staleAfter, hideAfterSec: GlucoseFreshness.hideAfter)
        WidgetStore.save(snap)
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
}
