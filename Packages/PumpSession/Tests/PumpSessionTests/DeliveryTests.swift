import Foundation
import PumpScript
import TandemLink
import TandemMessages
import Testing

@testable import PumpSession
@testable import faBolusCore

private let key = RemoteBolusLedger.Key(peerId: "phone", requestId: "phone-1")

/// Old history records, an hour before the scripted pump's clock starts, so a search can reach back past
/// a bolus's acceptance.
@MainActor
private func addOldHistory(_ pump: ScriptedPump, count: Int = 20) {
    for i in 0..<count {
        pump.appendHistory(
            typeId: 16, at: pump.wallClockAtStart - 3600 + UInt32(i * 60),
            body: le16(120) + [UInt8](repeating: 0, count: 14))
    }
}

@MainActor
@Suite struct DeliveryReplayTests {
    /// A whole delivery replayed from the capture of Tandem's app delivering bolus 3 on a t:slim X2:
    /// permission, initiate, the status going requesting → delivering → done, the last-bolus record, and
    /// the history records. Signed replies are the captured cargos, signed with the scripted pump's key.
    @Test func aCapturedSuccessfulDeliveryReplaysThroughTheSession() async throws {
        let rig = Rig(configure: { p in
            p.wallClockAtStart = CapturedBolus3.pumpClock
            p.nextBolusId = CapturedBolus3.bolusId
            p.unsupportedReads = []
        })
        await rig.startHeld()
        let pump = rig.pump
        pump.nextAnswers[MessageKey(BolusPermissionRequest.self)] = [.cargo(CapturedBolus3.permission)]
        pump.nextAnswers[MessageKey(InitiateBolusRequest.self)] = [.cargo(CapturedBolus3.initiate)]
        pump.nextAnswers[MessageKey(CurrentBolusStatusRequest.self)] = CapturedBolus3.status.map { .cargo($0) }
        pump.nextAnswers[MessageKey(LastBolusStatusV2Request.self)] = [.cargo(CapturedBolus3.lastBolus)]
        pump.nextAnswers[MessageKey(ControlIQIOBRequest.self)] = [.cargo(CapturedBolus3.iob)]

        let result = await rig.session.deliver(composed(1.0))
        #expect(result == .started(key, .delivering))
        await rig.run(for: 6)
        #expect(await rig.session.ledger.ledger.outcome(key) == .delivered(units: 1.0))
        #expect(await rig.outcomes(key) == [.requested, .accepted, .delivering, .delivered(units: 1.0)])
        #expect(await rig.session.ledger.block == nil)

        // On CONTROL: permission, then InitiateBolus, the pump clock read before each.
        let control = pump.arrivals.filter { $0.characteristic == .control }.map(\.opCode)
        #expect(control == [BolusPermissionRequest.props.opCode, InitiateBolusRequest.props.opCode])
        let initiate = try #require(pump.arrivals(of: InitiateBolusRequest.self).first)
        #expect(initiate.cargo == TandemAppRequests.initiate10650.replacing([0x9a, 0x29], with: [0x03, 0x00]))

        // Then the history: written to the store and shown in the logbook.
        pump.loadHistory(CapturedBolus3.historyRecords)
        let session = rig.session
        let sync = Task { await session.syncHistory() }
        await rig.run(for: 6)
        await rig.value(of: sync)
        let batches = await rig.sink.batches
        #expect(batches.flatMap(\.boluses).map(\.units) == [1.0])
        #expect(await rig.session.historyEvents.contains { $0.title == "Bolus delivered" && $0.detail == "1.00 U" })
        // 4632-4639 weren't captured: the records either side are credited, and the gap is asked for again
        // by the next sync.
        #expect(rig.store.load()?.coverage.ranges == [4620...4631, 4640...4642])
    }

    /// The pump refuses permission (P1 has no cartridge): refused, nothing that delivers is sent, and new
    /// boluses aren't blocked.
    @Test func aRefusedPermissionSendsNothingThatDelivers() async {
        let rig = Rig(configure: { $0.cartridgeLoaded = false })
        await rig.startHeld()
        let result = await rig.session.deliver(composed(1.0))
        guard case .started(_, .refused) = result else {
            Issue.record("expected refused, got \(result)")
            return
        }
        #expect(rig.pump.arrivals(of: InitiateBolusRequest.self).isEmpty)
        #expect(await rig.session.ledger.block == nil)
    }

    /// The link drops with InitiateBolus out and the pump delivering it: unknown, blocking, until history
    /// on the next connection shows how much went in.
    @Test func aDropMidDeliveryIsUnknownThenSettledFromHistory() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        rig.pump.nextAnswers[MessageKey(InitiateBolusRequest.self)] = [.drop(acted: true)]
        let result = await rig.session.deliver(composed(1.0))
        guard case .started(_, .unknown) = result else {
            Issue.record("expected unknown, got \(result)")
            return
        }
        guard case .unknownOutcome = await rig.session.ledger.block else {
            Issue.record("an unknown outcome must block")
            return
        }
        await rig.run(for: 60, step: 1)
        #expect(await rig.session.ledger.ledger.outcome(key) == .delivered(units: 1.0))
        #expect(await rig.session.ledger.block == nil)
        #expect(rig.pump.arrivals(of: InitiateBolusRequest.self).count == 1)
    }

    /// The link drops with InitiateBolus out and the pump never got it: unknown until history, reaching
    /// back past the acceptance, shows no such bolus; then failed, and bolusing is free again.
    @Test func aDropBeforeThePumpActedIsSettledAsNeverDelivered() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            addOldHistory($0)
        })
        await rig.startHeld()
        rig.pump.nextAnswers[MessageKey(InitiateBolusRequest.self)] = [.drop(acted: false)]
        _ = await rig.session.deliver(composed(1.0))
        await rig.run(for: 60, step: 1)
        #expect(
            await rig.session.ledger.ledger.outcome(key) == .failed(reason: RemoteBolusLedger.absentFromHistoryReason))
        #expect(await rig.session.ledger.block == nil)
        #expect(rig.pump.arrivals(of: InitiateBolusRequest.self).count == 1)
    }

    /// The pump records granting the permission (a type-297 record naming the bolus, as in the capture of
    /// bolus 3). That isn't the bolus starting: with nothing else naming it, it never started.
    @Test func aPermissionRecordAloneDoesntMakeTheBolusPresent() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            addOldHistory($0)
        })
        await rig.startHeld()
        rig.pump.nextAnswers[MessageKey(InitiateBolusRequest.self)] = [.drop(acted: false)]
        // The record the pump would write for bolus 10650, the next ID it grants.
        rig.pump.appendHistory(typeId: 297, body: le16(10650) + [0, 0, 0, 0])
        let session = rig.session
        let delivery = Task { await session.deliver(composed(1.0)) }
        #expect(await rig.until { rig.pump.arrivals(of: InitiateBolusRequest.self).count == 1 })
        await rig.run(for: 60, step: 1)
        _ = await rig.value(of: delivery)
        #expect(
            await rig.session.ledger.ledger.outcome(key) == .failed(reason: RemoteBolusLedger.absentFromHistoryReason))
    }

    /// A record showing the pump started the bolus keeps it from being called absent.
    @Test func anInitiateRecordKeepsItFromBeingAbsent() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            addOldHistory($0)
        })
        await rig.startHeld()
        rig.pump.nextAnswers[MessageKey(InitiateBolusRequest.self)] = [.drop(acted: false)]
        // The record the pump would write for bolus 10650, the next ID it grants.
        rig.pump.appendHistory(typeId: 298, body: le16(10650) + [0, 0, 0, 0])
        let session = rig.session
        let delivery = Task { await session.deliver(composed(1.0)) }
        #expect(await rig.until { rig.pump.arrivals(of: InitiateBolusRequest.self).count == 1 })
        await rig.run(for: 60, step: 1)
        _ = await rig.value(of: delivery)
        #expect(await rig.session.ledger.ledger.outcome(key)?.isUnknown == true)
    }

    /// History that doesn't reach back past the acceptance can't show a bolus absent: it stays unknown.
    @Test func historyThatDoesntReachBackLeavesItUnknown() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        rig.pump.nextAnswers[MessageKey(InitiateBolusRequest.self)] = [.drop(acted: false)]
        _ = await rig.session.deliver(composed(1.0))
        await rig.run(for: 60, step: 1)
        #expect(await rig.session.ledger.ledger.outcome(key)?.isUnknown == true)
    }
}

/// A crash or a failed save between recording the bolus and InitiateBolus never delivers unrecorded.
@MainActor
@Suite struct ReservationTests {
    @Test func aRequestThatCantBeSavedSendsNothing() async {
        let store = MemoryLedgerStore()
        store.failSaves = [1]
        let rig = Rig(ledgerStore: store)
        await rig.startHeld()
        #expect(await rig.session.deliver(composed(1.0)) == .notStarted(.notRecorded))
        #expect(rig.pump.arrivals.filter { $0.characteristic == .control }.isEmpty)
    }

    /// The bolus ID couldn't be saved after the pump granted it: InitiateBolus is never sent, and the
    /// permission is released.
    @Test func anAcceptanceThatCantBeSavedNeverSendsInitiate() async {
        let store = MemoryLedgerStore()
        store.failSaves = [2]
        let rig = Rig(ledgerStore: store)
        await rig.startHeld()
        // The release is an untested write: it waits for the connection to hold, so time has to move.
        let session = rig.session
        let delivery = Task { await session.deliver(composed(1.0)) }
        await rig.run(for: 15, step: 1)
        let result = await rig.value(of: delivery)
        guard case .started(_, .failed) = result else {
            Issue.record("expected failed, got \(result)")
            return
        }
        #expect(rig.pump.arrivals(of: InitiateBolusRequest.self).isEmpty)
        #expect(rig.pump.arrivals(of: BolusPermissionReleaseRequest.self).count == 1)
        #expect(rig.pump.released == [10650])
    }

    /// The app died after saving the bolus ID and before InitiateBolus went out. On relaunch the bolus is
    /// unknown and blocks; nothing is resent; history shows it never started, and only then is it failed.
    @Test func aCrashAfterTheReservationRestartsBlockedAndNeverResends() async {
        var saved = RemoteBolusLedger()
        let request = DoseRequest(id: "phone-1", origin: .phone, shape: .now(units: 1.0))
        _ = saved.begin(request, now: Date(timeIntervalSince1970: 1_800_000_000))
        saved.markAccepted(
            key, bolusId: 10650, pumpKey: "tandem|1693", pumpClock: 512_442_842,
            now: Date(timeIntervalSince1970: 1_800_000_000))
        let rig = Rig(
            ledger: saved,
            configure: {
                $0.unsupportedReads = []
                addOldHistory($0)
            })
        #expect(await rig.ledger.ledger.outcome(key)?.isUnknown == true)
        guard case .unknownOutcome = await rig.ledger.block else {
            Issue.record("the relaunch must start blocked")
            return
        }
        await rig.startHeld()
        await rig.run(for: 30, step: 1)
        #expect(
            await rig.session.ledger.ledger.outcome(key) == .failed(reason: RemoteBolusLedger.absentFromHistoryReason))
        #expect(rig.pump.arrivals(of: InitiateBolusRequest.self).isEmpty)
        #expect(await rig.session.ledger.block == nil)
    }

    /// The same crash, but the pump's log has restarted since (its newest record is older than one the phone
    /// holds): the new log reaching back past the acceptance can't show the bolus never started, so it stays
    /// unknown, across a relaunch too.
    @Test func aCrashBeforeThePumpsLogRestartedStaysUnknown() async {
        var saved = RemoteBolusLedger()
        let request = DoseRequest(id: "phone-1", origin: .phone, shape: .now(units: 1.0))
        _ = saved.begin(request, now: Date(timeIntervalSince1970: 1_800_000_000))
        saved.markAccepted(
            key, bolusId: 10650, pumpKey: "tandem|1693", pumpClock: 512_442_842,
            now: Date(timeIntervalSince1970: 1_800_000_000))
        var held = PumpSessionRecord(pairing: Rig.pairing)
        held.coverage = HistoryCoverage(ranges: [1000...5000])
        let rig = Rig(
            ledger: saved, record: held,
            configure: {
                $0.unsupportedReads = []
                addOldHistory($0)
            })
        await rig.startHeld()
        await rig.run(for: 30, step: 1)
        #expect(await rig.session.ledger.ledger.outcome(key)?.isUnknown == true)
        #expect(rig.store.load()?.beforeHistoryRestart == [key])
        // The log was fetched again from the restart, and a later search still leaves the bolus unknown.
        #expect(rig.store.load()?.coverage.ranges == [rig.pump.firstHeldSequence!...rig.pump.lastSequence!])
        await rig.run(for: 5 * 60, step: 5)
        #expect(await rig.session.ledger.ledger.outcome(key)?.isUnknown == true)
    }

    /// The same crash with history that can't settle it: it stays unknown and keeps blocking.
    @Test func aCrashHistoryCantSettleKeepsBlocking() async {
        var saved = RemoteBolusLedger()
        let request = DoseRequest(id: "phone-1", origin: .phone, shape: .now(units: 1.0))
        _ = saved.begin(request, now: Date(timeIntervalSince1970: 1_800_000_000))
        saved.markAccepted(
            key, bolusId: 10650, pumpKey: "tandem|1693", pumpClock: 512_442_842,
            now: Date(timeIntervalSince1970: 1_800_000_000))
        let rig = Rig(ledger: saved, configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        let other = await rig.session.deliver(composed(0.5, id: "phone-2"))
        guard case .notStarted(.blocked(.unknownOutcome)) = other else {
            Issue.record("expected the unknown outcome to block, got \(other)")
            return
        }
        #expect(rig.pump.arrivals(of: InitiateBolusRequest.self).isEmpty)
    }

    /// The same crash, but the pump did get InitiateBolus: history shows it delivered, with the amount.
    @Test func aCrashAfterThePumpGotTheBolusIsSettledDelivered() async {
        var saved = RemoteBolusLedger()
        let request = DoseRequest(id: "phone-1", origin: .phone, shape: .now(units: 1.0))
        _ = saved.begin(request, now: Date(timeIntervalSince1970: 1_800_000_000))
        saved.markAccepted(
            key, bolusId: 10650, pumpKey: "tandem|1693", pumpClock: 512_442_842,
            now: Date(timeIntervalSince1970: 1_800_000_000))
        let rig = Rig(
            ledger: saved,
            configure: { p in
                p.unsupportedReads = []
                p.appendHistory(
                    typeId: 20,
                    body: ScriptedPump.bolusCompletedBody(
                        bolusId: 10650, completionStatus: 3, iob: 1, delivered: 1.0, requested: 1.0))
            })
        await rig.startHeld()
        await rig.run(for: 10, step: 1)
        #expect(await rig.session.ledger.ledger.outcome(key) == .delivered(units: 1.0))
    }
}

/// Cancel is never blocked.
@MainActor
@Suite struct CancelTests {
    @Test func cancelStopsADeliveringBolusAndTheOutcomeIsWhatWentIn() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        _ = await rig.session.deliver(composed(2.0))
        await rig.run(for: rig.pump.pendingSeconds + 5)
        #expect(await rig.session.cancelBolus() == .cancelled)
        await rig.run(for: 3)
        guard case .stopped(let delivered, let requested) = await rig.session.ledger.ledger.outcome(key) else {
            Issue.record("expected stopped")
            return
        }
        #expect(delivered > 0 && delivered < 2.0)
        #expect(requested == 2.0)
    }

    /// A cancel before InitiateBolus is sent stops the delivery: no InitiateBolus, the permission released.
    @Test func cancelBeforeInitiateStopsTheDelivery() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        rig.pump.answers[MessageKey(RemoteBgEntryRequest.self)] = .silent
        let session = rig.session
        let delivery = Task { await session.deliver(composed(1.0, bg: 180)) }
        #expect(await rig.until { rig.pump.arrivals(of: RemoteBgEntryRequest.self).count == 1 })
        #expect(await session.cancelBolus() == .stoppedBeforeStart)
        await rig.run(for: 62)
        let result = await rig.value(of: delivery)
        #expect(result == .started(key, .failed(reason: PumpSession.cancelledBeforeStartReason)))
        #expect(rig.pump.arrivals(of: InitiateBolusRequest.self).isEmpty)
        #expect(rig.pump.released.count == 1)
    }

    /// A cancel made while InitiateBolus is out reaches the pump after it, never before.
    @Test func aCancelNeverOvertakesTheInitiateItStops() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        rig.pump.answers[MessageKey(InitiateBolusRequest.self)] = .silent
        let session = rig.session
        let delivery = Task { await session.deliver(composed(1.0)) }
        #expect(await rig.until { rig.pump.arrivals(of: InitiateBolusRequest.self).count == 1 })
        let cancel = Task { await session.cancelBolus() }
        await rig.run(for: 62)
        _ = await rig.value(of: delivery)
        _ = await rig.value(of: cancel)
        let control = rig.pump.arrivals.filter { $0.characteristic == .control }.map(\.opCode)
        let initiate = control.firstIndex(of: InitiateBolusRequest.props.opCode)
        let cancelled = control.firstIndex(of: CancelBolusRequest.props.opCode)
        #expect(initiate != nil && cancelled != nil)
        if let initiate, let cancelled { #expect(initiate < cancelled) }
    }

    /// After a relaunch the app has no bolus of its own in hand, and an unknown outcome blocks new boluses:
    /// the cancel still reads the pump's active bolus and stops it.
    @Test func cancelWorksWithNoTrackedBolusAndWhileBolusingIsBlocked() async {
        var saved = RemoteBolusLedger()
        let request = DoseRequest(id: "old", origin: .phone, shape: .now(units: 1.0))
        _ = saved.begin(request)
        saved.markAccepted(request.ledgerKey, bolusId: 77, pumpKey: "tandem|1693")
        let rig = Rig(
            ledger: saved,
            configure: {
                $0.unsupportedReads = []
                $0.startBolus(id: 10650, milliunits: 5000)
            })
        await rig.startHeld()
        guard case .unknownOutcome = await rig.session.ledger.block else {
            Issue.record("expected bolusing blocked")
            return
        }
        #expect(await rig.session.cancelBolus() == .cancelled)
        #expect(rig.pump.arrivals(of: CancelBolusRequest.self).count == 1)
        #expect(rig.pump.activeBolus == nil)
    }

    /// An untested command (DismissNotification on P1) waiting for the connection to hold doesn't hold up a
    /// cancel behind it.
    @Test func anUntestedDismissWaitingForTheHoldDoesntDelayACancel() async throws {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.alertBitmap = 1 << 7
            $0.startBolus(id: 10650, milliunits: 5000)
        })
        await rig.startHeld()
        // A fresh connection, inside its hold window: the dismiss (untested on P1) waits for the hold.
        rig.transport.drop()
        await rig.untilConnected()
        let alert = try #require(await rig.session.state.alerts?.value.first)
        let session = rig.session
        let dismiss = Task { await session.dismiss(alert) }
        await rig.settle()
        #expect(await session.cancelBolus() == .cancelled)
        #expect(rig.pump.arrivals(of: DismissNotificationRequest.self).isEmpty)
        await rig.run(for: 12, step: 1)
        #expect(await rig.value(of: dismiss) == .cleared)
    }

    @Test func cancelWithNoBolusSaysSo() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        #expect(await rig.session.cancelBolus() == .noBolus)
        #expect(rig.pump.arrivals(of: CancelBolusRequest.self).isEmpty)
    }
}

/// The scripted pump's bolus engine, run through the session: the pending phase and rate of the one
/// recorded t:slim bolus, how a bolus ends, and the history records a t:slim writes for it.
@MainActor
@Suite struct ScriptedBolusEngineTests {
    private func types(_ records: [[UInt8]]) -> [Int] { records.map { Bytes.readShort($0, 0) } }

    private func records(_ pump: ScriptedPump, _ typeId: Int) -> [[UInt8]] {
        pump.historyRecords.filter { Bytes.readShort($0, 0) == typeId }
    }

    /// For 15 s after it's accepted the pump reports the bolus pending (status 2) and delivers nothing; the
    /// session follows it through that and then through delivery, and never settles it early.
    @Test func aPendingBolusIsFollowedNotSettled() async throws {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        #expect(await rig.session.deliver(composed(1.0)) == .started(key, .delivering))
        await rig.run(for: 10)
        let bolus = try #require(rig.pump.activeBolus)
        #expect(rig.clock.now < bolus.deliversFrom)
        #expect(rig.pump.deliveredMilliunits(bolus) == 0)
        #expect(await rig.session.tracked != nil)
        #expect(await rig.session.ledger.ledger.outcome(key) == .delivering)
        // 1 U: 15 s pending, then 40 s at the recorded rate.
        await rig.run(for: rig.pump.deliverySeconds(milliunits: 1000) - 10 + 5)
        #expect(await rig.session.ledger.ledger.outcome(key) == .delivered(units: 1.0))
        #expect(await rig.outcomes(key) == [.requested, .accepted, .delivering, .delivered(units: 1.0)])
    }

    /// A pending bolus the pump drops is never taken as delivered: nothing went in.
    @Test func aPendingBolusThePumpDropsIsNeverDelivered() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.dropsPendingBolus = true
        })
        await rig.startHeld()
        _ = await rig.session.deliver(composed(1.0))
        await rig.run(for: rig.pump.deliverySeconds(milliunits: 1000) + 5)
        let outcome = await rig.session.ledger.ledger.outcome(key)
        #expect(outcome == .stopped(delivered: 0, requested: 1.0), "\(String(describing: outcome))")
        #expect(!(await rig.outcomes(key)).contains(.delivered(units: 1.0)))
        #expect(records(rig.pump, BolusActivatedHistoryLog.typeId).isEmpty)
    }

    /// The pump stops a bolus on its own (an alarm) with no cancel from the phone: the outcome is the
    /// amount that went in, and the alarm is shown once the pump's notice arrives.
    @Test func aBolusThePumpStopsSettlesStoppedAndShowsTheAlarm() async throws {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        _ = await rig.session.deliver(composed(2.0))
        await rig.run(for: rig.pump.pendingSeconds + 32)
        let delivered = rig.pump.deliveredMilliunits(try #require(rig.pump.activeBolus))
        #expect(delivered > 0 && delivered < 2000)
        rig.pump.stopBolus(completionStatus: ScriptedPump.CompletionStatus.alarm, alarmBit: 5)
        rig.transport.qualifyingEvents([.alarm, .bolusChange])
        await rig.run(for: 10)
        #expect(
            await rig.session.ledger.ledger.outcome(key)
                == .stopped(delivered: Double(delivered) / 1000, requested: 2.0))
        #expect(rig.pump.arrivals(of: CancelBolusRequest.self).isEmpty)
        let alerts = await rig.session.state.alerts?.value ?? []
        #expect(alerts.contains { $0.id == 5 && $0.kind == .alarm })
        let completed = BolusCompletedHistoryLog(cargo: try #require(records(rig.pump, 20).last))
        #expect(completed.completionStatusId == ScriptedPump.CompletionStatus.alarm)
    }

    /// A cancel from the phone is recorded with the phone-cancel completion status, a full delivery with
    /// the delivered one.
    @Test func eachEndIsRecordedWithItsCompletionStatus() async throws {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        _ = await rig.session.deliver(composed(2.0))
        await rig.run(for: rig.pump.pendingSeconds + 5)
        #expect(await rig.session.cancelBolus() == .cancelled)
        await rig.run(for: 5)
        let cancelled = BolusCompletedHistoryLog(cargo: try #require(records(rig.pump, 20).last))
        #expect(cancelled.completionStatusId == ScriptedPump.CompletionStatus.cancelledFromPhone)

        _ = await rig.session.deliver(composed(1.0, id: "phone-2"))
        await rig.run(for: rig.pump.deliverySeconds(milliunits: 1000) + 5)
        let full = BolusCompletedHistoryLog(cargo: try #require(records(rig.pump, 20).last))
        #expect(full.completionStatusId == ScriptedPump.CompletionStatus.delivered)
        #expect(full.insulinDelivered == 1.0)
    }

    /// An engine bolus writes the records the capture of bolus 3 shows, in its order and with its timing:
    /// 15 s from the request records to activation, then 40 s for 1 U.
    @Test func anEngineBolusWritesTheCapturesRecords() async throws {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        _ = await rig.session.deliver(composed(1.0))
        await rig.run(for: rig.pump.deliverySeconds(milliunits: 1000) + 15)
        let captured = CapturedBolus3.historyRecords.sorted { Bytes.readUint32($0, 6) < Bytes.readUint32($1, 6) }
        // Type 23 in the capture is a record of something else between the bolus's records.
        #expect(types(rig.pump.historyRecords) == types(captured).filter { $0 != 23 })

        let initiate = InitiateBolusRequestMsg1HistoryLog(cargo: try #require(records(rig.pump, 292).first))
        let activated = BolusActivatedHistoryLog(cargo: try #require(records(rig.pump, 55).first))
        let deliveries = records(rig.pump, 280).map { BolusDeliveryHistoryLog(cargo: $0) }
        let completed = BolusCompletedHistoryLog(cargo: try #require(records(rig.pump, 20).first))
        #expect(initiate.bolusId == 10650 && initiate.totalVolume == 1000 && initiate.bolusTypeBitmask == 8)
        #expect(activated.bolusId == 10650 && activated.bolusSize == 1.0)
        #expect(deliveries.map(\.bolusDeliveryStatusId) == [1, 0])
        #expect(deliveries.map(\.deliveredTotal) == [0, 1000])
        #expect(completed.bolusId == 10650 && completed.insulinDelivered == 1.0)
        #expect(activated.pumpTimeSec - initiate.pumpTimeSec == 15)
        #expect(completed.pumpTimeSec - activated.pumpTimeSec == 40)
        // Every record the session reads as naming a bolus names this one: the requested, initiate,
        // activated, two delivery and completed records.
        let named = rig.pump.historyRecords.compactMap {
            HistoryProjection.bolusId(of: HistoryLogParser.parse(record: $0))
        }
        #expect(named == [Int](repeating: 10650, count: 11))
    }

    /// While the status read goes unanswered mid-bolus, a history search finds the bolus from the records
    /// the pump wrote when it accepted it, and never calls it absent.
    @Test func aBolusWhoseStatusGoesUnansweredIsPresentInHistory() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            // Slow enough that the bolus is still going when the pages are read, minutes in.
            $0.deliveryMilliunitsPerSecond = 5
        })
        addOldHistory(rig.pump)
        await rig.startHeld()
        let acceptedAt = rig.pump.wallClock
        _ = await rig.session.deliver(composed(2.0))
        await rig.run(for: rig.pump.pendingSeconds + 5)
        rig.pump.answers[MessageKey(CurrentBolusStatusRequest.self)] = .silent
        let session = rig.session
        // The bolus's own status reads go first and wait out their 60 s deadlines until it is given up on as
        // unknown; then the search's status read waits out its own, and the routine status read can take the
        // wire for two more deadlines before it rests. Only then are the history pages read.
        let found = await rig.run(upTo: 600) { await session.searchHistory(for: 10650, acceptedAt: acceptedAt) }
        #expect(found == .present)
    }
}
