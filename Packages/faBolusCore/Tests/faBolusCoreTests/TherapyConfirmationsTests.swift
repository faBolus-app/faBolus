import Testing
@testable import faBolusCore

/// P14 S10 (§2.1(5)): the TDD-relative max-bolus-limit CONFIRM tier — warns, never blocks, and is
/// strictly separate from the absolute 25 U HARD cap (`Interlocks.clampMaxBolusLimit`).
struct TherapyConfirmationsTests {

    @Test func noConfirmWhenTddUnknown() {
        // No TDD ⇒ no relative bound can be computed ⇒ never a confirm (the hard cap still applies).
        #expect(TherapyConfirmations.maxBolusLimitConfirm(proposedUnits: 25, totalDailyInsulinUnits: 0) == nil)
    }

    @Test func confirmsOnlyStrictlyAboveTheTddFraction() {
        // TDD 40 ⇒ threshold 20 U. At the threshold → no confirm; strictly above → confirm.
        #expect(TherapyConfirmations.maxBolusLimitConfirm(proposedUnits: 20, totalDailyInsulinUnits: 40) == nil)
        #expect(TherapyConfirmations.maxBolusLimitConfirm(proposedUnits: 20.5, totalDailyInsulinUnits: 40) != nil)
    }

    @Test func neverFiresWhenTheCeilingIsSmallRelativeToTdd() {
        // TDD 60 ⇒ threshold 30 U, above the 25 U hard cap — so nothing reachable in the editor confirms.
        #expect(
            TherapyConfirmations.maxBolusLimitConfirm(
                proposedUnits: Interlocks.absoluteMaxUnits,
                totalDailyInsulinUnits: 60) == nil)
    }

    @Test func confirmIsAdviceNotAClamp() {
        // It returns a message for a large-but-legal edit and names the user's OWN TDD; it does not bound
        // the value. The 25 U hard cap is enforced separately by `Interlocks`, unaffected by this.
        let msg = TherapyConfirmations.maxBolusLimitConfirm(proposedUnits: 24, totalDailyInsulinUnits: 20)
        #expect(msg != nil)
        #expect(msg?.contains("20 U") == true)  // names the user's own TDD
        // The proposed amount renders correctly ONCE — `formatUnits` already carries " U" (guards against
        // a doubled "U U" suffix in this user-facing safety dialog).
        #expect(msg?.contains("24.0 U ") == true)
        #expect(msg?.contains("U U") == false)
        // The clamp tier is independent and still hard-caps at 25 regardless of any confirmation.
        #expect(Interlocks.clampMaxBolusLimit(1000) == Interlocks.absoluteMaxUnits)
    }

    // MARK: - B1(d) §2.1(5): per-segment therapy-value advisories vs the TDD rules of thumb

    @Test func tddAdvisoriesAreSilentWhenTddUnknown() {
        // TDD 0 ⇒ unknown ⇒ never an advisory (the whole layer needs a configured Control-IQ TDD).
        #expect(TherapyConfirmations.isfTddAdvisory(isfMgdlPerUnit: 5, totalDailyInsulinUnits: 0) == nil)
        #expect(TherapyConfirmations.carbRatioTddAdvisory(carbRatioGramsPerUnit: 3, totalDailyInsulinUnits: 0) == nil)
        #expect(TherapyConfirmations.basalTddAdvisory(basalUnitsPerHour: 9, totalDailyInsulinUnits: 0) == nil)
    }

    @Test func isf1800RuleFiresOnlyWhenFarFromExpected() {
        // TDD 45 ⇒ 1800/45 = 40 mg/dL/U; band 3× ⇒ silent within [13.3, 120].
        #expect(TherapyConfirmations.isfTddAdvisory(isfMgdlPerUnit: 40, totalDailyInsulinUnits: 45) == nil)  // on the rule
        #expect(TherapyConfirmations.isfTddAdvisory(isfMgdlPerUnit: 90, totalDailyInsulinUnits: 45) == nil)  // 2.25× — within band
        let far = TherapyConfirmations.isfTddAdvisory(isfMgdlPerUnit: 130, totalDailyInsulinUnits: 45)  // >3× ⇒ advisory
        #expect(far != nil)
        #expect(far?.contains("1800 rule") == true)
        #expect(far?.contains("45 U") == true)  // names the user's own TDD
        #expect(TherapyConfirmations.isfTddAdvisory(isfMgdlPerUnit: 12, totalDailyInsulinUnits: 45) != nil)  // <1/3× ⇒ advisory (typo-catch)
    }

    @Test func carbRatio500RuleFiresOnlyWhenFarFromExpected() {
        // TDD 50 ⇒ 500/50 = 10 g/U; band 3× ⇒ silent within [3.33, 30].
        #expect(TherapyConfirmations.carbRatioTddAdvisory(carbRatioGramsPerUnit: 10, totalDailyInsulinUnits: 50) == nil)
        #expect(TherapyConfirmations.carbRatioTddAdvisory(carbRatioGramsPerUnit: 25, totalDailyInsulinUnits: 50) == nil)  // within band
        let far = TherapyConfirmations.carbRatioTddAdvisory(carbRatioGramsPerUnit: 40, totalDailyInsulinUnits: 50)
        #expect(far != nil)
        #expect(far?.contains("500 rule") == true)
    }

    @Test func basalHalfTddRuleFiresOnlyWhenFarFromExpected() {
        // TDD 48 ⇒ 0.5·48/24 = 1.0 U/hr average; band 3× ⇒ silent within [0.33, 3.0] (segments vary).
        #expect(TherapyConfirmations.basalTddAdvisory(basalUnitsPerHour: 1.0, totalDailyInsulinUnits: 48) == nil)
        #expect(TherapyConfirmations.basalTddAdvisory(basalUnitsPerHour: 2.5, totalDailyInsulinUnits: 48) == nil)  // 2.5× — a legit dawn segment
        #expect(TherapyConfirmations.basalTddAdvisory(basalUnitsPerHour: 5.0, totalDailyInsulinUnits: 48) != nil)  // >3× ⇒ advisory
    }

    @Test func tddAdvisoriesNeverFireForAZeroValue() {
        // A zero/blank entry isn't a "far from rule" case — it's incomplete; don't nag (guarded in isFarFromRule).
        #expect(TherapyConfirmations.isfTddAdvisory(isfMgdlPerUnit: 0, totalDailyInsulinUnits: 45) == nil)
        #expect(TherapyConfirmations.carbRatioTddAdvisory(carbRatioGramsPerUnit: 0, totalDailyInsulinUnits: 50) == nil)
        #expect(TherapyConfirmations.basalTddAdvisory(basalUnitsPerHour: 0, totalDailyInsulinUnits: 48) == nil)
    }

    // MARK: - 04-08 gap closure (SC1): isfTddAdvisory's mg/dL literal must convert via a GlucoseUnit param
    // (no AppSettings in faBolusCore); the no-arg default must stay byte-identical to before this plan.

    @Test func isfAdvisoryDefaultUnitTextIsUnchanged() {
        // No `unit:` argument — the pre-existing mg/dL wording must be byte-identical.
        let far = TherapyConfirmations.isfTddAdvisory(isfMgdlPerUnit: 130, totalDailyInsulinUnits: 45)
        #expect(far?.contains("mg/dL per unit") == true)
        #expect(far?.contains("130 mg/dL per unit") == true)
    }

    @Test func isfAdvisoryMmolUnitConvertsBothFigures() {
        // TDD 45 ⇒ expected 40 mg/dL/U ⇒ 2.2 mmol/L/U; entered 130 mg/dL/U ⇒ 7.2 mmol/L/U. Neither the
        // "typical" nor the "entered" figure may leak a bare mg/dL number in mmol mode.
        let far = TherapyConfirmations.isfTddAdvisory(isfMgdlPerUnit: 130, totalDailyInsulinUnits: 45, unit: .mmol)
        #expect(far != nil)
        #expect(far?.contains("mg/dL") == false, "mmol mode must never leak an mg/dL label")
        #expect(far?.contains("mmol/L per unit") == true)
        #expect(far?.contains("2.2 mmol/L per unit") == true)  // 1800/45 = 40 mg/dL → 2.2 mmol/L
        #expect(far?.contains("7.2 mmol/L per unit") == true)  // 130 mg/dL → 7.2 mmol/L
    }
}
