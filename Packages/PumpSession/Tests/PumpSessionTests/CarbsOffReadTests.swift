import Foundation
import PumpScript
import TandemLink
import TandemMessages
import Testing

@testable import PumpSession
@testable import faBolusCore

/// Carbs off on the pump: the calculator snapshot's carb entry (byte 13), and the bolus that goes with it.
@MainActor
@Suite struct CarbsOffReadTests {
    @Test func theReadsForADoseSayWhetherCarbsAreOn() async throws {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        #expect(try #require(await rig.session.prepareDose().pump.bolusCalculator?.value).carbsOff == false)
        rig.pump.carbEntryEnabled = false
        let settings = try #require(await rig.session.prepareDose().pump.bolusCalculator?.value)
        #expect(settings.carbEntryEnabled == false)
        #expect(settings.isUsable)
    }

    /// A dose with insulin entered for the food goes as any dose with no carbs does: no carb amount and no
    /// carb entry, the glucose it corrected from with it.
    @Test func aDoseWithTheFoodAsUnitsGoesWithNoCarbs() throws {
        let request = DoseRequest(
            id: "phone-1", origin: .phone, shape: .now(units: 4.25), carbsGrams: nil, bgMgdl: 180, foodInsulinUnits: 3)
        let dose = ComposedDose(
            request: request, calculatorIOBUnits: 0.5, correctionGlucoseMgdl: 180, calculatorCarbUnits: 3,
            usedIncludedStaleGlucose: false, notices: [])
        let c = try BolusCommands.make(dose, bolusId: 9, uptime: 0)
        #expect(c.carbEntry == nil)
        #expect(c.initiate.bolusCarbs == 0)
        #expect(c.initiate.bolusTypeBitmask == InitiateBolusRequest.bitFood2)
        #expect(c.bgEntry?.bg == 180)
    }
}
