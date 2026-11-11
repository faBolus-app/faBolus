import Foundation
import PumpScript
import TandemLink
import TandemMessages
import Testing

@testable import PumpSession
@testable import faBolusCore

/// The calculator snapshot's bytes the confirmations are asked from: the insulin left (7), the last hour's
/// boluses (20), and the too-many-boluses flags (24 and 25).
@MainActor
@Suite struct DoseConfirmationReadTests {
    @Test func theReadsForADoseCarryWhatTheConfirmationsNeed() async throws {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.reservoirUnits = 1
            $0.bolusedLastHourMilliunits = 30_250
            $0.tooManyBolusesHourlyLimit = true
        })
        await rig.startHeld()
        let preparation = await rig.session.prepareDose()
        let settings = try #require(preparation.pump.bolusCalculator?.value)
        #expect(settings.insulinRemainingUnits == 1)
        #expect(settings.bolusedLastHourUnits == 30.25)
        #expect(settings.tooManyBoluses == .init(hourlyLimit: true, insulinOnBoard: false))
        rig.pump.tooManyBolusesHourlyLimit = false
        rig.pump.tooManyBolusesIOB = true
        let again = await rig.session.prepareDose()
        #expect(
            again.pump.bolusCalculator?.value.tooManyBoluses == .init(hourlyLimit: false, insulinOnBoard: true))
    }
}
