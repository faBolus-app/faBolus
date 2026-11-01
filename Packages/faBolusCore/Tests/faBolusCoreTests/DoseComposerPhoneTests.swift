import Foundation
import Testing

@testable import faBolusCore

/// One test per phone-dose check, each from `DoseComposer.composePhone`.
@Suite struct DoseComposerPhoneTests {
    typealias F = DoseFixtures
    typealias Answers = PhoneDoseAnswers

    private func compose(_ entry: PhoneDoseEntry, context: DoseContext = F.context()) -> PhoneDoseDecision {
        DoseComposer.composePhone(entry, context: context)
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

    /// An accepted override still goes through the glucose checks.
    @Test func overrideStillChecksTheReading() {
        var pump = F.pump(glucose: 220)
        iobReadEarlier(&pump)
        let answers = Answers(calculatorOverride: .init(kind: .iob, units: 7.25))
        #expect(
            compose(F.cgmDose(), answers: answers, context: F.context(pump: pump)).prompt
                == .glucoseChanged(mgdl: 220, newUnits: 8.25, enteredUnits: 7.25))
    }

    /// The two IOB readings disagreeing makes IOB unverified, which is asked about like a late read.
    @Test func disagreeingIOBReadingsPrompt() {
        var pump = F.pump()
        pump.bolusCalculator = F.observed(
            BolusCalculatorSettings(
                carbRatio: 10, correctionFactor: 40, targetMgdl: 110, maxBolusUnits: 25, insulinOnBoardUnits: 1.5),
            age: 2)
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

    // MARK: - Typed glucose

    @Test func implausibleTypedGlucoseIsRefused() {
        for mgdl in [39, 401] {
            let amount = PhoneDoseEntry.Amount.calculator(
                carbsGrams: 0, glucose: .typed(mgdl: mgdl), recommendedUnits: 0, enteredUnits: 1)
            #expect(compose(amount).refusal == .implausibleGlucose(mgdl: mgdl))
        }
    }

    @Test func typedGlucoseDeliversTheEnteredDose() throws {
        let amount = PhoneDoseEntry.Amount.calculator(
            carbsGrams: 60, glucose: .typed(mgdl: 150), recommendedUnits: 6.5, enteredUnits: 6.5)
        let dose = try #require(compose(amount).dose)
        #expect(dose.units == 6.5)
        #expect(dose.correctionGlucoseMgdl == 150)
    }

    // MARK: - A fresh CGM read

    /// The reading moved since the screen computed the dose, and the dose moved with it: the user is
    /// asked which to deliver.
    @Test func changedReadingPromptsAndTheAnswerIsHonored() throws {
        let context = F.context(pump: F.pump(glucose: 220))
        // 60 g at 220 mg/dL: 6.00 + 2.75 − 0.50 = 8.25 U.
        #expect(
            compose(F.cgmDose(), context: context).prompt
                == .glucoseChanged(mgdl: 220, newUnits: 8.25, enteredUnits: 7.25))

        let useNew = Answers(glucoseChanged: .useNew(mgdl: 220, units: 8.25))
        let dose = try #require(compose(F.cgmDose(), answers: useNew, context: context).dose)
        #expect(dose.units == 8.25)
        #expect(dose.correctionGlucoseMgdl == 220)

        let keep = Answers(glucoseChanged: .keepEntered(mgdl: 220))
        let kept = try #require(compose(F.cgmDose(), answers: keep, context: context).dose)
        #expect(kept.units == 7.25)
        #expect(kept.correctionGlucoseMgdl == 180)  // the reading the entered dose came from

        // An answer about a different reading is asked again.
        let other = Answers(glucoseChanged: .useNew(mgdl: 200, units: 7.75))
        #expect(compose(F.cgmDose(), answers: other, context: context).prompt != nil)
    }

    /// Any change in the reading that moves the dose at all is asked about.
    @Test func changedReadingThatMovesTheDoseSlightlyPrompts() {
        // 182 mg/dL: 6.00 + 1.80 − 0.50 = 7.30 U.
        #expect(compose(F.cgmDose(), context: F.context(pump: F.pump(glucose: 182))).prompt != nil)
    }

    /// With the same reading, a dose moved by the inputs is asked about only past 0.10 U.
    @Test func sameReadingWithMovedInputsPromptsOnlyPastTheLimit() {
        var pump = F.pump()
        pump.insulinOnBoard = F.observed(0.3, age: 1)  // 7.45 U, 0.20 U from what was shown
        #expect(compose(F.cgmDose(), context: F.context(pump: pump)).prompt != nil)
        pump.insulinOnBoard = F.observed(0.45, age: 1)  // 7.30 U, within the limit
        #expect(compose(F.cgmDose(), context: F.context(pump: pump)).dose?.units == 7.25)
    }

    // MARK: - Stale glucose

    @Test func staleReadingPromptsAndIncludeUsesIt() throws {
        let pump = F.pump(glucose: 180, glucoseAge: 10 * 60)
        let context = F.context(pump: pump)
        let reading = try #require(pump.glucose)
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

    /// A reading older than 15 minutes is never offered, and an earlier "include" for it is asked again.
    @Test func readingPastTheIncludableLimitIsNotOffered() throws {
        let pump = F.pump(glucose: 180, glucoseAge: 30 * 60)
        let reading = try #require(pump.glucose)
        let context = F.context(pump: pump)
        #expect(
            compose(F.cgmDose(), context: context).prompt
                == .staleGlucose(reading: reading, includeUnits: nil, carbsOnlyUnits: 6))
        let include = Answers(staleGlucose: .include(mgdl: 180, measuredAt: reading.measuredAt, units: 7.25))
        #expect(compose(F.cgmDose(), answers: include, context: context).prompt != nil)
    }

    @Test func noReadingOffersCarbsOnly() {
        #expect(
            compose(F.cgmDose(shown: nil), context: F.context(pump: F.pump(glucose: nil))).prompt
                == .staleGlucose(reading: nil, includeUnits: nil, carbsOnlyUnits: 6))
    }

    /// The user answered a stale prompt, then a fresh reading arrived: the answer no longer holds, so
    /// the phone asks again rather than deliver the larger entered dose.
    @Test func freshReadingAfterAStaleAnswerAsksAgain() {
        let answers = Answers(staleGlucose: .carbsOnly(units: 6))
        #expect(
            compose(F.cgmDose(), answers: answers).prompt
                == .glucoseChanged(mgdl: 180, newUnits: 7.25, enteredUnits: 7.25))
    }

    // MARK: - Notices never change the dose

    /// 10 g at 180 mg/dL comes to 1.00 + 1.75 − 0.50 = 2.25 U.
    private func override(entered: Double, glucose: Int = 180) -> PhoneDoseEntry.Amount {
        .calculator(carbsGrams: 10, glucose: .typed(mgdl: glucose), recommendedUnits: 2.25, enteredUnits: entered)
    }

    private func stacking(_ dose: ComposedDose) -> StackingGuard.Disclosure? {
        for case .stacking(let disclosure) in dose.notices { return disclosure }
        return nil
    }

    @Test func notGlucoseAboveTargetNoStackingNotice() throws {
        let dose = try #require(compose(override(entered: 5, glucose: 100)).dose)
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

    @Test func moreThanTheReservoirIsNoticed() throws {
        var pump = F.pump()
        pump.reservoirUnits = F.observed(2, age: 1)
        let dose = try #require(compose(.units(2.5), context: F.context(pump: pump)).dose)
        #expect(dose.notices.contains { if case .moreThanReservoir = $0 { true } else { false } })
        #expect(dose.units == 2.5)
    }
}

/// Ported from the old app's `StackingGuardDeliverInvariantTests`: while a stacking notice fires, the
/// composed dose is exactly the units the user confirmed. The notice never clamps, rewrites or blocks it.
@Suite struct StackingGuardDeliverInvariantTests {
    typealias F = DoseFixtures

    /// 10 g at 180 mg/dL comes to 2.25 U.
    private func compose(entered: Double) -> ComposedDose? {
        DoseComposer.composePhone(
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
    var calculatorUnits: Double? {
        if case .calculatorInputs(_, let units, _) = self { return units }
        return nil
    }
}
