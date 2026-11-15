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
private func completedRecord(_ pump: ScriptedPump, bolusId: Int = 500, at pumpTime: UInt32? = nil) {
    pump.appendHistory(
        typeId: 20, at: pumpTime,
        body: ScriptedPump.bolusCompletedBody(
            bolusId: bolusId, completionStatus: 3, iob: 0, delivered: 1, requested: 1))
}

@MainActor
private func filler(_ pump: ScriptedPump, count: Int) {
    for _ in 0..<count { pump.appendHistory(typeId: 16, body: le16(120) + [UInt8](repeating: 0, count: 14)) }
}

/// History requests that ask for `count` records. A search asks for the whole log here (under a page),
/// a sync for at most `historySyncBatch` (30), so with 40 records only a search asks for 40.
@MainActor
private func pages(_ pump: ScriptedPump, count: Int) -> Int {
    pump.arrivals(of: HistoryLogRequest.self).filter { Int($0.cargo[4]) == count }.count
}

extension PumpSession {
    fileprivate func isReconciling() -> Bool { reconciling }
}

@MainActor
@Suite struct BolusRecordFixTests {
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
}

@MainActor
@Suite struct HistorySettlingTests {
    /// A completed bolus the phone already holds settles an unknown outcome without searching the pump's
    /// log.
    @Test func aRecordThePhoneHoldsSettlesWithoutASearch() async {
        let sink = RecordingSink()
        var held = PumpHistoryBatch()
        held.completedBoluses = [
            HistoryBolus(sequence: 1, bolusId: 500, pumpTime: pumpStart, deliveredUnits: 1, requestedUnits: 1)
        ]
        try? await sink.record(held)
        let rig = Rig(
            ledger: unknownLedger(confirmed: true), sink: sink,
            configure: {
                $0.unsupportedReads = []
                $0.wallClockAtStart = pumpStart
                filler($0, count: 40)
            })
        await rig.startHeld()
        await rig.run(for: 30, step: 1)
        #expect(await rig.ledger.ledger.outcome(key) == .delivered(units: 1.0))
        #expect(pages(rig.pump, count: 40) == 0)
    }

    /// One the phone holds from before the bolus's acceptance is another bolus's, and the log is searched.
    @Test func anOlderRecordThePhoneHoldsDoesntSettle() async {
        let sink = RecordingSink()
        var held = PumpHistoryBatch()
        held.completedBoluses = [
            HistoryBolus(sequence: 1, bolusId: 500, pumpTime: pumpStart - 3600, deliveredUnits: 1, requestedUnits: 1)
        ]
        try? await sink.record(held)
        let rig = Rig(
            ledger: unknownLedger(confirmed: true), sink: sink,
            configure: {
                $0.unsupportedReads = []
                $0.wallClockAtStart = pumpStart
                filler($0, count: 40)
            })
        await rig.startHeld()
        await rig.run(for: 30, step: 1)
        #expect(await rig.ledger.ledger.outcome(key)?.isUnknown == true)
        #expect(pages(rig.pump, count: 40) >= 1)
    }

    /// The pump's log is searched for one unknown outcome a bounded number of times in all, across
    /// connections and launches: a bolus confirmed on the pump isn't searched for after every connection.
    @Test func theSearchesForAnOutcomeAreCappedAcrossConnectionsAndLaunches() async {
        var configuration = PumpSession.Configuration()
        configuration.reconcileSearchesPerEntry = 2
        configuration.reconcileInterval = 20
        let configure: (ScriptedPump) -> Void = {
            $0.unsupportedReads = []
            $0.wallClockAtStart = pumpStart
            filler($0, count: 40)
        }
        let rig = Rig(ledger: unknownLedger(confirmed: true), configure: configure, configuration: configuration)
        await rig.startHeld()
        await rig.run(for: 200, step: 2)
        #expect(pages(rig.pump, count: 40) == 2)
        rig.transport.drop()
        await rig.untilConnected()
        await rig.run(for: 120, step: 2)
        #expect(pages(rig.pump, count: 40) == 2)
        #expect(await rig.ledger.ledger.outcome(key)?.isUnknown == true)

        let relaunched = Rig(
            ledger: rig.ledgerStore.saved, record: rig.store.load(), configure: configure,
            configuration: configuration)
        await relaunched.startHeld()
        await relaunched.run(for: 120, step: 2)
        #expect(pages(relaunched.pump, count: 40) == 0)
    }

    /// A confirmed outcome whose record a sync already read (while the bolus was still delivering) is
    /// settled by a search, as no sync reads that record again.
    @Test func aConfirmedOutcomeWhoseRecordWasAlreadySyncedIsSettledByASearch() async {
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
    /// as the running one ends, not at the next routine try two minutes on.
    @Test func aSearchAskedForDuringAnotherRunsAfterIt() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            $0.wallClockAtStart = pumpStart
            filler($0, count: 10)
        })
        await rig.startHeld()
        await rig.run(for: 30, step: 1)
        #expect(await !rig.session.isReconciling())
        func goesUnknown(_ id: String, bolusId: Int) async throws {
            let request = DoseRequest(id: id, origin: .phone, shape: .now(units: 1.0))
            #expect(try await rig.ledger.begin(request) == .proceed)
            #expect(
                try await rig.ledger.markAccepted(
                    request.ledgerKey, bolusId: bolusId, pumpKey: "tandem|1693", pumpClock: pumpStart))
            await rig.session.settle(request.ledgerKey, .unknown)
        }
        // The first search waits out a status read the pump doesn't answer.
        rig.pump.nextAnswers[MessageKey(HistoryLogStatusRequest.self)] = [.silent]
        try? await goesUnknown("phone-1", bolusId: 500)
        await rig.run(for: 20, step: 1)
        #expect(await rig.session.isReconciling())
        // Meanwhile the user confirms it on the pump, a second bolus goes unknown, and its search is asked for.
        _ = try? await rig.ledger.confirmOnPump(key)
        try? await goesUnknown("phone-2", bolusId: 501)
        #expect(await rig.ledger.ledger.unknownOutcomes.count == 2)
        let asked = rig.pump.arrivals(of: HistoryLogStatusRequest.self).count
        var waited = 0
        while await rig.session.isReconciling(), waited < 90 {
            await rig.run(for: 1, step: 1)
            waited += 1
        }
        #expect(await !rig.session.isReconciling())
        #expect(rig.pump.arrivals(of: HistoryLogStatusRequest.self).count == asked)
        // The second search goes within seconds of the first ending, well before the next routine try.
        await rig.run(for: 10, step: 1)
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
        // Finished, and not retried again until the routine interval.
        let asked = rig.pump.arrivals(of: HistoryLogRequest.self).count
        await rig.run(for: 120, step: 2)
        #expect(rig.pump.arrivals(of: HistoryLogRequest.self).count == asked)
        // The next routine sync meets the same silence and finishes at once: the retries were spent.
        let finished = rig.store.load()?.lastHistorySync
        await rig.run(for: 15 * 60, step: 10)
        let next = rig.store.load()?.lastHistorySync
        #expect(next != finished)
        if let finished, let next { #expect(next.timeIntervalSince(finished) < 16 * 60) }
    }
}
