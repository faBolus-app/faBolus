import Foundation
import PumpScript
import TandemLink
import TandemMessages
import Testing

@testable import PumpSession
@testable import faBolusCore

private let key = RemoteBolusLedger.Key(peerId: "phone", requestId: "phone-1")
/// The scripted pump's clock when the link starts, set on every rig here.
private let pumpStart: UInt32 = 512_442_842

/// A saved ledger with one 1 U bolus (`phone-1`, bolus 500, the rig's pump) whose outcome is unknown,
/// accepted at `pumpClock` on the pump's clock.
private func unknownLedger(pumpClock: UInt32? = pumpStart, confirmed: Bool = false) -> RemoteBolusLedger {
    var ledger = RemoteBolusLedger()
    let at = Date(timeIntervalSince1970: 1_700_000_000)
    let request = DoseRequest(id: "phone-1", origin: .phone, shape: .now(units: 1.0))
    _ = ledger.begin(request, now: at)
    ledger.markAccepted(key, bolusId: 500, pumpKey: "tandem|1693", pumpClock: pumpClock, now: at)
    ledger.markUnknown(key, now: at)
    if confirmed { ledger.confirmOnPump(key, now: at) }
    return ledger
}

@MainActor
private func completedRecord(_ pump: ScriptedPump, at pumpTime: UInt32? = nil) {
    pump.appendHistory(
        typeId: 20, at: pumpTime,
        body: ScriptedPump.bolusCompletedBody(bolusId: 500, completionStatus: 3, iob: 0, delivered: 1, requested: 1))
}

@MainActor
private func filler(_ pump: ScriptedPump, count: Int) {
    for _ in 0..<count { pump.appendHistory(typeId: 16, body: le16(120) + [UInt8](repeating: 0, count: 14)) }
}

/// History requests that ask for `count` records.
@MainActor
private func pages(_ pump: ScriptedPump, count: Int) -> Int {
    pump.arrivals(of: HistoryLogRequest.self).filter { Int($0.cargo[4]) == count }.count
}

extension PumpSession {
    fileprivate func isReconciling() -> Bool { reconciling }
    fileprivate func setTrusted(_ trusted: Bool) { identityTrusted = trusted }
    fileprivate func historyDue() -> Uptime? { due[.history] }
    fileprivate func misses(_ key: MessageKey) -> Int { unanswered[key]?.count ?? 0 }
}

@MainActor
@Suite struct BolusOutcomeFixTests {
    /// A completed record with the bolus's ID and amount from before the bolus was accepted is another
    /// bolus's: it doesn't settle this one. A record written after the acceptance does.
    @Test func aRecordOlderThanTheAcceptanceDoesntSettleTheBolus() async {
        let rig = Rig(
            ledger: unknownLedger(),
            configure: {
                $0.unsupportedReads = []
                $0.wallClockAtStart = pumpStart
                completedRecord($0, at: pumpStart - 3600)
            })
        await rig.startHeld()
        await rig.run(for: 30, step: 1)
        #expect(await rig.ledger.ledger.outcome(key)?.isUnknown == true)
        completedRecord(rig.pump)
        await rig.run(for: 130, step: 2)
        #expect(await rig.ledger.ledger.outcome(key) == .delivered(units: 1.0))
    }

    /// A cancel by the bolus the last routine status read reported, which has ended since while the pump
    /// started another, is refused by the pump. That says nothing about the bolus going on: unconfirmed,
    /// never "it may have finished".
    @Test func aRefusedCancelOfAnIdNotJustSeenActiveIsUnconfirmed() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.startBolus(id: 10650, milliunits: 5000)
        })
        await rig.startHeld()
        rig.pump.stopBolus(completionStatus: 3)
        rig.pump.startBolus(id: 10651, milliunits: 5000)
        #expect(await rig.session.cancelBolus() == .unconfirmed)
        #expect(rig.pump.activeBolus?.id == 10651)
    }

    /// With the pump's bolus status unanswered, an outcome the user confirmed on the pump isn't cancelled by
    /// its recorded ID: it's no longer a bolus the phone may be delivering.
    @Test func theCancelFallbackLeavesOutAConfirmedOutcome() async {
        let rig = Rig(
            ledger: unknownLedger(confirmed: true),
            configure: {
                $0.unsupportedReads = []
                $0.wallClockAtStart = pumpStart
            })
        await rig.startHeld()
        rig.pump.answers[MessageKey(CurrentBolusStatusRequest.self)] = .silent
        let session = rig.session
        #expect(await rig.run(upTo: 150) { await session.cancelBolus() } == .unconfirmed)
        #expect(rig.pump.arrivals(of: CancelBolusRequest.self).isEmpty)
    }

    /// A bolus the pump gave between preparing the dose and delivering it, which a read in between already
    /// counts: the IOB the dose was prepared with is what's compared, so the rise still stops the dose.
    @Test func aReadBetweenPreparingAndDeliveringDoesntHideAPumpBolus() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        _ = await rig.session.prepareDose()
        rig.pump.calculatorInsulinOnBoardMilliunits = 2_500
        rig.pump.insulinOnBoardMilliunits = 2_500
        _ = await rig.session.prepareDose()
        let dose = {
            var dose = composed(1.0)
            dose.preparedIOBUnits = 0.5
            return dose
        }()
        let session = rig.session
        let result = await rig.run(for: 3, upTo: 120) { await session.deliver(dose) }
        #expect(result == .started(key, .failed(reason: PumpSession.iobRoseReason(from: 0.5, to: 2.5))))
        #expect(rig.pump.arrivals(of: InitiateBolusRequest.self).isEmpty)
    }
}

@MainActor
@Suite struct HistorySearchFixTests {
    /// An outcome the user confirmed on the pump isn't searched for: no 250-record search pages over ten
    /// minutes of connection.
    @Test func aConfirmedOutcomeIsNotSearchedFor() async {
        let rig = Rig(
            ledger: unknownLedger(confirmed: true),
            configure: {
                $0.unsupportedReads = []
                $0.wallClockAtStart = pumpStart
                filler($0, count: 40)
            })
        await rig.startHeld()
        await rig.run(for: 600, step: 5)
        // Its one search, and none after, on this connection or the next.
        #expect(pages(rig.pump, count: 40) == 1)
        rig.transport.drop()
        await rig.untilConnected()
        await rig.run(for: 300, step: 5)
        #expect(pages(rig.pump, count: 40) == 1)
        #expect(await rig.ledger.ledger.outcome(key)?.isUnknown == true)
    }

    /// A confirmed outcome whose record a sync already read (while the bolus was still delivering) is
    /// settled by its one search, as no sync reads that record again.
    @Test func aConfirmedOutcomeWhoseRecordWasAlreadySyncedIsSettledByOneSearch() async {
        let rig = Rig(
            ledger: unknownLedger(confirmed: true),
            record: PumpSessionRecord(pairing: Rig.pairing, coverage: HistoryCoverage().inserting(1000...1010)),
            configure: {
                $0.unsupportedReads = []
                $0.wallClockAtStart = pumpStart
                completedRecord($0)
                filler($0, count: 10)
            })
        await rig.startHeld()
        await rig.run(for: 30, step: 1)
        #expect(await rig.ledger.ledger.outcome(key) == .delivered(units: 1.0))
    }

    /// A sync page that holds a confirmed outcome's record still fills in what went in.
    @Test func aSyncPageSettlesAConfirmedOutcome() async {
        let rig = Rig(
            ledger: unknownLedger(confirmed: true),
            configure: {
                $0.unsupportedReads = []
                $0.wallClockAtStart = pumpStart
                completedRecord($0)
            })
        await rig.startHeld()
        await rig.run(for: 30, step: 1)
        #expect(await rig.ledger.ledger.outcome(key) == .delivered(units: 1.0))
    }

    /// A search asked for while another runs (a bolus that just became unknown) isn't lost: it runs as soon
    /// as the running one ends, not at the next two-minute try.
    @Test func aSearchAskedForDuringAnotherRunsAfterIt() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.wallClockAtStart = pumpStart
        })
        await rig.startHeld()
        for _ in 0..<60 where await rig.session.isReconciling() { await rig.run(for: 1, step: 1) }
        #expect(await !rig.session.isReconciling())
        func goesUnknown(_ id: String, bolusId: Int) async {
            let request = DoseRequest(id: id, origin: .phone, shape: .now(units: 1.0))
            _ = try? await rig.ledger.begin(request)
            _ = try? await rig.ledger.markAccepted(
                request.ledgerKey, bolusId: bolusId, pumpKey: "tandem|1693", pumpClock: pumpStart)
            await rig.session.settle(request.ledgerKey, .unknown)
        }
        // The first search waits out a status read the pump doesn't answer (60 s).
        rig.pump.nextAnswers[MessageKey(HistoryLogStatusRequest.self)] = [.silent]
        await goesUnknown("phone-1", bolusId: 500)
        await rig.run(for: 20, step: 1)
        #expect(await rig.session.isReconciling())
        // Meanwhile a second bolus becomes unknown, and its search is asked for.
        await goesUnknown("phone-2", bolusId: 501)
        let asked = rig.pump.arrivals(of: HistoryLogStatusRequest.self).count
        // The first search ends about 60 s after it began, and the second runs straight after it: well before
        // the next two-minute try.
        for _ in 0..<9 {
            await rig.run(for: 10, step: 1)
            print("DEBUG", await rig.session.uptime(), await rig.session.isReconciling(), await rig.session.nextReconcileAt as Any, rig.pump.arrivals(of: HistoryLogStatusRequest.self).count, rig.pump.arrivals(of: CurrentBolusStatusRequest.self).count, await rig.ledger.ledger.unresolved.map(\.key.requestId))
        }
        #expect(rig.pump.arrivals(of: HistoryLogStatusRequest.self).count > asked)
    }

    /// A page cut short doesn't end the search: it goes on from below what arrived and finds the record.
    @Test func aShortPageDoesntEndTheSearch() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.wallClockAtStart = pumpStart
            completedRecord($0)
            filler($0, count: 150)
            $0.historyRecordsPerRequest = 100
        })
        await rig.startHeld()
        let session = rig.session
        let result = await rig.run(upTo: 120) {
            await session.searchHistory(for: 500, acceptedAt: pumpStart, notBefore: pumpStart - 600)
        }
        guard case .completed(let found)? = result else {
            Issue.record("expected the record, got \(String(describing: result))")
            return
        }
        #expect(found.bolusId == 500)
    }

    /// A sync whose requests come back with no record isn't a sync: the last sync's time stands, and it's
    /// asked again soon. Once the pump sends the records, the sync completes.
    @Test func aSyncAnsweredWithNoRecordIsntSynced() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            filler($0, count: 20)
            $0.historyRecordsPerRequest = 0
        })
        await rig.startHeld()
        await rig.run(for: 20, step: 1)
        #expect(rig.store.load()?.lastHistorySync == nil)
        #expect(await rig.session.historySync == .idle(lastSynced: nil))
        let asked = rig.pump.arrivals(of: HistoryLogRequest.self).count
        rig.pump.historyRecordsPerRequest = nil
        await rig.run(for: 70, step: 2)
        #expect(rig.pump.arrivals(of: HistoryLogRequest.self).count > asked)
        #expect(rig.store.load()?.lastHistorySync != nil)
        #expect(rig.store.load()?.coverage.ranges.count == 1)
    }
}

@MainActor
@Suite struct LinkAndTimingFixTests {
    /// A reconnect to the same pump soon after doesn't read again its settings, its CGM hardware or its
    /// history; the essential reads go again.
    @Test func aQuickReconnectDoesntReadEverythingAgain() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            filler($0, count: 20)
        })
        await rig.startHeld()
        await rig.run(for: 20, step: 1)
        let pump = rig.pump
        let settings = pump.arrivals(of: BasalLimitSettingsRequest.self).count
        let hardware = pump.arrivals(of: CGMHardwareInfoRequest.self).count
        let history = pump.arrivals(of: HistoryLogStatusRequest.self).count
        let clock = pump.arrivals(of: TimeSinceResetRequest.self).count
        #expect(settings == 1 && hardware == 1 && history >= 1)
        rig.transport.drop()
        await rig.untilConnected()
        await rig.run(for: 20, step: 1)
        #expect(pump.arrivals(of: BasalLimitSettingsRequest.self).count == settings)
        #expect(pump.arrivals(of: CGMHardwareInfoRequest.self).count == hardware)
        #expect(pump.arrivals(of: HistoryLogStatusRequest.self).count == history)
        #expect(pump.arrivals(of: TimeSinceResetRequest.self).count > clock)
    }

    private func graceRig() async -> Rig {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.apiVersion = (major: 4, minor: 0)
        })
        await rig.startHeld()
        return rig
    }

    private func graceDetail(_ rig: Rig) async -> String? {
        await rig.session.state.alerts?.value.first { $0.kind == .cgmAlert && $0.id == 32 }?.detail
    }

    /// The phone's clock set back an hour doesn't move the grace period's end: the time left still counts
    /// down from the read.
    @Test func theGraceTimeLeftFollowsAPhoneClockSet() async {
        let rig = await graceRig()
        rig.pump.graceSecondsLeft = 2200
        rig.pump.cgmAlertBitmap = 1 << 32
        rig.transport.qualifyingEvents(.cgmAlert)
        await rig.settle()
        #expect(await graceDetail(rig) == "About 2 hours of the sensor's grace period are left.")
        rig.clock.setWallClock(by: -3600)
        await rig.run(for: 120)
        rig.transport.qualifyingEvents(.cgmAlert)
        await rig.settle()
        #expect(await graceDetail(rig) == "About 30 minutes of the sensor's grace period are left.")
    }

    /// The grace-period read lost to a drop is asked again on the next connection.
    @Test func aGraceReadLostToADropIsAskedAgain() async {
        let rig = await graceRig()
        rig.pump.graceSecondsLeft = 3600
        rig.pump.nextAnswers[MessageKey(CgmStatusV2Request.self)] = [.drop(acted: false)]
        rig.pump.cgmAlertBitmap = 1 << 32
        rig.transport.qualifyingEvents(.cgmAlert)
        await rig.settle()
        await rig.untilConnected()
        await rig.run(for: 20, step: 1)
        #expect(rig.pump.arrivals(of: CgmStatusV2Request.self).count == 2)
        #expect(await graceDetail(rig) == "About 2 hours of the sensor's grace period are left.")
    }

    /// A pump notice doesn't ask again a read resting after the pump left it unanswered twice.
    @Test func aNoticeDoesntAskARestingRead() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        rig.pump.answers[MessageKey(InsulinStatusRequest.self)] = .silent
        let resting = MessageKey(InsulinStatusRequest.self)
        for _ in 0..<200 where await rig.session.misses(resting) < 2 {
            await rig.run(for: 5, step: 1)
        }
        let now = await rig.session.uptime()
        #expect(await rig.session.restingAfterNoAnswer(InsulinStatusRequest(), now: now))
        let asked = rig.pump.arrivals(of: InsulinStatusRequest.self).count
        rig.transport.qualifyingEvents(.remainingInsulin)
        await rig.run(for: 5, step: 1)
        #expect(rig.pump.arrivals(of: InsulinStatusRequest.self).count == asked)
    }

    /// The phone's clock set forward while a dose's reads wait: a reading from before the dose's reads
    /// still reads as from before them.
    @Test func aClockSetDuringTheDoseReadsMovesWhenTheyWereAskedFor() async throws {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        rig.pump.answers[MessageKey(ControlIQIOBRequest.self)] = .silent
        let session = rig.session
        let preparation = Task { await session.prepareDose() }
        await rig.run(for: 5, step: 1)
        rig.clock.setWallClock(by: 3600)
        await rig.run(for: 70, step: 1)
        let prepared = try #require(await rig.value(of: preparation))
        let iob = try #require(prepared.pump.insulinOnBoard)
        #expect(iob.receivedAt < prepared.inputsRequestedAt)
    }

    /// A UserInteraction this pump's class is suspected of rejecting isn't sent when the bolus screen
    /// opens: its rejection could drop the link just before a dose.
    @Test func aSuspectedUserInteractionIsntSent() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = [MessageKey(UserInteractionRequest.self)]
            $0.apiVersion = (major: 4, minor: 0)
        })
        await rig.startHeld()
        let session = rig.session
        // The rejection's drop comes on the pump's clock, so the clock is moved until the write is answered.
        await rig.run(upTo: 30) { await session.bolusScreenOpened() }
        await rig.untilConnected(limit: 30)
        await rig.run(for: 12, step: 1)
        #expect(rig.pump.arrivals(of: UserInteractionRequest.self).count == 1)
        await rig.run(upTo: 30) { await session.bolusScreenOpened() }
        #expect(rig.pump.arrivals(of: UserInteractionRequest.self).count == 1)
    }

    /// A clear waiting for the pump after a drop waits for this connection's alert read, not the list the
    /// last connection left.
    @Test func aWaitingClearWaitsForThisConnectionsAlerts() async throws {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.alertBitmap = 1 << 7
        })
        await rig.startHeld()
        let alert = try #require(await rig.session.state.alerts?.value.first)
        rig.pump.answers[MessageKey(AlertStatusRequest.self)] = .silent
        rig.transport.drop()
        let session = rig.session
        let dismiss = Task { await session.dismiss(alert, waitingForLinkUpTo: 40) }
        await rig.untilConnected()
        await rig.run(for: 20, step: 1)
        #expect(rig.pump.arrivals(of: DismissNotificationRequest.self).isEmpty)
        rig.pump.answers[MessageKey(AlertStatusRequest.self)] = .normal
        await rig.run(for: 90, step: 2)
        _ = await rig.value(of: dismiss)
        #expect(rig.pump.arrivals(of: DismissNotificationRequest.self).count == 1)
    }

    /// A part of the log the pump never sends doesn't stop syncs finishing: after a few quick retries the
    /// sync finishes with that window still missing, to be asked for at the next routine sync.
    @Test func aWindowThePumpNeverSendsStillLetsTheSyncFinish() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            filler($0, count: 20)
            $0.historyRecordsPerRequest = 0
        })
        await rig.startHeld()
        await rig.run(for: 20, step: 1)
        #expect(rig.store.load()?.lastHistorySync == nil)
        await rig.run(for: 240, step: 2)
        #expect(rig.store.load()?.lastHistorySync != nil)
        #expect(rig.store.load()?.coverage.ranges.isEmpty == true)
    }

    /// A new CGM reading is followed by one read of the calculator snapshot, so the reading it carries is
    /// the new one within seconds; the same reading read again asks for nothing more.
    @Test func aNewCGMReadingIsFollowedByOneSnapshotRead() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        await rig.run(for: 5, step: 1)
        let before = rig.pump.arrivals(of: BolusCalcDataSnapshotRequest.self).count
        rig.pump.glucose = (150, 0)
        rig.transport.qualifyingEvents(.cgmChange)
        await rig.run(for: 3, step: 1)
        #expect(rig.pump.arrivals(of: BolusCalcDataSnapshotRequest.self).count == before + 1)
        let state = await rig.session.state
        #expect(state.bolusCalculator?.value.reading?.mgdl == 150)
        #expect(state.correctionReading?.value.mgdl == state.glucose?.value.mgdl)
        // The same reading, read again on a notice: no snapshot read.
        rig.transport.qualifyingEvents(.cgmChange)
        await rig.run(for: 3, step: 1)
        #expect(rig.pump.arrivals(of: BolusCalcDataSnapshotRequest.self).count == before + 1)
    }

    /// While the connected pump isn't trusted yet (a new pairing being checked), a sync that comes due
    /// isn't pushed back: it runs as soon as the pump is trusted.
    @Test func anUntrustedPumpDoesntPushTheSyncBack() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            filler($0, count: 20)
        })
        await rig.startHeld()
        await rig.run(for: 20, step: 1)
        await rig.session.setTrusted(false)
        let syncs = rig.pump.arrivals(of: HistoryLogStatusRequest.self).count
        rig.transport.qualifyingEvents(.battery)
        await rig.run(for: 3, step: 1)
        let due = await rig.session.historyDue()
        let now = await rig.session.uptime()
        #expect(due.map { $0 <= now } == true)
        await rig.session.setTrusted(true)
        await rig.run(for: 5, step: 1)
        #expect(rig.pump.arrivals(of: HistoryLogStatusRequest.self).count > syncs)
    }
}
