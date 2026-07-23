import Foundation
import faBolusCore
import DosingSafetyKit
import GlucoseIntelligenceKit
import TherapyInsightsKit

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

    /// Sensor-trust (compression-low / noise) assessment over recent CGM.
    static func sensorTrust(recent: [GlucoseReading]) -> GlucoseIntelligenceKit.SensorTrust {
        SensorTrustAssessor().assess(recent: recent.map {
            GlucoseIntelligenceKit.CGMReading(mgdl: Double($0.mgdl), date: $0.date)
        })
    }

    // MARK: Retrospective insights (TherapyInsightsKit)

    static func insights(cgm: [GlucoseReading]) -> [PatternInsights.Insight] {
        PatternInsights().insights(cgm: cgm.map {
            TherapyInsightsKit.CGMPoint(mgdl: Double($0.mgdl), date: $0.date)
        })
    }
}
