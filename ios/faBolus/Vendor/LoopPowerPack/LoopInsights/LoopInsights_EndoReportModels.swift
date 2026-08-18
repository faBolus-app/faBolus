// Ported from LoopPowerPack/Loop @ ad4c4d498f936a25e22dd3a8dc93354138458509 (MIT)
//
//  LoopInsights_EndoReportModels.swift
//  Loop (AID) PowerPack — based on LoopKit/Loop.
//
//  LoopInsights — the benign, Foundation-only report DTO shapes the endo-visit PDF needs.
//
//  Concept & design by Taylor Patterson. Coded by Claude Code.
//  Copyright © 2026 LoopKit Authors and Taylor Patterson.
//

import Foundation

// D-04 / D-14 (binding): LoopInsights is NEVER vendored as a whole dir. This file cherry-picks ONLY
// the benign, Foundation-only report DTO shapes the endo report reads — the analysis-period enum and
// the reduced aggregated-stats struct — from the mirror's `LoopInsights_Models.swift`
// (`LoopInsightsAnalysisPeriod` + `LoopInsightsAggregatedStats`). Everything AI / advisor / Phase5 /
// biometric / LoopKit-typed in that upstream file is stripped: NO `apiKey` / provider config, NO
// suggestion / pattern / chat / guardrail types, NO `BiometricStats` / `hourlyAverages` maps, NO
// `negativeBasalStats`, NO `LoopKit` / `HealthKit` import. The file is deliberately named
// `LoopInsights_EndoReportModels.swift` — NOT `LoopInsights_Models.swift`, which is on the 09.18a
// `LoopInsightsExclusionGuardTests` denylist (benign structs are re-created, not bulk-vendored).

// MARK: - Analysis Period

/// How far back the endo report aggregates. Cherry-picked from the mirror `LoopInsightsAnalysisPeriod`
/// (Foundation-only, benign). Maps to `FaBolusInsightsReport.Period.days(_:)` at the aggregator seam.
enum LoopInsightsReportPeriod: Int, CaseIterable, Identifiable {
    case sevenDays = 7
    case fourteenDays = 14
    case thirtyDays = 30
    case ninetyDays = 90

    var id: Int { rawValue }
    var days: Int { rawValue }

    var displayName: String {
        switch self {
        case .sevenDays:    return "7 Days"
        case .fourteenDays: return "14 Days"
        case .thirtyDays:   return "30 Days"
        case .ninetyDays:   return "90 Days"
        }
    }
}

// MARK: - Aggregated Report Stats (reduced, benign)

/// The reduced aggregated-stats shape the endo report renders — cherry-picked from the mirror's
/// `LoopInsightsAggregatedStats` GlucoseStats / InsulinStats / CarbStats, keeping ONLY the benign
/// summary scalars. All AI-feeding fields (`hourlyAverages`, `biometricStats`, `negativeBasalStats`,
/// `tddWeekOverWeekChange`, tight-range/percentile internals) are stripped (D-14). Populated by the
/// app-side adapter from a faBolus `FaBolusInsightsReport`; the report path is summary-only (§13).
struct LoopInsightsReportStats {

    struct GlucoseStats {
        let averageGlucose: Double         // mg/dL (canonical)
        let standardDeviation: Double      // mg/dL
        let coefficientOfVariation: Double // %
        let timeInRange: Double            // % (70–180)
        let gmi: Double                    // % (est. A1C)
        let sampleCount: Int
    }

    struct InsulinStats {
        let totalDailyDose: Double         // average units/day (bolus rollup in faBolus)
        let totalUnits: Double             // total units delivered in the window
    }

    struct CarbStats {
        let averageDailyCarbs: Double      // grams/day
        let averageCarbsPerMeal: Double    // grams/meal
        let mealCount: Int
    }

    let glucose: GlucoseStats
    let insulin: InsulinStats
    let carbs: CarbStats
}
