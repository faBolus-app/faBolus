import Testing
import Foundation
@testable import faBolusCore

/// P15 Addendum B (AB1): the shared stale-CGM bolus decision. Pins the warn predicate, the three-way
/// choice → calculator-input mapping, and that `cancel` alone does not proceed — the contract every
/// surface (iPhone / Watch / Garmin / Mac) will consume so the behavior and safety framing are identical.
struct StaleBolusPromptTests {

    /// Warn only for a reading that EXISTS and is stale at compose time. Dates are chosen far from any
    /// plausible `staleAfter` (10 s vs 24 h) so the test does not depend on — or mutate — the global
    /// `GlucoseFreshness.staleAfter` (avoids cross-suite flakiness). Future-skew is a fixed constant.
    @Test func shouldWarnOnlyForAnExistingStaleReading() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let fresh = now.addingTimeInterval(-10)             // 10 s old — fresh for any staleAfter ≥ 10 s
        let stale = now.addingTimeInterval(-24 * 3600)      // 24 h old — stale for any staleAfter < 24 h
        let future = now.addingTimeInterval(60 * 60)        // 1 h ahead — beyond the 5-min future skew

        #expect(!StaleBolusPrompt.shouldWarn(glucoseMgdl: 120, glucoseDate: fresh, now: now))
        #expect(StaleBolusPrompt.shouldWarn(glucoseMgdl: 120, glucoseDate: stale, now: now))
        #expect(StaleBolusPrompt.shouldWarn(glucoseMgdl: 120, glucoseDate: future, now: now))
        // No reading value ⇒ nothing to include ⇒ no warning (it is simply a carbs-only bolus).
        #expect(!StaleBolusPrompt.shouldWarn(glucoseMgdl: nil, glucoseDate: stale, now: now))
    }

    @Test func choiceMapsToCalculatorInput() {
        #expect(StaleBolusPrompt.bgForCalculation(.includeStale, staleGlucoseMgdl: 200) == 200)
        #expect(StaleBolusPrompt.bgForCalculation(.proceedWithout, staleGlucoseMgdl: 200) == nil)
        #expect(StaleBolusPrompt.bgForCalculation(.cancel, staleGlucoseMgdl: 200) == nil)
    }

    @Test func onlyCancelDoesNotProceed() {
        #expect(StaleBolusPrompt.proceeds(.includeStale))
        #expect(StaleBolusPrompt.proceeds(.proceedWithout))
        #expect(!StaleBolusPrompt.proceeds(.cancel))
    }

    /// End-to-end with the real calculator: a high stale BG makes `includeStale` recommend MORE than
    /// `proceedWithout` (carbs-only) — i.e. the choice genuinely governs the dose, and the "include" path
    /// adds a positive correction rather than being cosmetic.
    @Test func includeStaleAddsACorrectionVsProceedWithout() {
        let profile = BolusMath.Profile(carbRatioGramsPerUnit: 10, isfMgdlPerUnit: 40, targetBgMgdl: 110, iobUnits: 0)
        let carbs = 30.0, staleBG = 230
        let included = BolusMath.recommendedUnits(
            carbsGrams: carbs,
            bgMgdl: StaleBolusPrompt.bgForCalculation(.includeStale, staleGlucoseMgdl: staleBG),
            profile: profile)
        let without = BolusMath.recommendedUnits(
            carbsGrams: carbs,
            bgMgdl: StaleBolusPrompt.bgForCalculation(.proceedWithout, staleGlucoseMgdl: staleBG),
            profile: profile)
        #expect(included > without)                 // (230-110)/40 = +3 U correction is added
        #expect(without == 3.0)                      // carbs-only: 30 g / 10 g·U⁻¹
    }
}
