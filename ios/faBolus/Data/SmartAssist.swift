import Foundation
import faBolusCore
import DosingSafetyKit

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
}
