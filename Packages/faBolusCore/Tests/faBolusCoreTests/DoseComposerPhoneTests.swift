import Foundation
import Testing

@testable import faBolusCore

/// One test per phone-dose check, each from `DoseComposer.composePhone`.
@Suite struct DoseComposerPhoneTests {
    typealias F = DoseFixtures
    typealias Answers = PhoneDoseAnswers

    private func compose(_ entry: PhoneDoseEntry, context: DoseContext = F.context()) -> PhoneDoseDecision {
        DoseComposer.composePhoneCorrecting(entry, context: context)
    }

    private func compose(
        _ amount: PhoneDoseEntry.Amount, answers: Answers = .init(), context: DoseContext = F.context()
    ) -> PhoneDoseDecision {
        compose(F.phone(amount, answers: answers), context: context)
    }

    /// The pump's IOB, read before this attempt began.
    private func iobReadEarlier(_ pump: inout PumpState) {
        let before = F.requestedAt.addingTimeInterval(-1)
        pump.insulinOnBoard = Observed(0.5, measuredAt: before, receivedAt: before)
    }

    private func settingsReadEarlier(_ pump: inout PumpState) {
        let before = F.requestedAt.addingTimeInterval(-1)
        pump.bolusCalculator = Observed(F.settings, measuredAt: before, receivedAt: before)
        pump.cgm = pump.glucose
    }

    // MARK: - Units and limits

    @Test func unitsAreDeliveredAsEntered() throws {
        let dose = try #require(compose(.units(2.37)).dose)
        #expect(dose.units == 2.37)
        #expect(dose.request.origin == .phone)
        #expect(dose.request.carbsGrams == nil)
        #expect(dose.calculatorIOBUnits == nil)
    }

    @Test func phoneReadOnlyRefuses() {
        var access = F.openAccess
        access.phoneReadOnly = true
        #expect(
            compose(.units(1), context: F.context(access: access)).refusal
                == .unavailable(.accessDenied(.phoneReadOnly)))
    }

    /// The remote size limit is for remotes only.
    @Test func remoteLimitDoesNotApplyToThePhone() {
        #expect(compose(.units(2), context: F.context(remoteSizeLimitUnits: 1)).dose?.units == 2)
    }

    @Test func aboveThePumpsKnownMaxIsRefused() {
        #expect(compose(.units(25.05)).refusal == .unavailable(.aboveMax(25)))
    }

    @Test func maxUnknownGoesToThePump() {
        var pump = F.pump()
        pump.bolusCalculator = nil
        #expect(compose(.units(40), context: F.context(pump: pump)).dose?.units == 40)
    }

    /// A calculator entry of zero is refused before any prompt can turn it into a dose.
    @Test func zeroEnteredIsRefusedBeforeAnyPrompt() {
        let context = F.context(pump: F.pump(glucose: 180, glucoseAge: 10 * 60))
        #expect(compose(F.cgmDose(entered: 0), context: context).refusal == .nothingToDeliver)
        #expect(
            compose(F.cgmDose(entered: 0), answers: Answers(staleGlucose: .carbsOnly(units: 6)), context: context)
                .refusal == .nothingToDeliver)
    }

    @Test func belowThePumpsMinimumIsRefused() {
        #expect(compose(.units(0.04)).refusal == .unavailable(.belowMinimum(0.05)))
        #expect(compose(.units(0)).refusal == .nothingToDeliver)
    }

    @Test func pumpAndLedgerAreCheckedBeforeAnyPrompt() {
        var pump = F.pump()
        iobReadEarlier(&pump)
        #expect(
            compose(F.cgmDose(), context: F.context(pump: pump, bolusBlock: .outcomeNotSaved)).refusal
                == .blocked(.outcomeNotSaved))
        pump.link = .disconnected
        #expect(compose(F.cgmDose(), context: F.context(pump: pump)).refusal == .unavailable(.pumpNotLinked))
        pump = F.pump()
        pump.cartridge = F.observed(CartridgeLoadState(rawValue: 2), age: 1)
        #expect(compose(F.cgmDose(), context: F.context(pump: pump)).refusal == .unavailable(.noCartridge))
    }

    @Test func cartridgeUnknownDeliversWithANotice() {
        var pump = F.pump()
        pump.cartridge = nil
        #expect(
            compose(.units(1), context: F.context(pump: pump)).dose?.notices.contains(.cartridgeStateUnknown) == true)
    }

    // MARK: - Calculator-input gate

    @Test func verifiedInputsDeliverTheEnteredDose() throws {
        let dose = try #require(compose(F.cgmDose()).dose)
        #expect(dose.units == 7.25)
        #expect(dose.request.carbsGrams == 60)
        #expect(dose.request.bgMgdl == 180)
        #expect(dose.calculatorIOBUnits == 0.5)
    }

    @Test func inputsNotReadForThisAttemptPromptByKind() {
        var pump = F.pump()
        iobReadEarlier(&pump)
        #expect(compose(F.cgmDose(), context: F.context(pump: pump)).prompt?.kind == .iob)
        pump = F.pump()
        settingsReadEarlier(&pump)
        #expect(compose(F.cgmDose(), context: F.context(pump: pump)).prompt?.kind == .therapy)
        iobReadEarlier(&pump)
        let prompt = compose(F.cgmDose(), context: F.context(pump: pump)).prompt
        #expect(prompt?.kind == .both)
        // The prompt shows the dose from the last-known inputs and the current reading.
        #expect(prompt?.calculatorUnits == 7.25)
    }

    /// An accepted override never delivers more than its prompt showed or than a recompute now gives.
    @Test func acceptedOverrideDeliversTheEnteredDose() throws {
        var pump = F.pump()
        iobReadEarlier(&pump)
        let context = F.context(pump: pump)
        // The user lowered the suggested 7.25 U to 3 U: the prompt asks about 3 U, and 3 U is delivered.
        let lowered = PhoneDoseEntry.Amount.calculator(
            carbsGrams: 60, glucose: .typed(mgdl: 180), recommendedUnits: 7.25, enteredUnits: 3)
        #expect(compose(lowered, context: context).prompt?.calculatorUnits == 3)
        let accepted = Answers(calculatorOverride: .init(kind: .iob, units: 3))
        #expect(compose(lowered, answers: accepted, context: context).dose?.units == 3)
    }

    /// An override names the dose it was given for, so a dose changed after the prompt is asked about again.
    @Test func overrideForADifferentDoseAsksAgain() {
        var pump = F.pump()
        iobReadEarlier(&pump)
        let answers = Answers(calculatorOverride: .init(kind: .iob, units: 7.25))
        #expect(compose(F.cgmDose(entered: 8), answers: answers, context: F.context(pump: pump)).prompt?.kind == .iob)
    }

    /// An accepted override still goes through the glucose checks: the new reading's dose is asked about.
    @Test func overrideStillChecksTheReading() {
        var pump = F.pump(glucose: 220)
        iobReadEarlier(&pump)
        let answers = Answers(calculatorOverride: .init(kind: .iob, units: 7.25))
        #expect(
            DoseComposer.composePhone(F.phone(F.cgmDose(), answers: answers), context: F.context(pump: pump)).prompt
                == .correction(mgdl: 220, targetMgdl: 110, applyUnits: 8.25, declineUnits: 6))
    }

    /// The two IOB readings disagreeing makes IOB unverified, which is asked about like a late read.
    @Test func disagreeingIOBReadingsPrompt() {
        var pump = F.pump()
        pump.bolusCalculator = F.observed(
            F.settings(target: 110, reportedIOB: 1.5),
            age: 2)
        pump.cgm = pump.glucose
        #expect(compose(F.cgmDose(), context: F.context(pump: pump)).prompt?.kind == .iob)
    }

    /// An override accepted for one input doesn't cover the other once it too is unverified.
    @Test func overrideThatNoLongerCoversAsksAgain() {
        var pump = F.pump()
        iobReadEarlier(&pump)
        settingsReadEarlier(&pump)
        let answers = Answers(calculatorOverride: .init(kind: .iob, units: 7.25))
        #expect(compose(F.cgmDose(), answers: answers, context: F.context(pump: pump)).prompt?.kind == .both)
        let both = Answers(calculatorOverride: .init(kind: .both, units: 7.25))
        #expect(compose(F.cgmDose(), answers: both, context: F.context(pump: pump)).dose?.units == 7.25)
    }

    @Test func inputsNeverReadAreRefused() {
        var pump = F.pump()
        pump.bolusCalculator = nil
        #expect(compose(F.cgmDose(), context: F.context(pump: pump)).refusal == .pumpSettingsNotRead)
        pump = F.pump()
        pump.insulinOnBoard = nil
        #expect(compose(F.cgmDose(), context: F.context(pump: pump)).refusal == .pumpSettingsNotRead)
    }

    /// When the two IOB readings disagree the dose subtracts the larger, and carries that IOB to the pump.
    @Test func disagreeingIOBIsCarriedAsUsed() throws {
        var pump = F.pump()
        pump.bolusCalculator = F.observed(
            F.settings(target: 110, reportedIOB: 1.5),
            age: 2)
        pump.cgm = pump.glucose
        let amount = PhoneDoseEntry.Amount.calculator(
            carbsGrams: 60, glucose: .typed(mgdl: 180), recommendedUnits: 6.25, enteredUnits: 6.25)
        let answers = Answers(calculatorOverride: .init(kind: .iob, units: 6.25))
        let dose = try #require(compose(amount, answers: answers, context: F.context(pump: pump)).dose)
        #expect(dose.calculatorIOBUnits == 1.5)
    }

    // MARK: - Typed glucose

    /// Outside 20–600 a typed glucose is invalid.
    @Test func aTypedGlucoseOutsideTheCalculatorsRangeIsRefused() {
        for mgdl in [0, 19, 601] {
            let amount = PhoneDoseEntry.Amount.calculator(
                carbsGrams: 0, glucose: .typed(mgdl: mgdl), recommendedUnits: 0, enteredUnits: 1)
            #expect(compose(amount).refusal == .invalidGlucose(mgdl: mgdl))
        }
    }

    /// A meter reads to 600: a typed 450 corrects from 450, and a typed 20 or 39 reduces the dose.
    @Test(arguments: [(450, 14.0), (600, 17.75), (39, 3.7), (20, 3.25)])
    func aTypedGlucoseFrom20To600Corrects(mgdl: Int, units: Double) throws {
        // 60 g at 10 g/U, ISF 40, target 110, IOB 0.5 U.
        let amount = PhoneDoseEntry.Amount.calculator(
            carbsGrams: 60, glucose: .typed(mgdl: mgdl), recommendedUnits: units, enteredUnits: units)
        let dose = try #require(compose(amount).dose)
        #expect(dose.units == units)
        #expect(dose.correctionGlucoseMgdl == mgdl)
    }

    @Test func typedGlucoseDeliversTheEnteredDose() throws {
        let amount = PhoneDoseEntry.Amount.calculator(
            carbsGrams: 60, glucose: .typed(mgdl: 150), recommendedUnits: 6.5, enteredUnits: 6.5)
        let dose = try #require(compose(amount).dose)
        #expect(dose.units == 6.5)
        #expect(dose.correctionGlucoseMgdl == 150)
    }

    // MARK: - A fresh CGM read

    /// The reading moved since the screen computed the dose, and the dose moved with it: the correction
    /// question shows the doses from the new reading, and the answer is the dose that goes, with no second
    /// question. (It asked "dose changed" after it before, offering the entered dose; to send that, the user
    /// now cancels and enters it.)
    @Test func changedReadingAsksWithTheNewDose() throws {
        let context = F.context(pump: F.pump(glucose: 220))
        // 60 g at 220 mg/dL: 6.00 + 2.75 − 0.50 = 8.25 U.
        #expect(
            DoseComposer.composePhone(F.phone(F.cgmDose()), context: context).prompt
                == .correction(mgdl: 220, targetMgdl: 110, applyUnits: 8.25, declineUnits: 6))

        let corrected = Answers(correction: .init(mgdl: 220, apply: true, units: 8.25))
        let dose = try #require(
            DoseComposer.composePhone(F.phone(F.cgmDose(), answers: corrected), context: context).dose)
        #expect(dose.units == 8.25)
        #expect(dose.correctionGlucoseMgdl == 220)

        let carbsOnly = Answers(correction: .init(mgdl: 220, apply: false, units: 6))
        let carbs = try #require(
            DoseComposer.composePhone(F.phone(F.cgmDose(), answers: carbsOnly), context: context).dose)
        #expect(carbs.units == 6)
        #expect(carbs.correctionGlucoseMgdl == nil)

        // An answer about a different reading, or a different dose, is asked again.
        let other = Answers(correction: .init(mgdl: 200, apply: true, units: 7.75))
        #expect(DoseComposer.composePhone(F.phone(F.cgmDose(), answers: other), context: context).prompt != nil)
        let stale = Answers(correction: .init(mgdl: 220, apply: true, units: 7.25))
        #expect(DoseComposer.composePhone(F.phone(F.cgmDose(), answers: stale), context: context).prompt != nil)

        // A dose of the user's own isn't asked about the correction; the new reading's dose still is, and
        // keeping theirs sends it.
        #expect(
            compose(F.cgmDose(entered: 7), context: context).prompt
                == .doseChanged(mgdl: 220, newUnits: 8.25, enteredUnits: 7))
        let keep = Answers(doseChanged: .keepEntered(mgdl: 220, enteredUnits: 7, newUnits: 8.25))
        let kept = try #require(compose(F.cgmDose(entered: 7), answers: keep, context: context).dose)
        #expect(kept.units == 7)
        #expect(kept.correctionGlucoseMgdl == 180)  // the reading the entered dose came from
    }

    /// A typed glucose has no fresh reading to check, but the pump's inputs can still move between the
    /// screen and the tap: past 0.10 U the user chooses.
    @Test func typedGlucoseWithMovedInputsPrompts() throws {
        var pump = F.pump()
        pump.insulinOnBoard = F.observed(3.0, age: 1)
        pump.bolusCalculator = F.observed(F.settings(reportedIOB: 3.0), age: 1)
        pump.cgm = pump.glucose
        let context = F.context(pump: pump)
        let typed = PhoneDoseEntry.Amount.calculator(
            carbsGrams: 60, glucose: .typed(mgdl: 180), recommendedUnits: 7.25, enteredUnits: 7.25)
        // 6.00 + 1.75 − 3.00 leaves no correction: 6.00 U.
        #expect(compose(typed, context: context).prompt == .doseChanged(mgdl: 180, newUnits: 6, enteredUnits: 7.25))
        let useNew = Answers(doseChanged: .useNew(mgdl: 180, units: 6))
        #expect(compose(typed, answers: useNew, context: context).dose?.units == 6)
    }

    /// Any change in the reading that moves the dose at all is asked about, with the new dose.
    @Test func changedReadingThatMovesTheDoseSlightlyPrompts() {
        // 182 mg/dL: 6.00 + 1.80 − 0.50 = 7.30 U.
        #expect(
            DoseComposer.composePhone(F.phone(F.cgmDose()), context: F.context(pump: F.pump(glucose: 182))).prompt
                == .correction(mgdl: 182, targetMgdl: 110, applyUnits: 7.3, declineUnits: 6))
    }

    /// With the same reading, inputs that moved the dose: the correction question names the dose from the
    /// inputs now, and that dose goes, past the 0.10 U limit or within it.
    @Test func sameReadingWithMovedInputsGivesTheDoseTheQuestionNamed() {
        var pump = F.pump()
        pump.insulinOnBoard = F.observed(0.3, age: 1)  // 7.45 U, 0.20 U from what was shown
        pump.bolusCalculator = F.observed(F.settings(reportedIOB: 0.3), age: 1)
        pump.cgm = pump.glucose
        #expect(compose(F.cgmDose(), context: F.context(pump: pump)).dose?.units == 7.45)
        pump.insulinOnBoard = F.observed(0.45, age: 1)  // 7.30 U, within the limit
        pump.bolusCalculator = F.observed(F.settings(reportedIOB: 0.45), age: 1)
        pump.cgm = pump.glucose
        #expect(compose(F.cgmDose(), context: F.context(pump: pump)).dose?.units == 7.3)
    }

    /// Where nothing is asked about the correction (under 70 the reduction always applies), a dose moved by
    /// the inputs is still asked about only past 0.10 U.
    @Test func withNoCorrectionQuestionMovedInputsPromptOnlyPastTheLimit() {
        // 60 g at 60 mg/dL: 6.00 − 1.25 − 0.50 = 4.25 U.
        let amount = F.cgmDose(shown: 60, recommended: 4.25, entered: 4.25)
        var pump = F.pump(glucose: 60)
        pump.insulinOnBoard = F.observed(0.3, age: 1)  // 4.45 U, 0.20 U from what was shown
        pump.bolusCalculator = F.observed(F.settings(reportedIOB: 0.3), age: 1)
        pump.cgm = pump.glucose
        #expect(
            compose(amount, context: F.context(pump: pump)).prompt
                == .doseChanged(mgdl: 60, newUnits: 4.45, enteredUnits: 4.25))
        pump.insulinOnBoard = F.observed(0.45, age: 1)  // 4.30 U, within the limit
        pump.bolusCalculator = F.observed(F.settings(reportedIOB: 0.45), age: 1)
        pump.cgm = pump.glucose
        #expect(compose(amount, context: F.context(pump: pump)).dose?.units == 4.25)
    }

    // MARK: - Stale glucose

    @Test func staleReadingPromptsAndIncludeUsesIt() throws {
        let pump = F.pump(glucose: 180, glucoseAge: 10 * 60)
        let context = F.context(pump: pump)
        let reading = try #require(pump.correctionReading)
        #expect(
            compose(F.cgmDose(), context: context).prompt
                == .staleGlucose(reading: reading, includeUnits: 7.25, carbsOnlyUnits: 6))

        let include = Answers(staleGlucose: .include(mgdl: 180, measuredAt: reading.measuredAt, units: 7.25))
        let dose = try #require(compose(F.cgmDose(), answers: include, context: context).dose)
        #expect(dose.units == 7.25)
        #expect(dose.correctionGlucoseMgdl == 180)
        #expect(dose.usedIncludedStaleGlucose)

        let carbsOnly = Answers(staleGlucose: .carbsOnly(units: 6))
        let carbs = try #require(compose(F.cgmDose(), answers: carbsOnly, context: context).dose)
        #expect(carbs.units == 6)
        #expect(carbs.correctionGlucoseMgdl == nil)
    }

    /// A stale-glucose answer is for the dose it showed: on a changed entry it is asked again.
    @Test func staleAnswerForADifferentDoseAsksAgain() {
        let context = F.context(pump: F.pump(glucose: 180, glucoseAge: 10 * 60))
        let carbsOnly = Answers(staleGlucose: .carbsOnly(units: 6))
        // 100 g comes to 10.00 U carbs only, not the 6.00 U the answer was given for.
        #expect(compose(F.cgmDose(carbs: 100, entered: 11), answers: carbsOnly, context: context).prompt != nil)
    }

    /// A CGM reading outside 20–600 gives no calculated dose.
    @Test func outOfRangeReadingRefuses() {
        for mgdl in [19, 601] {
            #expect(
                compose(F.cgmDose(), context: F.context(pump: F.pump(glucose: mgdl))).refusal
                    == .invalidGlucose(mgdl: mgdl))
        }
        // A stale one is never offered for inclusion.
        #expect(
            compose(F.cgmDose(), context: F.context(pump: F.pump(glucose: 19, glucoseAge: 10 * 60))).prompt?
                .includeUnits
                == .some(nil))
    }

    /// A reading older than 15 minutes is never offered, and an earlier "include" for it is asked again.
    @Test func readingPastTheIncludableLimitIsNotOffered() throws {
        let pump = F.pump(glucose: 180, glucoseAge: 30 * 60)
        let reading = try #require(pump.correctionReading)
        let context = F.context(pump: pump)
        #expect(
            compose(F.cgmDose(), context: context).prompt
                == .staleGlucose(reading: reading, includeUnits: nil, carbsOnlyUnits: 6))
        let include = Answers(staleGlucose: .include(mgdl: 180, measuredAt: reading.measuredAt, units: 7.25))
        #expect(compose(F.cgmDose(), answers: include, context: context).prompt != nil)
    }

    /// With no reading to include and none on the screen, the carbs-only dose the screen showed goes with
    /// nothing to ask, as on the watch: no reading at all, or one too old to include.
    @Test func noReadingToIncludeGoesCarbsOnly() throws {
        for pump in [F.pump(glucose: nil), F.pump(glucose: 180, glucoseAge: 30 * 60)] {
            let dose = try #require(
                compose(F.cgmDose(shown: nil, recommended: 6, entered: 6), context: F.context(pump: pump)).dose)
            #expect(dose.units == 6)
            #expect(dose.correctionGlucoseMgdl == nil)
        }
        // A reading still includable is asked about.
        #expect(
            compose(
                F.cgmDose(shown: nil, recommended: 6, entered: 6),
                context: F.context(pump: F.pump(glucose: 180, glucoseAge: 10 * 60))
            ).prompt?.includeUnits == 7.25)
    }

    /// The user answered a stale prompt, then a fresh reading arrived: the answer no longer holds, so
    /// the phone asks again rather than deliver the larger entered dose.
    @Test func freshReadingAfterAStaleAnswerAsksAgain() {
        let answers = Answers(staleGlucose: .carbsOnly(units: 6))
        #expect(
            DoseComposer.composePhone(F.phone(F.cgmDose(), answers: answers), context: F.context()).prompt
                == .correction(mgdl: 180, targetMgdl: 110, applyUnits: 7.25, declineUnits: 6))
    }

    // MARK: - Notices never change the dose

    /// 10 g at 180 mg/dL comes to 1.00 + 1.75 − 0.50 = 2.25 U.
    private func override(entered: Double, glucose: Int = 180, recommended: Double = 2.25) -> PhoneDoseEntry.Amount {
        .calculator(
            carbsGrams: 10, glucose: .typed(mgdl: glucose), recommendedUnits: recommended, enteredUnits: entered)
    }

    private func stacking(_ dose: ComposedDose) -> StackingGuard.Disclosure? {
        for case .stacking(let disclosure) in dose.notices { return disclosure }
        return nil
    }

    @Test func notGlucoseAboveTargetNoStackingNotice() throws {
        let dose = try #require(compose(override(entered: 5, glucose: 100, recommended: 0.25)).dose)
        #expect(stacking(dose) == nil)
    }

    /// Delivering the calculator's own carbs-only number isn't a difference from the calculator.
    @Test func answeredCalculatorDoseIsNotADifference() throws {
        let context = F.context(pump: F.pump(glucose: 180, glucoseAge: 10 * 60))
        let dose = try #require(
            compose(F.cgmDose(), answers: Answers(staleGlucose: .carbsOnly(units: 6)), context: context).dose)
        #expect(!dose.notices.contains { if case .differsFromCalculator = $0 { true } else { false } })
    }

    /// A dose the screen computed with no reading is recorded with no correction glucose, even when a
    /// fresh reading has arrived since.
    @Test func doseComputedWithoutAReadingRecordsNone() throws {
        // At target, 60 g comes to 6.00 U with or without the reading.
        let context = F.context(pump: F.pump(glucose: 110))
        let dose = try #require(compose(F.cgmDose(shown: nil, recommended: 6, entered: 6), context: context).dose)
        #expect(dose.correctionGlucoseMgdl == nil)
        #expect(dose.request.bgMgdl == nil)
    }

    @Test func differentFromTheCalculatorIsNoticed() throws {
        let dose = try #require(compose(override(entered: 2.5)).dose)
        #expect(dose.notices.contains(.differsFromCalculator(deliveredUnits: 2.5, suggestedUnits: 2.25)))
        #expect(
            compose(override(entered: 2.3)).dose?.notices.contains {
                $0 == .differsFromCalculator(deliveredUnits: 2.3, suggestedUnits: 2.25)
            } == false)
    }
}

/// Ported from the old app's `StackingGuardDeliverInvariantTests`: while a stacking notice fires, the
/// composed dose is exactly the units the user confirmed. The notice never clamps, rewrites or blocks it.
@Suite struct StackingGuardDeliverInvariantTests {
    typealias F = DoseFixtures

    /// 10 g at 180 mg/dL comes to 2.25 U.
    private func compose(entered: Double) -> ComposedDose? {
        DoseComposer.composePhoneCorrecting(
            F.phone(
                .calculator(carbsGrams: 10, glucose: .typed(mgdl: 180), recommendedUnits: 2.25, enteredUnits: entered)),
            context: F.context()
        ).dose
    }

    private func friction(_ dose: ComposedDose) -> StackingGuard.Friction? {
        for case .stacking(let disclosure) in dose.notices { return disclosure.friction }
        return nil
    }

    @Test func deliveredEqualsConsentedAtEveryTier() throws {
        for (entered, tier) in [(2.5, StackingGuard.Friction.disclose), (3.5, .confirmExtra), (5.0, .reenter)] {
            let dose = try #require(compose(entered: entered))
            #expect(friction(dose) == tier, "\(entered) U")
            #expect(dose.units == entered)
        }
    }

    @Test func deliveredEqualsConsentedAtThePumpsMax() throws {
        let dose = try #require(compose(entered: 25))
        #expect(dose.notices.contains { if case .atPumpMax = $0 { true } else { false } })
        #expect(dose.units == 25)
    }

    /// The IOB the dose carries to the pump is the pump's own reading the calculator used.
    @Test func calculatorIOBIsThePumpsReading() throws {
        let dose = try #require(compose(entered: 2.25))
        #expect(dose.calculatorIOBUnits == F.pump().insulinOnBoard?.value)
    }
}

extension PhoneDosePrompt {
    var kind: CalcInputGate.Kind? {
        if case .calculatorInputs(let kind, _, _) = self { return kind }
        return nil
    }
    var includeUnits: Double?? {
        if case .staleGlucose(_, let includeUnits, _) = self { return includeUnits }
        return nil
    }
    var calculatorUnits: Double? {
        if case .calculatorInputs(_, let units, _) = self { return units }
        return nil
    }
}
