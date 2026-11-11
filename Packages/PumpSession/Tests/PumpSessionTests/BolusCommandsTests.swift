import Foundation
import TandemMessages
import Testing
@testable import faBolusCore

@testable import PumpSession

/// The bolus messages are byte-for-byte what Tandem's own app sent for the same bolus, so the pump's
/// records read as they would for a bolus from Tandem's app.
@Suite struct BolusCommandsTests {
    private func make(
        _ units: Double, bolusId: Int, carbs: Double? = nil, bg: Int? = nil, iob: Double? = nil,
        carbUnits: Double? = nil, origin: DoseRequest.Origin = .phone, uptime: UInt32 = 0
    ) throws -> BolusCommands {
        try BolusCommands.make(
            composed(units, origin: origin, carbs: carbs, bg: bg, iob: iob, carbUnits: carbUnits), bolusId: bolusId,
            uptime: uptime)
    }

    @Test func aDoseTypedInUnitsMatchesTandemsCapture() throws {
        let c = try make(1.0, bolusId: 10650)
        #expect(c.initiate.cargo == TandemAppRequests.initiate10650)
        #expect(c.bgEntry == nil)
        #expect(c.carbEntry == nil)
    }

    @Test func aCarbOnlyDoseMatchesTandemsCapture() throws {
        let c = try make(0.13, bolusId: 10652, carbs: 13, bg: 142, iob: 0, carbUnits: 0.13)
        #expect(c.initiate.cargo == TandemAppRequests.initiate10652)
        let iob = try make(0.11, bolusId: 10653, carbs: 11, bg: 161, iob: 0.13, carbUnits: 0.11)
        #expect(iob.initiate.cargo == TandemAppRequests.initiate10653)
    }

    /// Carbs with a correction on top: type bits 3, the dose split into the carbs' part and the rest.
    @Test func aCarbDoseWithACorrectionIsSplitAsTandemsAppSplitsIt() throws {
        let a = try make(0.77, bolusId: 10677, carbs: 5, bg: 185, iob: 0, carbUnits: 0.05)
        #expect(a.initiate.cargo == TandemAppRequests.initiate10677)
        let b = try make(0.76, bolusId: 10678, carbs: 3, bg: 186, iob: 0, carbUnits: 0.03)
        #expect(b.initiate.cargo == TandemAppRequests.initiate10678)
    }

    /// The glucose a dose corrected from goes with it from 20 to 600 mg/dL, the calculator's range; one
    /// outside it isn't sent.
    @Test(arguments: [(20, 20), (600, 600), (19, 0), (601, 0)])
    func theCorrectionGlucoseGoesFrom20To600(bg: Int, sent: Int) throws {
        let c = try make(0.77, bolusId: 10677, carbs: 5, bg: bg, iob: 0, carbUnits: 0.05)
        #expect(c.initiate.bolusBG == sent)
        #expect(c.bgEntry?.bg == (sent > 0 ? sent : nil))
    }

    @Test func theEntriesCarryThePumpsSecondsSinceBootAsTandemsAppSends() throws {
        let c = try make(
            0.77, bolusId: 10677, carbs: 5, bg: 185, iob: 0, carbUnits: 0.05, uptime: TandemAppRequests.uptime10677)
        #expect(c.carbEntry?.cargo == TandemAppRequests.carbEntry10677)
        #expect(c.bgEntry?.cargo == TandemAppRequests.bgEntry10677)
    }

    /// A dose the user changed from the calculator's has no carb part, so it is all food (the proven
    /// form), never a guessed split.
    @Test func aChangedCarbDoseIsAllFood() throws {
        let c = try make(1.2, bolusId: 9, carbs: 10, bg: 180, iob: 0.4, carbUnits: nil)
        #expect(c.initiate.bolusTypeBitmask == InitiateBolusRequest.bitFood1)
        #expect(c.initiate.foodVolume == 1200)
        #expect(c.initiate.correctionVolume == 0)
    }

    /// Below target the dose is under the carbs' part: all food, never more food than the dose.
    @Test func aDoseUnderTheCarbsPartIsAllFood() throws {
        let c = try make(0.8, bolusId: 9, carbs: 10, bg: 90, iob: 0, carbUnits: 0.8)
        #expect(c.initiate.bolusTypeBitmask == InitiateBolusRequest.bitFood1)
        #expect(c.initiate.foodVolume == 800)
        #expect(c.initiate.correctionVolume == 0)
    }

    /// 0 g from the phone and 0 g from a remote reach the pump identically.
    @Test func zeroCarbsMapsTheSameFromEverySurface() throws {
        let phone = try make(1.25, bolusId: 9, carbs: 0, bg: 200, iob: 0.5)
        let remote = try make(
            1.25, bolusId: 9, carbs: 0, bg: 200, iob: 0.5,
            origin: .remote(peerId: "garmin", sentAt: Date(timeIntervalSince1970: 0)))
        #expect(phone.initiate.cargo == remote.initiate.cargo)
        #expect(phone.initiate.bolusTypeBitmask == InitiateBolusRequest.bitFood2)
        #expect(phone.initiate.foodVolume == 0)
        #expect(phone.carbEntry == nil)
        let units = try make(1.25, bolusId: 9, carbs: nil, bg: 200, iob: 0.5)
        #expect(units.initiate.bolusTypeBitmask == phone.initiate.bolusTypeBitmask)
    }

    @Test func aDoseThePumpCantBeToldIsRefused() {
        #expect(throws: BolusCommands.Refusal.carbsOutOfRange) { try make(1, bolusId: 1, carbs: 1500) }
        #expect(throws: BolusCommands.Refusal.invalidAmount) { try make(.nan, bolusId: 1) }
        #expect(throws: BolusCommands.Refusal.invalidAmount) { try make(0, bolusId: 1) }
        let extended = ComposedDose(
            request: DoseRequest(
                id: "x", origin: .phone, shape: .extended(nowUnits: 1, laterUnits: 1, duration: 3600)),
            calculatorIOBUnits: nil, correctionGlucoseMgdl: nil, calculatorCarbUnits: nil,
            usedIncludedStaleGlucose: false, notices: [])
        #expect(throws: BolusCommands.Refusal.extendedNotSupported) {
            try BolusCommands.make(extended, bolusId: 1, uptime: 0)
        }
    }
}
