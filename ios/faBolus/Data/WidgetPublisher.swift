import Foundation
import WidgetKit

/// Publishes the current pump state to the App Group so the Lock/Home Screen widgets can render
/// it, and asks WidgetKit to refresh their timelines. Called on every snapshot update.
enum WidgetPublisher {
    /// Throttle timeline reloads — WidgetKit budgets refreshes, and the pump updates ~every 60 s.
    @MainActor private static var lastReload = Date.distantPast

    @MainActor
    static func publish(_ s: PumpSnapshot, history: [GlucoseReading], alerts: [String] = []) {
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

        // Coalesce reloads to at most once every 30 s.
        if Date().timeIntervalSince(lastReload) > 30 {
            lastReload = Date()
            WidgetCenter.shared.reloadAllTimelines()
        }
    }
}
