import Foundation
import faBolusCore
#if FABOLUS_NUDGE
import TherapyInsightsKit
#endif

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

// App-local, kit-free mirrors of the therapy-advice results so views (DataHistoryView) never reference
// faBolusNudge types — the Smart Assist features can then compile out when the SDK is unavailable.
public struct TherapyInsightItem: Identifiable, Equatable { public let id = UUID(); public let title: String; public let detail: String }

#if FABOLUS_NUDGE
/// faBolus's app-side glue for the retrospective TherapyInsightsKit reporting (PatternInsights).
/// Advisory display only — never blocks or changes a dose; the algorithm lives in the reusable SDK.
/// See MIGRATION.md (Phase 4).
enum SmartAssist {
    // MARK: Retrospective insights (TherapyInsightsKit)

    static func insights(cgm: [GlucoseReading], carbs: [(date: Date, grams: Double)] = []) -> [PatternInsights.Insight] {
        PatternInsights().insights(
            cgm: cgm.map { TherapyInsightsKit.CGMPoint(mgdl: Double($0.mgdl), date: $0.date) },
            carbs: carbs.map { TherapyInsightsKit.Carbs(grams: $0.grams, date: $0.date) })
    }
}
#endif
