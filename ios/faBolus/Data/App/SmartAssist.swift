import Foundation
import faBolusCore

// App-local, kit-free mirrors of the therapy-advice results so views never reference faBolusNudge
// types — the Smart Assist features can then compile out when the SDK is unavailable. (No UI surface
// consumes this today.)
public struct TherapyInsightItem: Identifiable, Equatable {
    public let id = UUID()
    public let title: String
    public let detail: String
}

/// faBolus's app-side glue for the retrospective `PatternInsights` reporting (now vendored in
/// faBolusCore, so it builds in every configuration — no private SDK required). Advisory display only —
/// never blocks or changes a dose; the algorithm lives in the reusable core package.
enum SmartAssist {
    // MARK: Retrospective insights (PatternInsights, faBolusCore)

    /// - Parameter unit: the ACTIVE DISPLAY unit for the generated "Insights" prose.
    ///   `SmartAssist` — not `PatternInsights` (which stays app-independent) — is the funnel
    ///   boundary: the caller (`AppModel.therapyInsights()`) passes `AppSettings.shared.glucoseDisplayUnit`
    ///   explicitly rather than defaulting here, so the call site is grep-visible as funnel-routed.
    static func insights(cgm: [GlucoseReading], carbs: [(date: Date, grams: Double)] = [], unit: GlucoseUnit)
        -> [PatternInsights.Insight]
    {
        PatternInsights().insights(
            cgm: cgm.map { PatternInsights.CGMPoint(mgdl: Double($0.mgdl), date: $0.date) },
            carbs: carbs.map { PatternInsights.Carbs(grams: $0.grams, date: $0.date) },
            unit: unit)
    }
}
