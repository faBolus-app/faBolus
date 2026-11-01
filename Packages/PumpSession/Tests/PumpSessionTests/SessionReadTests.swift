import Foundation
import PumpScript
import TandemLink
import TandemMessages
import Testing

@testable import PumpSession
@testable import faBolusCore

@MainActor
@Suite struct SessionReadTests {
    @Test func reconnectsToTheStoredPairingAndReadsThePump() async {
        let rig = Rig()
        await rig.start()
        let state = await rig.session.state
        #expect(state.link == .connected)
        #expect(state.model == .tslimX2)
        #expect(state.insulinOnBoard?.value == 0.5)
        #expect(state.reservoirUnits?.value == 150)
        #expect(state.battery?.value == PumpBattery(percent: 80, isCharging: false))
        #expect(state.bolusState?.value == .noBolus)
        // The reading's time is the pump's, placed by the clock anchor: 60 s before now.
        let glucose = state.glucose
        #expect(glucose?.value == PumpGlucose(mgdl: 120, trend: .flat))
        if let measured = glucose?.measuredAt {
            #expect(abs(rig.clock.date.timeIntervalSince(measured) - 60) < 1.5)
        }
        let calculator = state.bolusCalculator?.value
        #expect(calculator?.carbRatio == 10)
        #expect(calculator?.correctionFactor == 40)
        #expect(calculator?.targetMgdl == 110)
        #expect(calculator?.maxBolusUnits == 25)
        // op-115's own IOB fills the calculator settings, so the composer can cross-check it with op-109.
        #expect(calculator?.insulinOnBoardUnits == 0.5)
        #expect(await rig.events.contains(.identified(.tslimX2)))
    }

    /// After authenticating the link sends only ApiVersion, PumpVersion and TimeSinceReset, and the session's
    /// own reads follow one at a time.
    @Test func theOnlyReadsBeforeReadyAreTheHandshake() async {
        let rig = Rig()
        await rig.start()
        let opcodes = rig.pump.arrivals.filter { $0.characteristic == .currentStatus }.map(\.opCode)
        #expect(
            Array(opcodes.prefix(3)) == [
                ApiVersionRequest.props.opCode, PumpVersionRequest.props.opCode, TimeSinceResetRequest.props.opCode
            ])
    }

    /// The pump's IOB is the one it displays: Mudaliar or Swan 6-hour by the model it reports (pumpx2's
    /// rule), the larger for a model it doesn't name. The old app always used Swan.
    @Test func iobFollowsThePumpsOwnModel() {
        // pumpx2 ControlIQIOBResponseTest: iobType 0, Mudaliar 192, Swan 161.
        let mudaliar = ControlIQIOBResponse(cargo: le32(192) + le32(14460) + le32(241) + le32(161) + [0])
        #expect(PumpReadings.displayedIOB(mudaliar) == 192)
        let swan = ControlIQIOBResponse(cargo: le32(192) + le32(14460) + le32(241) + le32(161) + [1])
        #expect(PumpReadings.displayedIOB(swan) == 161)
        let unknown = ControlIQIOBResponse(cargo: le32(150) + le32(0) + le32(0) + le32(161) + [7])
        #expect(PumpReadings.displayedIOB(unknown) == 161)
    }

    /// The G6 transmitter ID is read with CGMHardwareInfo (op-96), once a connection; the request that
    /// drew op-77 and a dropped link on P1 is never sent.
    @Test func readsTheCgmHardwareStringOnceAndNeverTheG6Request() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.start()
        await rig.run(for: 120, step: 15)
        #expect(await rig.session.state.cgmHardwareInfo?.value == "8KX21P")
        #expect(rig.pump.arrivals(of: CGMHardwareInfoRequest.self).count == 1)
        #expect(rig.pump.arrivals(of: GetG6TransmitterHardwareInfoRequest.self).isEmpty)
    }

    @Test func alertsAreReadEveryFifteenSecondsAndStatusEveryMinute() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.start()
        let alertsBefore = rig.pump.arrivals(of: AlertStatusRequest.self).count
        let iobBefore = rig.pump.arrivals(of: ControlIQIOBRequest.self).count
        await rig.run(for: 60, step: 5)
        #expect(rig.pump.arrivals(of: AlertStatusRequest.self).count - alertsBefore == 4)
        #expect(rig.pump.arrivals(of: ControlIQIOBRequest.self).count - iobBefore == 1)
    }

    /// P1 answers LoadStatus with op-77 and drops the link. The probe costs two drops (an error 0 and a
    /// drop is a strike, and it takes two), the result is kept with the pairing, and it is never sent again.
    @Test func anUnsupportedReadCostsTwoDropsAndIsNeverSentAgain() async {
        let rig = Rig()
        await rig.start()
        await rig.run(for: 180, step: 5)
        #expect(rig.pump.arrivals(of: LoadStatusRequest.self).count == 2)
        let drops = await rig.events.filter { $0 == .disconnected(.afterUnsupportedRequest(opcode: 20)) }
        #expect(drops.count == 2)
        let unit = TandemMessages.PumpUnit(serialNumber: 1693, armSoftwareVersion: 7, mspSoftwareVersion: 7)
        #expect(
            rig.store.load()?.support.entry(for: LoadStatusRequest(), unit: unit, model: .tslim, apiVersion: .v2_5)
                .status
                == .unsupported)
        // The cartridge state stays unknown, and a bolus is allowed with a notice.
        #expect(await rig.session.state.cartridgeReadiness == .unknown)
        #expect(await rig.session.state.link == .connected)
    }

    /// Around the time the next CGM reading is due, glucose is read every 10 s until it arrives.
    @Test func glucoseIsReadOftenAroundTheNextExpectedReading() async {
        let rig = Rig(configure: { $0.glucose = (120, 280) })  // the next reading is due in 20 s
        await rig.start()
        let before = rig.pump.arrivals(of: CurrentEGVGuiDataRequest.self).count
        await rig.run(for: 40, step: 5)
        #expect(rig.pump.arrivals(of: CurrentEGVGuiDataRequest.self).count - before >= 3)
    }

    /// A value the pump reported stays what it was, and goes unknown once its window passes, even while
    /// the session keeps running with the link down.
    @Test func valuesDecayOnTheSessionsWindowsWhenThePumpGoesQuiet() async {
        let rig = Rig()
        await rig.start()
        rig.transport.pumpWalksAway()
        await rig.settle()
        await rig.run(for: 7 * 60, step: 30)
        let state = await rig.session.state
        let windows = await rig.session.freshness
        let now = rig.clock.date
        #expect(state.link != .connected)
        #expect(state.reservoirUnits?.value == 150)
        #expect(state.reservoirUnitsIfFresh(thresholds: windows, now: now) == nil)
        #expect(state.batteryIfFresh(thresholds: windows, now: now) == nil)
        #expect(state.insulinOnBoardIfFresh(thresholds: windows, now: now) == nil)
        #expect(state.glucoseIfFresh(thresholds: windows, now: now) == nil)
    }

    /// A reading's pump time is placed by the measured offset between the clocks, so a pump clock an hour
    /// off the phone's time zone (a DST change nobody made on the pump) still gives the right time.
    @Test func pumpTimesArePlacedByTheMeasuredOffsetNotTheTimeZone() {
        let phone = Date(timeIntervalSince1970: 1_800_000_000)
        let anchor = PumpClockAnchor(pumpTime: 500_000_000, phoneTime: phone)
        #expect(anchor.date(forPumpTime: 500_000_000 - 300) == phone.addingTimeInterval(-300))
        #expect(anchor.pumpTime(at: phone.addingTimeInterval(90)) == 500_000_090)
    }
}

func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
