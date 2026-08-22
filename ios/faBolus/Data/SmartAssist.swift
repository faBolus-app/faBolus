import Foundation
import faBolusCore

/// An advisory eating-nudge shown in the UI (from the multi-signal EatingTriggerEngine).
struct EatingAlert: Sendable, Equatable {
    let estimatedCarbs: Double     // 0 if only the accel signal fired (no carb estimate)
    let at: Date
    var message: String {
        estimatedCarbs > 0
            ? "Looks like you're eating (~\(Int(estimatedCarbs))g). Bolus?"
            : "Looks like you might be eating. Bolus?"
    }
}

// App-local, kit-free mirrors of the therapy-advice results so views (originally `DataHistoryView`,
// since deleted; no current UI surface consumes this) never reference faBolusNudge types — the Smart
// Assist features can then compile out when the SDK is unavailable.
public struct TherapyInsightItem: Identifiable, Equatable { public let id = UUID(); public let title: String; public let detail: String }

/// faBolus's app-side glue for the retrospective `PatternInsights` reporting (now vendored in
/// faBolusCore, so it builds in every configuration — no private SDK required). Advisory display only —
/// never blocks or changes a dose; the algorithm lives in the reusable core package. See MIGRATION.md.
enum SmartAssist {
    // MARK: Retrospective insights (PatternInsights, faBolusCore)

    /// - Parameter unit: the ACTIVE DISPLAY unit for the generated "Insights" prose (04-08 gap closure,
    ///   SC1). `SmartAssist` — not `PatternInsights` (which stays app-independent) — is the funnel
    ///   boundary: the caller (`AppModel.therapyInsights()`) passes `AppSettings.shared.glucoseDisplayUnit`
    ///   explicitly rather than defaulting here, so the call site is grep-visible as funnel-routed.
    static func insights(cgm: [GlucoseReading], carbs: [(date: Date, grams: Double)] = [], unit: GlucoseUnit) -> [PatternInsights.Insight] {
        PatternInsights().insights(
            cgm: cgm.map { PatternInsights.CGMPoint(mgdl: Double($0.mgdl), date: $0.date) },
            carbs: carbs.map { PatternInsights.Carbs(grams: $0.grams, date: $0.date) },
            unit: unit)
    }
}
