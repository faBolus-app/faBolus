import Foundation
import Testing

@testable import faBolusCore

/// Add a correction? / Reduce the bolus?: asked from 70 mg/dL up when correcting changes the dose; no gives
/// the carbs-only dose. Under 70 the reduction always applies. And the calculator's messages, which never
/// change the dose.
@Suite struct CorrectionPromptTests {
    typealias F = DoseFixtures

    /// 60 g at 10 g/U, ISF 40, target 110, IOB 0.5 U: carbs only is 6.00 U.
    private static func compose(
        _ mgdl: Int?, typed: Bool = false, recommended: Double, entered: Double? = nil,
        answer: PhoneDoseAnswers.Correction? = nil
    ) -> PhoneDoseDecision {
        let glucose: PhoneDoseEntry.Glucose = typed ? .typed(mgdl: mgdl ?? 0) : .currentReading(shownMgdl: mgdl)
        let amount = PhoneDoseEntry.Amount.calculator(
            carbsGrams: 60, glucose: glucose, recommendedUnits: recommended, enteredUnits: entered ?? recommended)
        let pump = F.pump(glucose: typed ? 180 : mgdl)
        return DoseComposer.composePhone(
            F.phone(amount, answers: .init(correction: answer)), context: F.context(pump: pump))
    }

    @Test(arguments: [false, true])
    func aboveTargetAsksToAddTheCorrection(typed: Bool) throws {
        #expect(
            Self.compose(180, typed: typed, recommended: 7.25).prompt
                == .correction(mgdl: 180, targetMgdl: 110, applyUnits: 7.25, declineUnits: 6))
        let added = try #require(
            Self.compose(180, typed: typed, recommended: 7.25, answer: .init(mgdl: 180, apply: true, units: 7.25))
                .dose)
        #expect(added.units == 7.25)
        #expect(added.correctionGlucoseMgdl == 180)
        let carbsOnly = try #require(
            Self.compose(180, typed: typed, recommended: 7.25, answer: .init(mgdl: 180, apply: false, units: 6)).dose)
        #expect(carbsOnly.units == 6)
        #expect(carbsOnly.correctionGlucoseMgdl == nil)
        #expect(carbsOnly.calculatorCarbUnits == 6)
    }

    /// From 70 up to the target the reduction can be declined: 90 mg/dL reduces 6.00 U to 5.00 U.
    @Test func belowTargetAsksToReduce() throws {
        #expect(
            Self.compose(90, recommended: 5).prompt
                == .correction(mgdl: 90, targetMgdl: 110, applyUnits: 5, declineUnits: 6))
        let kept = try #require(Self.compose(90, recommended: 5, answer: .init(mgdl: 90, apply: false, units: 6)).dose)
        #expect(kept.units == 6)
    }

    /// Under 70 the reduction applies with no question, and the review says to eat carbs.
    @Test func underSeventyTheReductionAlwaysApplies() throws {
        // 6.00 - 50/40 (1.25) - 0.50 = 4.25 U.
        let dose = try #require(Self.compose(60, recommended: 4.25).dose)
        #expect(dose.units == 4.25)
        #expect(dose.correctionGlucoseMgdl == 60)
        #expect(dose.notices.contains(.calculator(.lowGlucose(.reduced))))
        // A dose the user entered instead isn't said to be reduced, but the glucose is still low.
        let entered = try #require(Self.compose(60, typed: true, recommended: 4.25, entered: 6).dose)
        #expect(entered.units == 6)
        #expect(entered.notices.contains(.calculator(.lowGlucose(.noCarbs))))
        #expect(!entered.notices.contains(.calculator(.lowGlucose(.reduced))))
        // Above the low, nothing is said of an entered dose.
        let above = try #require(Self.compose(120, typed: true, recommended: 6, entered: 7).dose)
        #expect(!above.notices.contains { if case .calculator = $0 { true } else { false } })
    }

    /// No question when correcting doesn't change the dose: on target, or IOB covering the correction.
    @Test func noQuestionWhenTheCorrectionChangesNothing() throws {
        let onTarget = try #require(Self.compose(110, recommended: 6).dose)
        #expect(onTarget.notices.contains(.calculator(.iobMayDropLow)))
        // 10 mg/dL over target is 0.25 U, less than the 0.50 U of IOB.
        let covered = try #require(Self.compose(120, recommended: 6).dose)
        #expect(covered.notices.contains(.calculator(.iobCoversCorrection)))
    }

    /// With no carbs there's no carbs-only dose to choose: a correction alone isn't asked about.
    @Test func noQuestionWithoutCarbs() throws {
        // (180 - 110) / 40 is 1.75 U, less the 0.50 U of IOB.
        let amount = PhoneDoseEntry.Amount.calculator(
            carbsGrams: 0, glucose: .typed(mgdl: 180), recommendedUnits: 1.25, enteredUnits: 1.25)
        let dose = try #require(DoseComposer.composePhone(F.phone(amount), context: F.context()).dose)
        #expect(dose.units == 1.25)
        #expect(dose.correctionGlucoseMgdl == 180)
    }

    /// A dose the user entered themselves isn't asked about: they chose its size.
    @Test func anEnteredDoseIsntAsked() throws {
        let dose = try #require(Self.compose(180, recommended: 7.25, entered: 8).dose)
        #expect(dose.units == 8)
    }

    /// An answer counts for the glucose and dose it showed: a new reading asks again.
    @Test func anAnswerForAnotherGlucoseAsksAgain() {
        #expect(
            Self.compose(200, recommended: 7.75, answer: .init(mgdl: 180, apply: true, units: 7.25)).prompt
                == .correction(mgdl: 200, targetMgdl: 110, applyUnits: 7.75, declineUnits: 6))
        #expect(
            Self.compose(180, recommended: 7.25, answer: .init(mgdl: 180, apply: false, units: 5.5)).prompt != nil)
    }

    /// A card chosen for a question the fresh read took away is asked about, never sent as entered: within
    /// the limit, the carbs-only card would otherwise have gone as whatever was entered.
    @Test func aCardForAQuestionThatWentIsAskedAbout() {
        // 10 mg/dL over target is 0.25 U, which the 0.50 U of IOB covers: no question at 120.
        #expect(
            Self.compose(120, recommended: 6, answer: .init(mgdl: 120, apply: false, units: 6)).prompt
                == .doseChanged(mgdl: 120, newUnits: 6, enteredUnits: 6))
        #expect(
            Self.compose(120, typed: true, recommended: 6.05, answer: .init(mgdl: 120, apply: false, units: 6.05))
                .prompt == .doseChanged(mgdl: 120, newUnits: 6, enteredUnits: 6.05))
    }

    /// The review's split adds up to the dose: the correction is the calculator's, the rounding down to the
    /// pump's step is in the food's share.
    @Test func theSplitAddsUpToTheDose() throws {
        // 47.3 g at 10 g/U is 4.73 U, rounded down to 4.70 U on target.
        func dose(_ mgdl: Int, _ units: Double, _ answer: PhoneDoseAnswers.Correction? = nil) throws -> ComposedDose {
            let amount = PhoneDoseEntry.Amount.calculator(
                carbsGrams: 47.3, glucose: .typed(mgdl: mgdl), recommendedUnits: units, enteredUnits: units)
            return try #require(
                DoseComposer.composePhone(F.phone(amount, answers: .init(correction: answer)), context: F.context())
                    .dose)
        }
        let onTarget = try dose(110, 4.7)
        #expect(onTarget.units == 4.7)
        #expect(abs((onTarget.calculatorFoodUnits ?? 0) - 4.7) < 1e-9)
        // 180: 1.75 U less 0.50 U of IOB is 1.25 U, 5.98 U in all, rounded down to 5.95 U.
        let corrected = try dose(180, 5.95, .init(mgdl: 180, apply: true, units: 5.95))
        #expect(corrected.units == 5.95)
        #expect(abs((corrected.calculatorFoodUnits ?? 0) - 4.7) < 1e-9)
    }

    // MARK: On a remote

    /// The watch asks too: declined from 70 mg/dL up, the phone composes carbs only; under 70 the reduction
    /// applies whatever the remote sent, so a carbs-only estimate is refused as changed.
    @Test func aRemoteMayDeclineTheCorrectionFromSeventyUp() throws {
        var request = F.remote(F.carbs(60, estimate: 6), glucose: 180)
        request.declineCorrection = true
        let declined = try #require(
            DoseComposer.composeRemote(request, ledger: .init(), context: F.context(pump: F.pump(glucose: 180))).dose)
        #expect(declined.units == 6)
        #expect(declined.correctionGlucoseMgdl == nil)
        #expect(
            DoseComposer.composeRemote(request, ledger: .init(), context: F.context(pump: F.pump(glucose: 60))).refusal
                == .doseChanged(estimateUnits: 6, doseUnits: 4.25))
        // Not declined, the fresh reading corrects as before.
        let corrected = DoseComposer.composeRemote(
            F.remote(F.carbs(60, estimate: 6), glucose: nil), ledger: .init(),
            context: F.context(pump: F.pump(glucose: 180)))
        #expect(corrected.refusal == .doseChanged(estimateUnits: 6, doseUnits: 7.25))
    }

    /// A remote's answer holds for the reading it was given at, as the phone's does: at another reading the
    /// phone corrects from its own, and asks again whenever that changes the dose, even within the limit.
    @Test func aRemoteDeclineAtAnotherReadingAsksAgain() throws {
        func compose(declinedAt: Int?, fresh: Int) -> RemoteDoseDecision {
            var request = F.remote(F.carbs(60, estimate: 6), glucose: declinedAt)
            request.declineCorrection = true
            return DoseComposer.composeRemote(
                request, ledger: .init(), context: F.context(pump: F.pump(glucose: fresh)))
        }
        // "Add a correction?" declined at 180, and the phone reads 90: not a reduction the user declined.
        #expect(compose(declinedAt: 180, fresh: 90).refusal == .doseChanged(estimateUnits: 6, doseUnits: 5))
        // 132 is 0.55 U over, 0.05 U past the IOB: within the limit, but still a correction declined.
        #expect(compose(declinedAt: 180, fresh: 132).refusal == .doseChanged(estimateUnits: 6, doseUnits: 6.05))
        // With no reading named there's nothing it held for.
        #expect(compose(declinedAt: nil, fresh: 180).refusal == .doseChanged(estimateUnits: 6, doseUnits: 7.25))
        // At a reading where correcting changes nothing, carbs only goes.
        #expect(try #require(compose(declinedAt: 180, fresh: 120).dose).units == 6)
    }

    // MARK: The messages

    private static func message(carbs: Double, bg: Int?, iob: Double = 0.5) -> CalculatorMessage? {
        let profile = BolusMath.Profile(carbRatioGramsPerUnit: 10, isfMgdlPerUnit: 40, targetBgMgdl: 110, iobUnits: iob)
        let result = BolusMath.estimate(carbsGrams: carbs > 0 ? carbs : nil, bgMgdl: bg, profile: profile)
        return CalculatorMessage.of(
            result, food: .carbs(grams: carbs), glucoseMgdl: bg, targetMgdl: 110, isfMgdlPerUnit: 40, iobUnits: iob)
    }

    @Test func theMessageSaysWhyTheDoseIsWhatItIs() {
        #expect(Self.message(carbs: 0, bg: 60) == .lowGlucose(.noCarbs))
        // 1.00 - 70/40 (1.75) - 0.50 is under zero.
        #expect(Self.message(carbs: 10, bg: 40) == .lowGlucose(.noBolus))
        #expect(Self.message(carbs: 60, bg: 60) == .lowGlucose(.reduced))
        // Below target, as Tandem's app: only a dose the reduction took to zero is explained, with the IOB
        // when it may take the glucose under 70 (70 - 0.50 x 40 is 50).
        #expect(Self.message(carbs: 60, bg: 90) == nil)
        #expect(Self.message(carbs: 10, bg: 70) == .reducedToZero(iob: true))
        #expect(Self.message(carbs: 0, bg: 100, iob: 0) == .reducedToZero(iob: false))
        #expect(Self.message(carbs: 60, bg: 110) == .iobMayDropLow)
        #expect(Self.message(carbs: 60, bg: 110, iob: 0) == nil)
        #expect(Self.message(carbs: 60, bg: 120) == .iobCoversCorrection)
        // Above target, IOB more than the correction and enough to take 120 under 70 (120 - 1.50 x 40).
        #expect(Self.message(carbs: 60, bg: 120, iob: 1.5) == .iobMayDropLow)
        #expect(Self.message(carbs: 60, bg: 180) == nil)
        #expect(Self.message(carbs: 60, bg: nil) == nil)
    }

    /// The screen's suggestion carries the same message.
    @Test func theScreenShowsTheMessage() {
        #expect(
            DoseComposer.recommend(carbsGrams: 60, glucoseMgdl: 60, context: F.context()).message
                == .lowGlucose(.reduced))
        #expect(DoseComposer.recommend(carbsGrams: 60, glucoseMgdl: 180, context: F.context()).message == nil)
        // From 70 to the target a reduction that leaves a dose isn't explained: the question names both.
        #expect(DoseComposer.recommend(carbsGrams: 60, glucoseMgdl: 90, context: F.context()).message == nil)
        // Reduced to zero, the screen says why, carbs or not: Deliver refuses 0 U before any question, so
        // nothing else would. 10 g is 1.00 U; 20/40 (0.50) and the 0.50 U of IOB take it to 0.
        #expect(
            DoseComposer.recommend(carbsGrams: 0, glucoseMgdl: 90, context: F.context()).message
                == .reducedToZero(iob: false))
        #expect(
            DoseComposer.recommend(carbsGrams: 10, glucoseMgdl: 90, context: F.context()).message
                == .reducedToZero(iob: false))
    }
}
