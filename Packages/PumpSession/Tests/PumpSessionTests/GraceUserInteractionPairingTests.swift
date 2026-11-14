import Foundation
import PumpScript
import TandemLink
import TandemMessages
import Testing

@testable import PumpSession
@testable import faBolusCore

/// CGM alert 32, the G7 grace period ending soon: t:connect reads CGM status B for the time left (below API
/// 4.1) and says about 2 hours or about 30 minutes in two steps.
@MainActor
@Suite struct GracePeriodTests {
    private func rig(api: (major: Int, minor: Int) = (4, 0)) async -> Rig {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.apiVersion = api
        })
        await rig.startHeld()
        return rig
    }

    private func graceAlert(_ rig: Rig) async -> PumpAlert? {
        await rig.session.state.alerts?.value.first { $0.kind == .cgmAlert && $0.id == 32 }
    }

    @Test func theAlertSaysHowLongIsLeft() async {
        let rig = await rig()
        rig.pump.graceSecondsLeft = 3600
        rig.pump.cgmAlertBitmap = 1 << 32
        rig.transport.qualifyingEvents(.cgmAlert)
        await rig.settle()
        #expect(rig.pump.arrivals(of: CgmStatusV2Request.self).count == 1)
        #expect(await graceAlert(rig)?.detail == "About 2 hours of the sensor's grace period are left.")
        #expect(await graceAlert(rig)?.title == "Grace period ending")
    }

    @Test func underThirtyFiveMinutesItIsAboutThirty() async {
        let rig = await rig()
        rig.pump.graceSecondsLeft = 1200
        rig.pump.cgmAlertBitmap = 1 << 32
        rig.transport.qualifyingEvents(.cgmAlert)
        await rig.settle()
        #expect(await graceAlert(rig)?.detail == "About 30 minutes of the sensor's grace period are left.")
    }

    /// The time left counts down from the read: a later alert read says the smaller step.
    @Test func theTimeLeftCountsDown() async {
        let rig = await rig()
        rig.pump.graceSecondsLeft = 2200
        rig.pump.cgmAlertBitmap = 1 << 32
        rig.transport.qualifyingEvents(.cgmAlert)
        await rig.settle()
        #expect(await graceAlert(rig)?.detail == "About 2 hours of the sensor's grace period are left.")
        await rig.run(for: 120)
        rig.transport.qualifyingEvents(.cgmAlert)
        await rig.settle()
        #expect(await graceAlert(rig)?.detail == "About 30 minutes of the sensor's grace period are left.")
        #expect(rig.pump.arrivals(of: CgmStatusV2Request.self).count == 1)
    }

    /// Read once for each raising of the alert, not on every alert read while it stays raised.
    @Test func itIsReadOncePerRaising() async {
        let rig = await rig()
        rig.pump.graceSecondsLeft = 3600
        rig.pump.cgmAlertBitmap = 1 << 32
        rig.transport.qualifyingEvents(.cgmAlert)
        await rig.settle()
        rig.transport.qualifyingEvents(.cgmAlert)
        await rig.settle()
        #expect(rig.pump.arrivals(of: CgmStatusV2Request.self).count == 1)
        rig.pump.cgmAlertBitmap = 0
        rig.transport.qualifyingEvents(.cgmAlert)
        await rig.settle()
        rig.pump.cgmAlertBitmap = 1 << 32
        rig.transport.qualifyingEvents(.cgmAlert)
        await rig.settle()
        #expect(rig.pump.arrivals(of: CgmStatusV2Request.self).count == 2)
    }

    /// Outside both of t:connect's windows, or with no grace period in the reply, the alert keeps its text.
    @Test func noTimeLeftKeepsTheAlertsOwnText() async {
        let rig = await rig()
        rig.pump.graceSecondsLeft = nil
        rig.pump.cgmAlertBitmap = 1 << 32
        rig.transport.qualifyingEvents(.cgmAlert)
        await rig.settle()
        #expect(await graceAlert(rig)?.detail == "The sensor's grace period ends soon.")
        #expect(PumpAlertLists.graceDetail(secondsLeft: 7501) == nil)
        #expect(PumpAlertLists.graceDetail(secondsLeft: 0) == nil)
    }

    /// At API 4.1 or later t:connect asks form C, which TandemKit doesn't have: nothing is read.
    @Test func atAPI4Point1NothingIsRead() async {
        let rig = await rig(api: (4, 1))
        rig.pump.cgmAlertBitmap = 1 << 32
        rig.transport.qualifyingEvents(.cgmAlert)
        await rig.settle()
        #expect(rig.pump.arrivals(of: CgmStatusV2Request.self).isEmpty)
    }
}

/// UserInteraction when the phone's bolus screen opens, at API 3.0 or later, as t:connect sends it.
@MainActor
@Suite struct BolusScreenUserInteractionTests {
    @Test func atAPI4ItGoesWhenTheBolusScreenOpens() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.apiVersion = (major: 4, minor: 0)
        })
        await rig.startHeld()
        await rig.session.bolusScreenOpened()
        #expect(rig.pump.arrivals(of: UserInteractionRequest.self).count == 1)
    }

    @Test func belowAPI3ItDoesnt() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        await rig.session.bolusScreenOpened()
        #expect(rig.pump.arrivals(of: UserInteractionRequest.self).isEmpty)
    }
}

@Suite struct PairingDroppedTests {
    @Test func aPairingThePumpDroppedSaysTheCodeMayBeWrong() {
        #expect(PumpSession.failure(.pairingDropped) == .pairingDropped)
    }
}
