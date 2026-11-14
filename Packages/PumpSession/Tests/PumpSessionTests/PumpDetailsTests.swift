import Foundation
import PumpScript
import TandemMessages
import Testing
import faBolusCore

@testable import PumpSession

/// Display-only details t:connect's dashboard shows: the home screen's status and bolus icons, the time left
/// of insulin action, and the CGM session's times. The icons' bytes are pumpX2's and their meaning in each pump
/// state is unconfirmed.
@Suite struct PumpDetailsReadingTests {
    private var state = PumpState()
    private var alerts = PumpAlertLists()
    private var basal = PumpBasalParts()
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private mutating func apply(_ message: any TandemMessages.Message, anchor: PumpClockAnchor? = nil) {
        _ = PumpReadings.apply(
            message, to: &state, alerts: &alerts, basal: &basal, context: .init(receivedAt: now, anchor: anchor))
    }

    private func mirror(status0: UInt8 = 200, status1: UInt8 = 200, bolus: UInt8 = 200) -> HomeScreenMirrorResponse {
        HomeScreenMirrorResponse(cargo: [4, 255, status0, status1, bolus, 0, 0, 0, 1])
    }

    @Test mutating func theBolusAndStatusIconsAreRead() {
        apply(mirror(status0: 4, status1: 1, bolus: 1))
        #expect(
            state.statusIcons?.value
                == PumpStatusIcons(bolus: .autoBolus, transmitter: .outOfRange, calibrationDue: true))
        apply(mirror(status0: 1, status1: 0, bolus: 0))
        #expect(state.statusIcons?.value == PumpStatusIcons(bolus: .bolus, transmitter: .inRange))
        // Hidden, a lock or an unknown id shows nothing.
        for bolus: UInt8 in [2, 3, 200, 9] {
            apply(mirror(status0: 200, status1: 200, bolus: bolus))
            #expect(state.statusIcons?.value == PumpStatusIcons())
        }
    }

    private func iob(type: UInt8, secondsLeft: UInt32) -> ControlIQIOBResponse {
        ControlIQIOBResponse(cargo: le32(1500) + le32(secondsLeft) + le32(3000) + le32(1500) + [type])
    }

    /// Only the Mudaliar model's time left is the pump's, as t:connect shows it.
    @Test mutating func theTimeLeftOfInsulinIsReadForTheMudaliarModelOnly() {
        apply(iob(type: 0, secondsLeft: 5400))
        #expect(state.insulinActionTimeLeft?.value == 5400)
        apply(iob(type: 1, secondsLeft: 5400))
        #expect(state.insulinActionTimeLeft == nil)
        #expect(state.insulinOnBoard?.value == 1.5)
    }

    private func cgmStatus(calibratedAt: UInt32, startedAt: UInt32) -> CGMStatusResponse {
        CGMStatusResponse(cargo: [1] + le32(calibratedAt) + le32(startedAt) + [0])
    }

    @Test mutating func theSessionTimesArePlacedByThePumpClock() {
        let anchor = PumpClockAnchor(pumpTime: 500_000_000, phoneTime: now)
        apply(cgmStatus(calibratedAt: 500_000_000 - 3600, startedAt: 500_000_000 - 86400), anchor: anchor)
        #expect(
            state.cgmSessionTimes?.value
                == PumpCGMSessionTimes(
                    sensorStarted: now.addingTimeInterval(-86400), lastCalibration: now.addingTimeInterval(-3600)))
        // 0 is unset.
        apply(cgmStatus(calibratedAt: 0, startedAt: 500_000_000 - 86400), anchor: anchor)
        #expect(state.cgmSessionTimes?.value.lastCalibration == nil)
        // Without an anchor neither time can be placed.
        apply(cgmStatus(calibratedAt: 500_000_000 - 3600, startedAt: 500_000_000 - 86400))
        #expect(state.cgmSessionTimes?.value == PumpCGMSessionTimes(sensorStarted: nil, lastCalibration: nil))
        #expect(state.cgmSessionActive?.value == true)
    }
}

/// Through the session, from what the test pump reports.
@MainActor
@Suite struct PumpDetailsSessionTests {
    @Test func theIconsAndTheTimeLeftComeFromTheirReplies() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        rig.pump.bolusIcon = 1
        rig.pump.statusIcon1 = 1
        rig.pump.insulinTimeLeftSeconds = 5400
        rig.pump.cgmSensorStartedAt = rig.pump.wallClockAtStart - 86400
        await rig.startHeld()
        let state = await rig.session.state
        #expect(state.statusIcons?.value == PumpStatusIcons(bolus: .autoBolus, calibrationDue: true))
        #expect(state.insulinActionTimeLeft?.value == 5400)
        let started = state.cgmSessionTimes?.value.sensorStarted
        let read = state.cgmSessionTimes?.receivedAt
        if let started, let read {
            #expect(abs(read.timeIntervalSince(started) - 86400) < 120)
        } else {
            Issue.record("the sensor start wasn't placed")
        }
        #expect(state.cgmSessionTimes?.value.lastCalibration == nil)
    }
}
