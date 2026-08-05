import Foundation
import faBolusCore
import WidgetKit

/// Publishes the current pump state to the App Group so the Lock/Home Screen widgets can render
/// it, and asks WidgetKit to refresh their timelines. Called on every snapshot update.
enum WidgetPublisher {
    /// Throttle timeline reloads — WidgetKit budgets refreshes, and the pump updates ~every 60 s.
    @MainActor private static var lastReload = Date.distantPast

    @MainActor
    static func publish(_ s: PumpSnapshot, history: [GlucoseReading], alerts: [String] = [],
                        bolusLocked: Bool = false, bolusLockReason: String = "") {
        let points = history.suffix(48).map { WidgetSnapshot.Point(t: $0.date, mgdl: $0.mgdl) }
        let snap = WidgetSnapshot(
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
            maxBolusUnits: s.maxBolusUnits)
        WidgetStore.save(snap)
        // Keep the Quick-Bolus widget's amount picker in sync with the pump's max + the increment.
        if s.maxBolusUnits > 0 { WidgetBolusStore.maxBolus = s.maxBolusUnits }
        WidgetBolusStore.increment = AppSettings.shared.bolusIncrement
        // A-05: mirror the bolus-lock decision so the widget greys/disables its pad. Written inline here
        // (the caller passes the evaluator's result) — the throttled reload below covers it.
        WidgetBolusStore.bolusLocked = bolusLocked
        WidgetBolusStore.bolusLockReason = bolusLocked ? bolusLockReason : ""

        // Coalesce reloads to at most once every 30 s.
        if Date().timeIntervalSince(lastReload) > 30 {
            lastReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
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
