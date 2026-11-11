import Foundation
import Testing

@testable import faBolusCore

/// The pump's own word on its CGM reading: a LOW or HIGH reading, a sensor state on its home screen, a
/// Libre's Check BG icon, its calculator's auto-fill flag off, or a CGM state not read for the attempt.
/// Each keeps the reading from correcting a dose by itself; the dose can be for carbs only, or correct
/// from a typed BG.
@Suite struct PumpGlucoseCautionTests {
    typealias F = DoseFixtures

    /// The fixture pump (180 mg/dL, no error) with one change.
    private static func pump(_ change: (inout PumpState) -> Void) -> PumpState {
        var pump = F.pump()
        change(&pump)
        return pump
    }

    private static func display(state: PumpCGMState = .noError, checkBG: Bool = false, age: TimeInterval = 2)
        -> Observed<PumpCGMDisplay>
    {
        F.observed(PumpCGMDisplay(state: state, checkBG: checkBG), age: age)
    }

    static let cautions: [(PumpState, PumpGlucoseCaution)] = [
        (pump { $0.glucose?.value.outOfRange = .low }, .outOfRange(.low)),
        (pump { $0.glucose?.value.outOfRange = .high }, .outOfRange(.high)),
        (pump { $0.cgmDisplay = display(state: .noReading) }, .sensorState(.noReading)),
        (pump { $0.cgmDisplay = display(state: .warmingUp) }, .sensorState(.warmingUp)),
        (pump { $0.cgmDisplay = display(state: .unknown(9)) }, .sensorState(.unknown(9))),
        (pump { $0.cgmDisplay = display(checkBG: true) }, .checkBG),
        (pump { $0.bolusCalculator?.value.glucoseAutoFillAllowed = false }, .autoFillOff),
        // Read before this attempt began, so it says nothing about the reading now.
        (pump { $0.cgmDisplay = display(age: 10) }, .cgmStateNotRead),
        (pump { $0.cgmDisplay = nil }, .cgmStateNotRead)
    ]

    @Test(arguments: cautions.indices)
    func aCautionedReadingAsksForCarbsOnlyOnThePhone(index: Int) throws {
        let (pump, caution) = Self.cautions[index]
        let context = F.context(pump: pump)
        #expect(
            DoseComposer.composePhone(F.phone(F.cgmDose()), context: context).prompt
                == .pumpGlucoseCaution(caution, carbsOnlyUnits: 6))
        // Carbs only, answered for that dose: no correction.
        let answers = PhoneDoseAnswers(staleGlucose: .carbsOnly(units: 6))
        let dose = try #require(
            DoseComposer.composePhone(F.phone(F.cgmDose(), answers: answers), context: context).dose)
        #expect(dose.units == 6)
        #expect(dose.correctionGlucoseMgdl == nil)
        // The screen doesn't offer the reading either. It needs a CGM state, but not one read for an
        // attempt: only the dose waits for that.
        if pump.cgmDisplay != nil, caution == .cgmStateNotRead {
            #expect(pump.glucoseForCorrection(thresholds: .standard, now: F.now)?.mgdl == 180)
        } else {
            #expect(pump.glucoseForCorrection(thresholds: .standard, now: F.now) == nil)
        }
    }

    /// A typed BG still corrects: the caution is on the CGM reading only.
    @Test(arguments: cautions.indices)
    func aTypedBGStillCorrects(index: Int) throws {
        let context = F.context(pump: Self.cautions[index].0)
        let typed = PhoneDoseEntry.Amount.calculator(
            carbsGrams: 60, glucose: .typed(mgdl: 180), recommendedUnits: 7.25, enteredUnits: 7.25)
        let dose = try #require(DoseComposer.composePhone(F.phone(typed), context: context).dose)
        #expect(dose.units == 7.25)
        #expect(dose.correctionGlucoseMgdl == 180)
    }

    /// A remote carb dose gets no correction from a cautioned reading: one the watch sized with it is
    /// refused as changed, and one sized for carbs only goes ahead.
    @Test(arguments: cautions.indices)
    func aRemoteDoseGetsNoCorrectionFromACautionedReading(index: Int) throws {
        let context = F.context(pump: Self.cautions[index].0)
        let withCorrection = DoseComposer.composeRemote(
            F.remote(F.carbs(60, estimate: 7.25)), ledger: .init(), context: context)
        #expect(withCorrection.refusal == .doseChanged(estimateUnits: 7.25, doseUnits: 6))
        let carbsOnly = try #require(
            DoseComposer.composeRemote(
                F.remote(F.carbs(60, estimate: 6), glucose: nil), ledger: .init(), context: context
            )
            .dose)
        #expect(carbsOnly.units == 6)
        #expect(carbsOnly.correctionGlucoseMgdl == nil)
    }

    /// A cautioned reading is never offered for inclusion once it is old either.
    @Test func anOldCautionedReadingIsNotOfferedForInclusion() {
        var pump = F.pump(glucose: 180, glucoseAge: 10 * 60)
        pump.cgmDisplay = Self.display(checkBG: true)
        #expect(
            DoseComposer.composePhone(F.phone(F.cgmDose()), context: F.context(pump: pump)).prompt
                == .pumpGlucoseCaution(.checkBG, carbsOnlyUnits: 6))
    }

    /// With no error, the flag on (or not reported) and the state read for the attempt, the reading
    /// corrects as before.
    @Test(arguments: [true, nil] as [Bool?])
    func aReadingThePumpAllowsCorrects(autoFill: Bool?) throws {
        let pump = Self.pump { $0.bolusCalculator?.value.glucoseAutoFillAllowed = autoFill }
        #expect(pump.glucoseCaution(cgmStateReadSince: F.requestedAt) == nil)
        let dose = try #require(DoseComposer.composePhone(F.phone(F.cgmDose()), context: F.context(pump: pump)).dose)
        #expect(dose.units == 7.25)
        #expect(dose.correctionGlucoseMgdl == 180)
    }

    /// A reading from another glucose source (the pump's own was stale or missing) is that source's to
    /// judge: the pump's CGM state doesn't apply to it.
    @Test func aReadingFromAnotherSourceIsNotJudgedByThePump() throws {
        var pump = Self.pump { $0.cgmDisplay = Self.display(state: .sensorFailed) }
        let at = F.now.addingTimeInterval(-60)
        pump.glucose = Observed(
            PumpGlucose(mgdl: 180, trend: nil), measuredAt: at, receivedAt: at, source: .glucoseSource(id: "dexcom"))
        #expect(pump.glucoseCaution() == nil)
        let dose = try #require(DoseComposer.composePhone(F.phone(F.cgmDose()), context: F.context(pump: pump)).dose)
        #expect(dose.correctionGlucoseMgdl == 180)
    }
}
