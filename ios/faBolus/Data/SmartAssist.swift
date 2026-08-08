import Foundation
import faBolusCore
#if FABOLUS_NUDGE
import DosingSafetyKit
import GlucoseIntelligenceKit
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

/// A Sendable, faBolus-local view of a predictive-low warning (so it can cross actor isolation and drive
/// the UI without coupling stored state to the SDK's type).
struct HypoAlert: Sendable, Equatable {
    let horizonMinutes: Int
    let probability: Double
    let projectedLowMgdl: Double?
    let at: Date
    let nocturnal: Bool
    var message: String {
        if let low = projectedLowMgdl {
            return "Low likely within ~\(horizonMinutes) min (projected ~\(Int(low)) mg/dL)."
        }
        return "Low likely within ~\(horizonMinutes) min."
    }
}

// App-local, kit-free mirrors of the therapy-advice results so views (DataHistoryView) never reference
// faBolusNudge types — the Smart Assist features can then compile out when the SDK is unavailable.
public struct TherapyInsightItem: Identifiable, Equatable { public let id = UUID(); public let title: String; public let detail: String }

#if FABOLUS_NUDGE
/// Bridges faBolus data to the DosingSafetyKit guardrail (advisory only). Given the bolus the user is
/// about to give + recent history + the pump's ISF/CR, it returns warnings (predicted low, insulin
/// stacking, oversized correction, …). Empty = looks fine. It NEVER blocks a dose — the app decides how
/// to surface these. See MIGRATION.md (Phase 4). This is faBolus's app-side glue; the algorithm lives in
/// the reusable SDK.
enum SmartAssist {
    static func warnings(units: Double, carbs: Double, recommendedUnits: Double?,
                         snapshot: PumpSnapshot, glucoseHistory: [GlucoseReading],
                         bolusMarkers: [BolusMarker]) -> [SafetyWarning] {
        guard let bg = snapshot.glucose, snapshot.isf > 0, snapshot.carbRatio > 0 else { return [] }
        let personalizer = LocalDosingPersonalizer(seedISF: Double(snapshot.isf),
                                                   seedCarbRatio: snapshot.carbRatio)
        let safety = DosingSafety(personalizer: personalizer)
        let proposal = BolusProposal(units: units, carbsGrams: carbs,
                                     currentGlucose: Double(bg), recommendedUnits: recommendedUnits)
        // Disambiguate: DosingSafetyKit has its own GlucoseSample/InsulinDose (≠ faBolusCore's).
        let doses = bolusMarkers.map {
            DosingSafetyKit.InsulinDose(units: $0.units, date: $0.date, isBolus: true)
        }
        let cgm = glucoseHistory.map {
            DosingSafetyKit.GlucoseSample(mgdl: Double($0.mgdl), date: $0.date)
        }
        return safety.evaluateBolus(proposal, recentDoses: doses, recentGlucose: cgm)
    }

    // MARK: Predictive-low (GlucoseIntelligenceKit)

    /// A stateful hypo engine (heuristic — no model file needed). Feed new readings via `ingest`.
    static func makeHypoEngine() -> GlucoseIntelligence {
        GlucoseIntelligence(predictor: HeuristicHypoPredictor(lowThreshold: 70, horizonSteps: 6))
    }

    // MARK: Retrospective insights (TherapyInsightsKit)

    static func insights(cgm: [GlucoseReading], carbs: [(date: Date, grams: Double)] = []) -> [PatternInsights.Insight] {
        PatternInsights().insights(
            cgm: cgm.map { TherapyInsightsKit.CGMPoint(mgdl: Double($0.mgdl), date: $0.date) },
            carbs: carbs.map { TherapyInsightsKit.Carbs(grams: $0.grams, date: $0.date) })
    }
}
#endif
