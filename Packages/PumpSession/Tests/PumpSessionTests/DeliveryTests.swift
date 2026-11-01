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
        await sync.value
        let batches = await rig.sink.batches
        #expect(batches.flatMap(\.boluses).map(\.units) == [1.0])
        #expect(await rig.session.historyEvents.contains { $0.title == "Bolus delivered" && $0.detail == "1.00 U" })
        // 4632-4639 weren't captured: only the run held from the newest record down is credited.
        #expect(rig.store.load()?.coverage.ranges == [4640...4642])
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
        _ = await delivery.value
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
        _ = await delivery.value
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
        let result = await delivery.value
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
        await rig.run(for: 5)
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
        await rig.run(for: 12)
        let result = await delivery.value
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
        await rig.run(for: 12)
        _ = await delivery.value
        _ = await cancel.value
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
        await rig.start()
        let alert = try #require(await rig.session.state.alerts?.value.first)
        let session = rig.session
        let dismiss = Task { await session.dismiss(alert) }
        await rig.settle()
        #expect(await session.cancelBolus() == .cancelled)
        #expect(rig.pump.arrivals(of: DismissNotificationRequest.self).isEmpty)
        await rig.run(for: 12, step: 1)
        #expect(await dismiss.value == .cleared)
    }

    @Test func cancelWithNoBolusSaysSo() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        #expect(await rig.session.cancelBolus() == .noBolus)
        #expect(rig.pump.arrivals(of: CancelBolusRequest.self).isEmpty)
    }
}
