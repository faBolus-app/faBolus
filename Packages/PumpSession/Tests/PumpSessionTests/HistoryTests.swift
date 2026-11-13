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
        _ = await rig.run(for: 8, upTo: 120) { await session.syncHistory() }
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

    /// Each request names its batch's newest record, as t:connect and Mobi send it, and asks for 30
    /// records, as Mobi asks.
    @Test func eachRequestNamesItsNewestRecordAndAsksForThirty() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            addGlucoseHistory($0, count: 600)
        })
        await rig.startHeld()
        await sync(rig)
        let last = rig.pump.lastSequence!
        let pages = rig.pump.arrivals(of: HistoryLogRequest.self).map { (readStart($0.cargo), Int($0.cargo[4])) }
        #expect(pages.map(\.0) == Array(stride(from: last, through: last - 570, by: -30)))
        #expect(pages.allSatisfy { $0.1 == 30 })
        #expect(rig.store.load()?.coverage.ranges == [rig.pump.firstHeldSequence!...last])
    }

    /// A sync runs until the phone holds the pump's whole log, as Mobi's does: one sync, however many
    /// requests it takes.
    @Test func aSyncRunsUntilTheWholeLogIsHeld() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            addGlucoseHistory($0, count: 900)
        })
        await rig.startHeld()
        await sync(rig)
        let first = rig.pump.firstHeldSequence!, last = rig.pump.lastSequence!
        #expect(rig.store.load()?.coverage.ranges == [first...last])
        #expect(rig.pump.arrivals(of: HistoryLogRequest.self).count == 30)
        #expect(await rig.session.historySync == .idle(lastSynced: rig.store.load()?.lastHistorySync))
    }

    /// A notice during a sync has the pump's log read again before the next request, so the records the
    /// sync didn't know of come next, newest first, as Mobi reads its latest status before every batch.
    @Test func aNoticeDuringASyncFetchesTheNewRecordsNext() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            addGlucoseHistory($0, count: 300)
            // The sync's first read of the log ends 50 records short, and a notice comes with its first page.
            let first = $0.firstHeldSequence!, last = $0.lastSequence!
            $0.nextAnswers[MessageKey(HistoryLogStatusRequest.self)] = [
                .cargo(le32(250) + le32(first) + le32(last - 50))
            ]
            $0.nextAnswers[MessageKey(HistoryLogRequest.self)] = [.notice(.bolusChange)]
        })
        await rig.startHeld()
        let first = rig.pump.firstHeldSequence!, last = rig.pump.lastSequence!
        let starts = rig.pump.arrivals(of: HistoryLogRequest.self).map { readStart($0.cargo) }
        #expect(Array(starts.prefix(4)) == [last - 50, last, last - 30, last - 80])
        #expect(rig.store.load()?.coverage.ranges == [first...last])
    }

    /// A notice during a sync finds the pump's log restarted: what the phone holds goes, and the restarted
    /// log is fetched from its newest record down.
    @Test func aRestartFoundDuringASyncStartsTheLogOver() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            addGlucoseHistory($0, count: 300)
        })
        await rig.startHeld()
        let first = rig.pump.firstHeldSequence!, last = rig.pump.lastSequence!
        #expect(rig.store.load()?.coverage.ranges == [first...last])
        // The pump's log now ends 100 records lower: it restarted. A notice comes with the sync's first page.
        addGlucoseHistory(rig.pump, count: 10)
        let restartedTop = last - 100
        rig.pump.nextAnswers[MessageKey(HistoryLogStatusRequest.self)] = [
            .normal, .cargo(le32(restartedTop - first + 1) + le32(first) + le32(restartedTop))
        ]
        rig.pump.nextAnswers[MessageKey(HistoryLogRequest.self)] = [.notice(.bolusChange)]
        let before = rig.pump.arrivals(of: HistoryLogRequest.self).count
        await sync(rig)
        let starts = rig.pump.arrivals(of: HistoryLogRequest.self).dropFirst(before).map { readStart($0.cargo) }
        #expect(Array(starts.prefix(2)) == [last + 10, restartedTop])
        #expect(await rig.sink.clears == 1)
        #expect(rig.store.load()?.coverage.ranges == [first...restartedTop])
    }

    /// A search waiting for the history stream goes before the sync's next request; the sync continues
    /// after it.
    @Test func aSearchWaitingForTheHistoryStreamGoesBeforeTheNextRequest() async {
        let rig = Rig(configure: { $0.unsupportedReads = [] })
        await rig.startHeld()
        addGlucoseHistory(rig.pump, count: 300)
        // The sync holds the stream while the pump is slow to say how long its log is.
        rig.pump.nextAnswers[MessageKey(HistoryLogStatusRequest.self)] = [.late(seconds: 2)]
        let statusReads = rig.pump.arrivals(of: HistoryLogStatusRequest.self).count
        let session = rig.session
        let sync = Task { await session.syncHistory() }
        _ = await rig.until { rig.pump.arrivals(of: HistoryLogStatusRequest.self).count > statusReads }
        let search = Task { await session.searchHistory(for: 999, acceptedAt: nil) }
        await rig.run(for: 30, step: 0.5)
        await rig.value(of: sync)
        _ = await rig.value(of: search)
        let counts = rig.pump.arrivals(of: HistoryLogRequest.self).map { Int($0.cargo[4]) }
        #expect(Array(counts.prefix(3)) == [250, 50, 30])
        let first = rig.pump.firstHeldSequence!, last = rig.pump.lastSequence!
        #expect(rig.store.load()?.coverage.ranges == [first...last])
        #expect(await rig.session.historySync == .idle(lastSynced: rig.store.load()?.lastHistorySync))
    }

    /// A pump whose newest record is older than one the phone holds has restarted its log: what the phone
    /// holds goes, logbook included, and the pump's log is fetched again.
    @Test func aPumpWhoseLogRestartedIsFetchedAgain() async {
        var held = PumpSessionRecord(pairing: Rig.pairing)
        held.coverage = HistoryCoverage(ranges: [1000...1599])
        let rig = Rig(
            record: held,
            configure: {
                $0.unsupportedReads = []
                addGlucoseHistory($0, count: 50)
            })
        await rig.startHeld()
        await sync(rig)
        #expect(rig.store.load()?.coverage.ranges == [1000...1049])
        #expect(await rig.sink.clears == 1)
        #expect(Set(await rig.sink.batches.flatMap(\.sequences)) == Set(1000...1049))
    }

    /// The boluses marked before a restart survive a save and load; a record saved before the mark existed
    /// has none.
    @Test func theRestartMarksSurviveASaveAndLoad() throws {
        let key = RemoteBolusLedger.Key(peerId: "phone", requestId: "phone-1")
        let record = PumpSessionRecord(pairing: Rig.pairing, beforeHistoryRestart: [key])
        let data = try JSONEncoder().encode(record)
        #expect(try JSONDecoder().decode(PumpSessionRecord.self, from: data) == record)
        var object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["beforeHistoryRestart"] = nil
        let old = try JSONDecoder().decode(PumpSessionRecord.self, from: JSONSerialization.data(withJSONObject: object))
        #expect(old.beforeHistoryRestart.isEmpty)
        #expect(old.pairing == record.pairing)
    }

    /// A pump that dropped its oldest records hasn't restarted: what the phone holds stays.
    @Test func aPumpThatDroppedItsOldestRecordsKeepsWhatIsHeld() async {
        var held = PumpSessionRecord(pairing: Rig.pairing)
        held.coverage = HistoryCoverage(ranges: [900...1049])
        let rig = Rig(
            record: held,
            configure: {
                $0.unsupportedReads = []
                addGlucoseHistory($0, count: 50)
            })
        await rig.startHeld()
        await sync(rig)
        #expect(rig.store.load()?.coverage.ranges == [900...1049])
        #expect(await rig.sink.clears == 0)
        #expect(rig.pump.arrivals(of: HistoryLogRequest.self).isEmpty)
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

    /// A page asked for while a slow request is on the wire waits for its own request to go out before it is
    /// judged quiet: its records arrive after that request is answered, from one page request.
    @Test func aPageAskedForBehindASlowRequestIsCollectedAfterIt() async {
        let rig = Rig(configure: {
            $0.unsupportedReads = []
            addGlucoseHistory($0, count: 20)
        })
        await rig.startHeld()
        rig.pump.nextAnswers[MessageKey(CurrentEGVGuiDataRequest.self)] = [.late(seconds: 20)]
        let session = rig.session
        let refresh = Task { await session.refreshGlucose() }
        await rig.settle()
        let top = rig.pump.lastSequence!
        let requests = rig.pump.arrivals(of: HistoryLogRequest.self).count
        let page = Task { await session.fetchPage(top: top, count: 20, priority: .history) }
        await rig.run(for: 25)
        #expect(await rig.value(of: page)??.count == 20)
        #expect(rig.pump.arrivals(of: HistoryLogRequest.self).count == requests + 1)
        await rig.value(of: refresh)
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
        // The page fetched before the drop wasn't asked for again: each request names its page's newest record.
        let starts = pump.arrivals(of: HistoryLogRequest.self).map { readStart($0.cargo) }
        #expect(starts.filter { $0 == last }.count == 1)
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
        // Each request names its batch's newest record, the newest window first.
        #expect(starts == [1499, 1469, 1439, 1409, 1199, 1169, 1139, 1109])
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
            if case .pumpFound(let id, let name, .tslimX2, _) = e { return (id, name) }
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

/// The newest record a `HistoryLogRequest` names.
func readStart(_ cargo: [UInt8]) -> UInt32 {
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

/// Mobi's low-power mode: in the background, history syncs stop once the pump's battery is at 20% or
/// below, and start again above 30%; in the foreground they always run.
@MainActor
@Suite struct LowBatteryHistoryTests {
    private func rig(battery: Int) -> Rig {
        Rig(configure: {
            $0.unsupportedReads = []
            $0.batteryPercent = battery
            addGlucoseHistory($0, count: 300)
        })
    }

    @Test func aLowBatteryStopsTheBackgroundSyncUntilTheForeground() async {
        let rig = rig(battery: 20)
        await rig.session.setAppActive(false)
        await rig.startHeld()
        await rig.run(for: 20 * 60, step: 30)
        // The connection's first sync may ask for the log's status before the battery is read; it stops
        // before any page.
        #expect(rig.pump.arrivals(of: HistoryLogRequest.self).isEmpty)
        #expect(rig.store.load()?.coverage.ranges.isEmpty ?? true)
        await rig.session.setAppActive(true)
        await rig.run(for: 30, step: 1)
        let first = rig.pump.firstHeldSequence!, last = rig.pump.lastSequence!
        #expect(rig.store.load()?.coverage.ranges == [first...last])
    }

    @Test func theBackgroundSyncResumesOnlyAboveThirtyPercent() async {
        let rig = rig(battery: 15)
        await rig.session.setAppActive(false)
        await rig.startHeld()
        await rig.run(for: 60, step: 5)
        rig.pump.batteryPercent = 30
        await rig.run(for: 20 * 60, step: 30)
        #expect(rig.pump.arrivals(of: HistoryLogRequest.self).isEmpty, "30% isn't above 30%")
        rig.pump.batteryPercent = 31
        await rig.run(for: 20 * 60, step: 30)
        let first = rig.pump.firstHeldSequence!, last = rig.pump.lastSequence!
        #expect(rig.store.load()?.coverage.ranges == [first...last])
    }

    @Test func aBatteryAboveTheLevelSyncsInTheBackground() async {
        let rig = rig(battery: 21)
        await rig.session.setAppActive(false)
        await rig.startHeld()
        await rig.run(for: 60, step: 5)
        let first = rig.pump.firstHeldSequence!, last = rig.pump.lastSequence!
        #expect(rig.store.load()?.coverage.ranges == [first...last])
    }
}
