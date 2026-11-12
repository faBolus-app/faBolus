import Foundation
import Testing

@testable import faBolusCore

/// Carbs off on the pump (the calculator snapshot's carb entry, byte 13): as in Tandem's apps, the
/// calculator's food entry is insulin units, the glucose still corrects, and no carbs go with the bolus.
@Suite struct CarbsOffTests {
    typealias F = DoseFixtures

    /// The fixtures' pump with carbs off. Its carb ratio is 0: what a t:slim reports then isn't known, and
    /// with carbs off the calculator doesn't use it.
    static func pump(glucose: Int? = 180) -> PumpState {
        var pump = F.pump(glucose: glucose)
        var settings = F.settings
        settings.carbRatio = 0
        settings.carbEntryEnabled = false
        pump.bolusCalculator = F.observed(settings, age: 2)
        return pump
    }

    static func insulin(_ units: Double, bg: Int, recommended: Double, entered: Double? = nil)
        -> PhoneDoseEntry.Amount
    {
        .calculator(
            food: .insulin(units: units), glucose: .typed(mgdl: bg), recommendedUnits: recommended,
            enteredUnits: entered ?? recommended)
    }

    @Test func noCarbRatioIsNeededWithCarbsOff() {
        var settings = F.settings
        settings.carbRatio = 0
        #expect(!settings.isUsable)
        settings.carbEntryEnabled = false
        #expect(settings.isUsable)
        #expect(settings.carbsOff)
    }

    /// 3 U for the food at 180 mg/dL: 3.00 + (70 / 40 = 1.75) − 0.50 = 4.25 U.
    @Test func theFoodEntryIsUnits() throws {
        let context = F.context(pump: Self.pump())
        let dose = try #require(
            DoseComposer.composePhoneCorrecting(
                F.phone(Self.insulin(3, bg: 180, recommended: 4.25)), context: context
            ).dose)
        #expect(dose.units == 4.25)
        #expect(dose.correctionGlucoseMgdl == 180)
        // No carbs go with the bolus, so no carb entry is sent; the food part is the insulin entered.
        #expect(dose.request.carbsGrams == nil)
        #expect(dose.calculatorCarbUnits == 3)
        #expect(dose.request.foodInsulinUnits == 3)
    }

    @Test func theCorrectionIsAskedAsWithCarbs() {
        let context = F.context(pump: Self.pump())
        #expect(
            DoseComposer.composePhone(F.phone(Self.insulin(3, bg: 180, recommended: 4.25)), context: context).prompt
                == .correction(mgdl: 180, targetMgdl: 110, applyUnits: 4.25, declineUnits: 3))
    }

    /// Below target the correction reduces the food's insulin, and never below nothing.
    @Test func aLowGlucoseReducesTheFoodsInsulin() {
        let profile = BolusMath.Profile(carbRatioGramsPerUnit: 0, isfMgdlPerUnit: 40, targetBgMgdl: 110, iobUnits: 0)
        let reduced = BolusMath.estimate(foodUnits: 3, bgMgdl: 70, profile: profile)
        #expect(reduced.totalUnits == 2)
        #expect(!reduced.sanityFailed)
        #expect(BolusMath.estimate(foodUnits: 0.5, bgMgdl: 30, profile: profile).totalUnits == 0)
    }

    /// An entry typed before carbs were turned on or off means something else now, so it's entered again,
    /// never converted. A correction only (nothing for food) fits either.
    @Test func anEntryTypedBeforeCarbsChangedIsEnteredAgain() throws {
        let off = F.context(pump: Self.pump())
        let grams = PhoneDoseEntry.Amount.calculator(
            carbsGrams: 60, glucose: .typed(mgdl: 180), recommendedUnits: 7.25, enteredUnits: 7.25)
        #expect(DoseComposer.composePhone(F.phone(grams), context: off).refusal == .carbEntryChanged(carbsOff: true))

        let on = F.context()
        #expect(
            DoseComposer.composePhone(F.phone(Self.insulin(3, bg: 180, recommended: 4.25)), context: on).refusal
                == .carbEntryChanged(carbsOff: false))

        // 1.75 − 0.50 = 1.25 U.
        let correctionOnly = PhoneDoseEntry.Amount.calculator(
            carbsGrams: 0, glucose: .typed(mgdl: 180), recommendedUnits: 1.25, enteredUnits: 1.25)
        #expect(DoseComposer.composePhone(F.phone(correctionOnly), context: off).dose?.units == 1.25)
    }

    @Test func theScreenSizesNoDoseFromAnEntryOfTheOtherKind() {
        let off = F.context(pump: Self.pump())
        let grams = DoseComposer.recommend(.carbs(grams: 60), glucoseMgdl: 180, context: off)
        #expect(grams.foodNotTaken)
        #expect(!grams.displaysNumericDose)
        #expect(grams.units == 0)
        let units = DoseComposer.recommend(.insulin(units: 3), glucoseMgdl: 180, context: off)
        #expect(!units.foodNotTaken)
        #expect(units.units == 4.25)
        #expect(units.carbsGrams == 0)
    }

    /// After the bolus the IOB rises and the recompute for the same food drops. A resend under a new ID is
    /// still the same request, recognized by what the remote sent (the food's insulin and the glucose), as a
    /// carb dose is, and refused.
    @Test func theSameFoodResentAfterItRaisedIOBIsRefused() throws {
        let insulin = RemoteDoseRequest.Amount.calculator(food: .insulin(units: 3), estimateUnits: 4.25)
        let first = try #require(
            DoseComposer.composeRemote(F.remote(insulin), ledger: .init(), context: F.context(pump: Self.pump())).dose)
        var ledger = RemoteBolusLedger()
        _ = ledger.begin(first.request, now: F.now)
        ledger.markAccepted(first.request.ledgerKey, bolusId: 7, now: F.now)
        ledger.markDelivering(first.request.ledgerKey, now: F.now)
        ledger.markDelivered(first.request.ledgerKey, units: first.units, now: F.now)
        var pump = Self.pump()
        pump.insulinOnBoard = F.observed(4.75, age: 1)
        var settings = try #require(pump.bolusCalculator?.value)
        settings.insulinOnBoardUnits = 4.75
        pump.bolusCalculator = F.observed(settings, age: 1)
        // 3 U at 180 with 4.75 U on board: the correction is gone, 3.00 U.
        let resend = F.remote(.calculator(food: .insulin(units: 3), estimateUnits: 3), id: "watch-2")
        let context = F.context(pump: pump)
        #expect(DoseComposer.composeRemote(resend, ledger: ledger, context: context).refusal == .recentlyDelivered)
        #expect(DoseComposer.composeRemote(resend, ledger: .init(), context: context).dose?.units == 3)
    }

    @Test func aRemoteSendsTheFoodAsUnits() throws {
        let off = F.context(pump: Self.pump())
        let insulin = RemoteDoseRequest.Amount.calculator(food: .insulin(units: 3), estimateUnits: 4.25)
        let dose = try #require(
            DoseComposer.composeRemote(F.remote(insulin), ledger: .init(), context: off).dose)
        #expect(dose.units == 4.25)
        #expect(dose.request.carbsGrams == nil)
        #expect(dose.correctionGlucoseMgdl == 180)

        #expect(
            DoseComposer.composeRemote(F.remote(F.carbs(60, estimate: 7.25)), ledger: .init(), context: off).refusal
                == .carbEntryChanged(carbsOff: true))
        #expect(
            DoseComposer.composeRemote(F.remote(insulin), ledger: .init(), context: F.context()).refusal
                == .carbEntryChanged(carbsOff: false))
    }
}
