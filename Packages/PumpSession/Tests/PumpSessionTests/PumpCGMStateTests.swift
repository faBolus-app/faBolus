import Foundation
import PumpScript
import TandemLink
import TandemMessages
import Testing

@testable import PumpSession
@testable import faBolusCore

/// The pump's word on its CGM reading, from its replies to the reads a dose makes: the home screen's CGM
/// alert and trend icons, the reading's status, and the calculator snapshot's auto-fill flag.
@MainActor
@Suite struct PumpCGMStateTests {
    private static let changes: [(String, (ScriptedPump) -> Void, PumpGlucoseCaution?)] = [
        ("no error", { _ in }, nil),
        ("a sensor state", { $0.cgmAlertIcon = 14 }, .sensorState(.sensorFailed)),
        ("warming up", { $0.cgmAlertIcon = 0 }, .sensorState(.warmingUp)),
        ("Check BG", { $0.trendIcon = 10 }, .checkBG),
        ("LOW", { $0.egvStatus = 2 }, .outOfRange(.low)),
        ("HIGH", { $0.egvStatus = 3 }, .outOfRange(.high)),
        ("auto-fill off", { $0.glucoseAutoFillAllowed = false }, .autoFillOff)
    ]

    @Test(arguments: 0..<7)
    func theReadsForADoseCarryThePumpsCaution(index: Int) async {
        let (_, change, caution) = Self.changes[index]
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        change(rig.pump)
        let preparation = await rig.session.prepareDose()
        #expect(preparation.pump.glucose?.value.mgdl == 120)
        #expect(preparation.pump.glucoseCaution(cgmStateReadSince: preparation.inputsRequestedAt) == caution)
    }

    /// The CGM state is kept when there's no reading too: it is why there's no number.
    @Test func theCGMStateIsKeptWithoutAReading() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.glucose = nil
            $0.cgmAlertIcon = 19
        })
        await rig.startHeld()
        let preparation = await rig.session.prepareDose()
        #expect(preparation.pump.glucose == nil)
        #expect(preparation.pump.cgmDisplay?.value == PumpCGMDisplay(state: .warmingUp, checkBG: false))
    }
}
