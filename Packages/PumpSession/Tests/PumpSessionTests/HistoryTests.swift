import Foundation
import PumpScript
import TandemLink
import TandemMessages
import Testing

@testable import PumpSession
@testable import faBolusCore

/// Glucose records every 5 minutes, the newest a minute before the pump's clock starts.
@MainActor
private func addGlucoseHistory(_ pump: ScriptedPump, count: Int) {
    for i in 0..<count {
        let at = pump.wallClockAtStart - 60 - UInt32((count - 1 - i) * 300)
        pump.appendHistory(typeId: 256, at: at, body: [UInt8](repeating: 0, count: 6) + le16(100 + i % 50))
    }
}

@MainActor
@Suite struct HistorySyncTests {
    private func sync(_ rig: Rig) async {
        let session = rig.session
        let task = Task { await session.syncHistory() }
        await rig.run(for: 8)
        await task.value
    }

    @Test func fetchesTheMissingRecordsAndCreditsThemOnceStored() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            addGlucoseHistory($0, count: 300)
        })
        await rig.startHeld()
        await sync(rig)
        let first = rig.pump.firstHeldSequence!, last = rig.pump.lastSequence!
        #expect(rig.store.load()?.coverage.ranges == [first...last])
        let stored = await rig.sink.batches.flatMap(\.sequences)
        #expect(stored.count == 300)
        #expect(Set(stored).count == 300)
        #expect(await rig.sink.batches.flatMap(\.glucose).count == 300)
        #expect(await rig.session.historySync == .idle(lastSynced: rig.store.load()?.lastHistorySync))
        // Nothing missing: the next sync asks for the range and fetches no page.
        let pages = rig.pump.arrivals(of: HistoryLogRequest.self).count
        await sync(rig)
        #expect(rig.pump.arrivals(of: HistoryLogRequest.self).count == pages)
    }

    /// The link drops after the first page. The sync pauses with the first page credited, and the next
    /// connection fetches only what's still missing; every record is stored exactly once.
    @Test func anInterruptedSyncResumesWhereItStopped() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            addGlucoseHistory($0, count: 600)
        })
        let pump = rig.pump
        pump.nextAnswers[MessageKey(HistoryLogRequest.self)] = [.normal, .drop(acted: false)]
        await rig.startHeld()
        await rig.run(for: 60, step: 1)
        let first = pump.firstHeldSequence!, last = pump.lastSequence!
        #expect(rig.store.load()?.coverage.ranges == [first...last])
        let stored = await rig.sink.batches.flatMap(\.sequences)
        #expect(stored.count == 600)
        #expect(Set(stored).count == 600)
        #expect(await rig.events.contains(.historySync(.paused)))
        // The page fetched before the drop wasn't asked for again.
        let starts = pump.arrivals(of: HistoryLogRequest.self).map { readStart($0.cargo) }
        #expect(starts.filter { $0 == last - 254 }.count == 1)
    }

    /// A sync cut short by its page limit continues within a minute, not at the next routine sync.
    @Test func aSyncCutShortByItsPageLimitContinuesSoon() async {
        var config = PumpSession.Configuration()
        config.historyMaxPages = 1
        let rig = Rig(
            configure: {
                $0.unsupportedReads = []
                addGlucoseHistory($0, count: 600)
            }, configuration: config)
        await rig.startHeld()
        await rig.run(for: 3 * 60, step: 5)
        let first = rig.pump.firstHeldSequence!, last = rig.pump.lastSequence!
        #expect(rig.store.load()?.coverage.ranges == [first...last])
    }

    /// A page the history store couldn't keep isn't credited, so it is fetched again.
    @Test func aPageTheStoreCouldntKeepIsFetchedAgain() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            addGlucoseHistory($0, count: 50)
        })
        await rig.sink.setFail(true)
        await rig.startHeld()
        #expect(rig.store.load()?.coverage.ranges.isEmpty == true)
        guard case .error = await rig.session.historySync else {
            Issue.record("expected an error state")
            return
        }
        await rig.sink.setFail(false)
        await sync(rig)
        #expect(rig.store.load()?.coverage.ranges.count == 1)
        #expect(await rig.sink.batches.flatMap(\.sequences).count == 50)
    }

    /// Missing windows go newest first: with a hole in old history and new records since, the new records
    /// come before the hole, so a backlog the page cap cuts short never starves the newest records.
    @Test func theNewestMissingWindowComesFirst() async {
        var held = PumpSessionRecord(pairing: Rig.pairing)
        held.coverage = HistoryCoverage(ranges: [1000...1099, 1200...1399])
        let rig = Rig(
            record: held,
            configure: {
                $0.unsupportedReads = []
                addGlucoseHistory($0, count: 500)
            })
        await rig.startHeld()
        await sync(rig)
        let starts = rig.pump.arrivals(of: HistoryLogRequest.self).map { readStart($0.cargo) }
        #expect(starts == [1400, 1100])
    }

    @Test func aRecordDatedInTheFutureIsDroppedNotMovedToNow() {
        let anchor = PumpClockAnchor(pumpTime: 1_000_000, phoneTime: Date(timeIntervalSince1970: 1_800_000_000))
        let now = anchor.phoneTime
        let records = [
            ScriptedPump.record(
                typeId: 256, pumpTime: 1_000_000 - 300, sequence: 1, body: [0, 0, 0, 0, 0, 0] + le16(110)),
            ScriptedPump.record(
                typeId: 256, pumpTime: 1_000_000 + 3600, sequence: 2, body: [0, 0, 0, 0, 0, 0] + le16(111))
        ]
        let batch = HistoryProjection.batch(records, anchor: anchor, now: now)
        #expect(batch.glucose.map(\.mgdl) == [110])
        #expect(batch.glucose.first?.date == now.addingTimeInterval(-300))
        // The dropped record isn't counted as held, so a later sync can fetch it again.
        #expect(batch.sequences == [1])
    }

    @Test func coverageReportsTheMissingWindows() {
        let held = HistoryCoverage(ranges: [1...50, 80...130])
        #expect(held.missing(first: 1, last: 130) == [51...79])
        #expect(HistoryCoverage(ranges: [1...100]).missing(first: 1, last: 130) == [101...130])
        #expect(HistoryCoverage().missing(first: 10, last: 500) == [10...500])
        #expect(HistoryCoverage(ranges: [1...5, 6...9]).ranges == [1...9])
        #expect(HistoryCoverage(ranges: [UInt32.max...UInt32.max, 0...1]).ranges.count == 2)
    }

    @Test func coverageSurvivesASaveAndLoad() throws {
        let held = HistoryCoverage(ranges: [1...50, 80...130])
        let decoded = try JSONDecoder().decode(HistoryCoverage.self, from: JSONEncoder().encode(held))
        #expect(decoded == held)
    }
}

private func readStart(_ cargo: [UInt8]) -> UInt32 {
    (0..<4).reduce(0) { $0 | UInt32(cargo[$1]) << (8 * UInt32($1)) }
}
