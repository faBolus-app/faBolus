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
        await rig.startHeld()
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
        await rig.startHeld()
        let alertsBefore = rig.pump.arrivals(of: AlertStatusRequest.self).count
        let iobBefore = rig.pump.arrivals(of: ControlIQIOBRequest.self).count
        await rig.run(for: 60, step: 5)
        #expect(rig.pump.arrivals(of: AlertStatusRequest.self).count - alertsBefore == 4)
        #expect(rig.pump.arrivals(of: ControlIQIOBRequest.self).count - iobBefore == 1)
    }

    /// On every connection the essential reads go first, in order, and nothing else goes until the
    /// connection has held (10 s), so a new connection never starts with a burst. The alert, status and
    /// settings reads follow the hold.
    @Test func theEssentialReadsGoFirstAndTheRestWaitForTheHold() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.start()
        // After the link's handshake (ApiVersion, PumpVersion, TimeSinceReset).
        let reads = rig.pump.arrivals.filter { $0.characteristic == .currentStatus }.map(\.opCode).dropFirst(3)
        #expect(
            Array(reads) == [
                TimeSinceResetRequest.props.opCode, CurrentBolusStatusRequest.props.opCode,
                BolusCalcDataSnapshotRequest.props.opCode, ControlIQIOBRequest.props.opCode,
                CurrentEGVGuiDataRequest.props.opCode
            ])
        let afterTheHold: [any TandemMessages.Message.Type] = [
            AlertStatusRequest.self, InsulinStatusRequest.self, CurrentBasalStatusRequest.self
        ]
        await rig.run(for: 9, step: 1)
        for type in afterTheHold { #expect(rig.pump.arrivals(of: type).isEmpty) }
        await rig.run(for: 2, step: 1)
        for type in afterTheHold { #expect(rig.pump.arrivals(of: type).count == 1) }
    }

    /// What changes rarely (basal, limits, Control-IQ, the CGM session) is read every 10 minutes.
    @Test func settingsAreReadEveryTenMinutes() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        #expect(rig.pump.arrivals(of: CurrentBasalStatusRequest.self).count == 1)
        await rig.run(for: 580, step: 20)
        #expect(rig.pump.arrivals(of: CurrentBasalStatusRequest.self).count == 1)
        await rig.run(for: 20, step: 5)
        #expect(rig.pump.arrivals(of: CurrentBasalStatusRequest.self).count == 2)
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

    /// The developer retest setting lists a read the pump was recorded not to answer, by name, and
    /// retesting it sends it again.
    @Test func aRejectedReadIsListedForRetestAndRetestSendsItAgain() async {
        let rig = Rig(configure: { $0.unsupportedReads = [MessageKey(LoadStatusRequest.self)] })
        await rig.start()
        await rig.run(for: 180, step: 5)
        let listed = await rig.session.retestableCommands()
        #expect(listed.map(\.name) == ["LoadStatusRequest"])
        #expect(listed.first?.reason == .unsupported)
        let sent = rig.pump.arrivals(of: LoadStatusRequest.self).count
        rig.pump.unsupportedReads = []
        await rig.session.retest(MessageKey(LoadStatusRequest.self))
        #expect(await rig.session.retestableCommands().isEmpty)
        // Saved with the pairing at once, so the next launch or reconnect doesn't bring it back.
        let unit = TandemMessages.PumpUnit(serialNumber: 1693, armSoftwareVersion: 7, mspSoftwareVersion: 7)
        #expect(
            rig.store.load()?.support.entry(for: LoadStatusRequest(), unit: unit, model: .tslim, apiVersion: .v2_5)
                .status == .untested)
        await rig.run(for: 180, step: 5)
        #expect(rig.pump.arrivals(of: LoadStatusRequest.self).count > sent)
    }

    /// One error-0 drop is a strike, not a verdict: the read is listed as suspected, under its name.
    @Test func aReadWithOneStrikeIsListedAsSuspected() async {
        let rig = Rig(configure: { $0.unsupportedReads = [MessageKey(LoadStatusRequest.self)] })
        await rig.start()
        // Until the first try has drawn its error and the drop after it, before the reconnect tries again.
        for _ in 0..<60 where await !rig.events.contains(.disconnected(.afterUnsupportedRequest(opcode: 20))) {
            await rig.run(for: 0.5, step: 0.5)
        }
        #expect(rig.pump.arrivals(of: LoadStatusRequest.self).count == 1)
        let listed = await rig.session.retestableCommands()
        #expect(listed.map(\.name) == ["LoadStatusRequest"])
        #expect(listed.first?.reason == .suspected)
    }

    @Test func everyCommandTheSessionSendsHasAName() {
        #expect(PumpSession.commandNames[MessageKey(DismissNotificationRequest.self)] == "DismissNotificationRequest")
        #expect(PumpSession.commandNames[MessageKey(LoadStatusRequest.self)] == "LoadStatusRequest")
    }

    /// Control-IQ's high alert (#50), which TandemKit leaves unnamed, reaches every surface with Tandem's
    /// own copy rather than "Alert 50"; a named alert keeps its name.
    @Test func controlIQsHighAlertGetsTandemsCopy() async throws {
        let rig = Rig(configure: { $0.alertBitmap = (1 << 50) | (1 << 7) })
        await rig.startHeld()
        let alerts = try #require(await rig.session.state.alerts?.value)
        let high = try #require(alerts.first { $0.id == 50 })
        #expect(high.title == "Control-IQ high")
        #expect(high.detail.contains("Test your blood glucose"))
        let named = try #require(alerts.first { $0.id == 7 })
        #expect(named.title != "Alert 7")
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
        await rig.startHeld()
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

/// The pump's comms-suspended notice (qualifying-event bit 19). What it means isn't known; each notice
/// pauses every send for 5 s, as controlX2 does, the cancel included (the owner's choice).
@MainActor
@Suite struct CommsSuspendedPauseTests {
    /// A read asked for while paused goes once the 5 s are up.
    @Test func aNoticeHoldsEverySendForFiveSeconds() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        rig.transport.qualifyingEvents(.pumpCommunicationsSuspended)
        await rig.settle()
        let before = rig.pump.arrivals.count
        let session = rig.session
        let refresh = Task { await session.refreshGlucose() }
        await rig.run(for: 4.5)
        #expect(rig.pump.arrivals.count == before)
        await rig.run(for: 1)
        await refresh.value
        #expect(rig.pump.arrivals(of: CurrentEGVGuiDataRequest.self).count > 0)
        #expect(rig.pump.arrivals.count > before)
    }

    @Test func aCancelWaitsOutThePauseToo() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        _ = await rig.session.deliver(composed(2.0))
        rig.transport.qualifyingEvents(.pumpCommunicationsSuspended)
        await rig.settle()
        let session = rig.session
        let cancel = Task { await session.cancelBolus() }
        await rig.run(for: 4.5)
        #expect(rig.pump.arrivals(of: CancelBolusRequest.self).isEmpty)
        await rig.run(for: 1)
        #expect(await cancel.value == .cancelled)
        #expect(rig.pump.arrivals(of: CancelBolusRequest.self).count == 1)
    }

    @Test func aBolusConfirmedDuringThePauseStartsAfterIt() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        rig.transport.qualifyingEvents(.pumpCommunicationsSuspended)
        await rig.settle()
        let session = rig.session
        let delivery = Task { await session.deliver(composed(1.0)) }
        await rig.run(for: 4.5)
        #expect(rig.pump.arrivals.filter { $0.characteristic == .control }.isEmpty)
        await rig.run(for: 2)
        guard case .started(_, .delivering) = await delivery.value else {
            Issue.record("expected delivering")
            return
        }
    }

    /// Each notice pauses from when it arrives.
    @Test func aSecondNoticeRestartsThePause() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        rig.transport.qualifyingEvents(.pumpCommunicationsSuspended)
        await rig.settle()
        let before = rig.pump.arrivals.count
        await rig.run(for: 3)
        rig.transport.qualifyingEvents(.pumpCommunicationsSuspended)
        await rig.settle()
        let session = rig.session
        let refresh = Task { await session.refreshGlucose() }
        await rig.run(for: 4.5)
        #expect(rig.pump.arrivals.count == before)
        await rig.run(for: 1)
        await refresh.value
        #expect(rig.pump.arrivals.count > before)
    }

    /// The pause belongs to the connection that reported it: a new one reads at once.
    @Test func thePauseEndsWithTheConnection() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        rig.transport.qualifyingEvents(.pumpCommunicationsSuspended)
        await rig.settle()
        let before = rig.pump.arrivals(of: ControlIQIOBRequest.self).count
        rig.transport.drop()
        await rig.run(for: 3)
        #expect(await rig.session.state.link == .connected)
        #expect(rig.pump.arrivals(of: ControlIQIOBRequest.self).count > before)
    }

    /// While paused the session ticks at its busy rhythm, so sends go on when the pause ends rather than at
    /// the next idle tick; after it, the idle rhythm comes back.
    @Test func theSessionTicksOftenWhilePaused() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        let config = PumpSession.Configuration()
        #expect(await rig.session.tickInterval == config.idleTick)
        rig.transport.qualifyingEvents(.pumpCommunicationsSuspended)
        await rig.settle()
        #expect(await rig.session.tickInterval == config.busyTick)
        await rig.run(for: 6)
        #expect(await rig.session.tickInterval == config.idleTick)
    }

    /// Any other notice only brings its reads forward.
    @Test func anotherNoticeDoesntPause() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        let before = rig.pump.arrivals(of: AlertStatusRequest.self).count
        rig.transport.qualifyingEvents(.alert)
        await rig.settle()
        #expect(rig.pump.arrivals(of: AlertStatusRequest.self).count == before + 1)
    }
}

func le32(_ v: UInt32) -> [UInt8] { (0..<4).map { UInt8((v >> (8 * $0)) & 0xFF) } }
func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF)] }
