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

    /// A carb entry in the pump's history becomes carbs in the store. The record's body is pumpx2's
    /// CarbEnteredHistoryLog capture (45 g), stamped five minutes ago.
    @Test func aCarbEntryInHistoryIsStoredAsCarbs() async throws {
        let captured: [UInt8] = [
            0x30, 0x00, 0xce, 0xa4, 0x97, 0x1a, 0xd1, 0xd6, 0x02, 0x00, 0x00, 0x00, 0x34, 0x42, 0x00, 0x00, 0x00,
            0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00
        ]
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            _ = $0.appendHistory(typeId: 48, at: $0.wallClockAtStart - 300, body: Array(captured[10...]))
        })
        await rig.startHeld()
        let entered = rig.clock.date.addingTimeInterval(-300 - rig.clock.now)
        await sync(rig)
        let carbs = await rig.sink.batches.flatMap(\.carbs)
        #expect(carbs.map(\.grams) == [45])
        let date = try #require(carbs.first?.date)
        #expect(abs(date.timeIntervalSince(entered)) < 2)
    }

    /// A page asked for during a comms-suspended pause (a sync's next page, a search for a bolus) waits
    /// for its request to go out before it is judged quiet: its records arrive after the pause, from one
    /// request.
    @Test func aPageAskedForDuringAPauseIsCollectedAfterIt() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            addGlucoseHistory($0, count: 20)
        })
        await rig.startHeld()
        rig.transport.qualifyingEvents(.pumpCommunicationsSuspended)
        await rig.settle()
        let session = rig.session
        let start = rig.pump.firstHeldSequence!
        let requests = rig.pump.arrivals(of: HistoryLogRequest.self).count
        let page = Task { await session.fetchPage(start: start, count: 20, priority: .history) }
        await rig.run(for: 8)
        #expect(await page.value?.count == 20)
        #expect(rig.pump.arrivals(of: HistoryLogRequest.self).count == requests + 1)
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

    /// The logbook is saved with the history it came from, so a relaunch shows it at once, before any sync
    /// (history the phone holds isn't fetched again). Forgetting the pump removes it, in memory and saved.
    @Test func theLogbookComesBackAfterARelaunchAndGoesWhenThePumpIsForgotten() async {
        let sink = RecordingSink()
        let addRecords: (ScriptedPump) -> Void = { pump in
            pump.unsupportedReads = []
            // A Control-IQ auto-correction (280, source 7) and a rejected auto-bolus (288).
            _ = pump.appendHistory(
                typeId: 280, at: pump.wallClockAtStart - 600,
                body: le16(12) + [0, 0, 7, 0] + [UInt8](repeating: 0, count: 12))
            _ = pump.appendHistory(typeId: 288, at: pump.wallClockAtStart - 300, body: [])
        }
        let rig = Rig(sink: sink, configure: addRecords)
        await rig.startHeld()
        await sync(rig)
        let events = await rig.session.historyEvents
        #expect(events.map(\.category) == [.couldNotDeliver, .autoCorrection])
        await rig.stop()

        let relaunched = Rig(record: rig.store.load(), sink: sink, configure: addRecords)
        await relaunched.start()
        #expect(await relaunched.session.historyEvents == events)
        #expect(relaunched.pump.arrivals(of: HistoryLogRequest.self).isEmpty)

        await relaunched.session.forgetPairing()
        #expect(await relaunched.session.historyEvents.isEmpty)
        #expect(await sink.loadEvents(limit: 500).isEmpty)
        await relaunched.stop()
    }

    /// A new pairing starts its logbook empty, in memory and saved: its history is fetched again from the
    /// start, and the last pump's events would hide the new one's records that share sequence numbers.
    @Test func aNewPairingStartsWithAnEmptyLogbook() async throws {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            _ = $0.appendHistory(typeId: 288, at: $0.wallClockAtStart - 300, body: [])
        })
        await rig.startHeld()
        await sync(rig)
        #expect(await !rig.session.historyEvents.isEmpty)
        await rig.session.scanForPairing()
        await rig.settle()
        let found = await rig.events.compactMap { e -> (UUID, String?)? in
            if case .pumpFound(let id, let name, .tslimX2) = e { return (id, name) }
            return nil
        }
        let pump = try #require(found.first)
        try await rig.session.pair(peripheralID: pump.0, advertisedName: pump.1, code: ScriptedPump.code)
        await rig.settle()
        #expect(rig.store.load()?.coverage.ranges.isEmpty == true)
        #expect(await rig.session.historyEvents.isEmpty)
        #expect(await rig.sink.loadEvents(limit: 500).isEmpty)
        await rig.stop()
    }

    /// With no pump paired, a launch shows no logbook and drops one left saved by a forget that couldn't
    /// delete it.
    @Test func aLaunchWithNoPumpDropsASavedLogbook() async {
        let sink = RecordingSink()
        try? await sink.record(
            PumpHistoryBatch(events: [HistoryEvent(id: 1, date: Date(), category: .bolus, title: "Bolus")]))
        let rig = Rig(paired: false, sink: sink)
        await rig.start()
        #expect(await rig.session.historyEvents.isEmpty)
        #expect(await sink.loadEvents(limit: 500).isEmpty)
        await rig.stop()
    }

    /// The logbook names each Control-IQ and calculator record for what it is: an automatic correction
    /// (a bolus whose source is Control-IQ), an automatic bolus the pump rejected, and a calculator
    /// correction the user declined, which isn't Control-IQ.
    @Test func controlIQAndCalculatorRecordsAreLabelledForWhatTheyAre() {
        let anchor = PumpClockAnchor(pumpTime: 1_000_000, phoneTime: Date(timeIntervalSince1970: 1_800_000_000))
        let iob = withUnsafeBytes(of: Float(1.5).bitPattern.littleEndian, Array.init)
        let records = [
            // BolusDelivery (280), bolus 12, source 7.
            ScriptedPump.record(
                typeId: 280, pumpTime: 1_000_000 - 30, sequence: 3,
                body: le16(12) + [0, 0, 7, 0] + [UInt8](repeating: 0, count: 12)),
            // AA Auto Bolus Rejected (288).
            ScriptedPump.record(typeId: 288, pumpTime: 1_000_000 - 20, sequence: 4, body: []),
            // Correction Declined (93): BG 180, bolus 13, IOB 1.5, target 110, ISF 40.
            ScriptedPump.record(
                typeId: 93, pumpTime: 1_000_000 - 10, sequence: 5,
                body: le16(180) + le16(13) + iob + le16(110) + le16(40))
        ]
        let events = HistoryProjection.batch(records, anchor: anchor, now: anchor.phoneTime).events
        #expect(
            events.map(\.title) == [
                "Correction declined", "Control-IQ auto-bolus rejected", "Control-IQ auto-corrected"
            ])
        #expect(events.map(\.category) == [.bolus, .couldNotDeliver, .autoCorrection])
        #expect(events.first?.detail == "BG 180 mg/dL")
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

/// The logbook names an alert as the live alert does: Control-IQ's high alert (#50), which TandemKit
/// leaves unnamed, gets Tandem's copy there too; another unnamed alert keeps its id.
@Suite struct HistoryAlertNameTests {
    private func activated(_ alertId: UInt32) -> AlertActivatedHistoryLog {
        var raw = [UInt8](repeating: 0, count: 26)
        for i in 0..<4 { raw[10 + i] = UInt8((alertId >> (8 * UInt32(i))) & 0xFF) }
        return AlertActivatedHistoryLog(cargo: raw)
    }

    @Test func controlIQsHighAlertIsNamedInTheLogbook() throws {
        let event = try #require(HistoryProjection.event(activated(50), date: Date()))
        #expect(event.title == "Control-IQ high")
        #expect(event.detail.contains("Test your blood glucose"))
    }

    @Test func anotherUnnamedAlertKeepsItsId() throws {
        let unnamed = try #require((0..<64).first { AlertStatusResponse.name(for: $0) == nil && $0 != 50 })
        let event = try #require(HistoryProjection.event(activated(UInt32(unnamed)), date: Date()))
        #expect(event.title == "Alert")
        #expect(event.detail == "id \(unnamed)")
    }
}
