import XCTest
import faBolusCore
@testable import HistoryStore

@MainActor
final class HistoryStoreTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> GlucoseHistoryStore { try GlucoseHistoryStore(inMemory: true) }

    func testPersistAndQueryGlucose() throws {
        let store = try makeStore()
        store.ingestGlucose(
            [
                GlucoseReading(date: t0, mgdl: 120),
                GlucoseReading(date: t0.addingTimeInterval(300), mgdl: 130)
            ],
            sourceID: "dexcomG7", priority: 100)
        let out = store.glucose(in: t0.addingTimeInterval(-60)...t0.addingTimeInterval(600))
        XCTAssertEqual(out.map(\.mgdl), [120, 130])
    }

    func testHigherPrioritySourceWinsSameSlot() throws {
        let store = try makeStore()
        // Same 5-min slot from two sources: the higher-priority (local BLE) must win over the cloud follow.
        store.ingestGlucose([GlucoseReading(date: t0, mgdl: 100)], sourceID: "nightscout", priority: 30)
        store.ingestGlucose(
            [GlucoseReading(date: t0.addingTimeInterval(60), mgdl: 142)], sourceID: "dexcomG7", priority: 100)
        let out = store.glucose(in: t0.addingTimeInterval(-300)...t0.addingTimeInterval(300))
        XCTAssertEqual(out.count, 1, "one reading per 5-min slot")
        XCTAssertEqual(out[0].mgdl, 142, "higher-priority source wins")
    }

    func testRecencyBreaksTieSamePriority() throws {
        let store = try makeStore()
        store.ingestGlucose(
            [GlucoseReading(date: t0, mgdl: 100)], sourceID: "nightscout", priority: 30,
            recordedAt: t0)
        store.ingestGlucose(
            [GlucoseReading(date: t0.addingTimeInterval(60), mgdl: 110)], sourceID: "nightscout",
            priority: 30, recordedAt: t0.addingTimeInterval(3600))
        let out = store.glucose(in: t0.addingTimeInterval(-300)...t0.addingTimeInterval(300))
        XCTAssertEqual(out[0].mgdl, 110, "later recordedAt wins the tie")
    }

    /// The logbook's events are kept once per sequence number, read newest first, and survive reopening
    /// the store; clearing one source leaves the others.
    func testHistoryEventsPersistOncePerSequenceAndClearBySource() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("history.store")
        let older = HistoryEvent(id: 7, date: t0, category: .autoCorrection, title: "Control-IQ auto-corrected")
        let newer = HistoryEvent(
            id: 8, date: t0.addingTimeInterval(60), category: .bolus, title: "Bolus", detail: "1 U")
        do {
            let store = try GlucoseHistoryStore(url: url)
            try store.ingestPumpHistory(
                glucose: [], boluses: [], carbs: [], events: [older, newer], sourceID: "pump", glucosePriority: 50)
            try store.ingestPumpHistory(
                glucose: [], boluses: [], carbs: [], events: [newer], sourceID: "pump", glucosePriority: 50)
            try store.ingestPumpHistory(
                glucose: [], boluses: [], carbs: [], events: [older], sourceID: "other", glucosePriority: 50)
        }
        let reopened = try GlucoseHistoryStore(url: url)
        XCTAssertEqual(try reopened.historyEvents(sourceID: "pump", limit: 10), [newer, older])
        XCTAssertEqual(try reopened.historyEvents(sourceID: "pump", limit: 1), [newer])
        try reopened.clearHistoryEvents(sourceID: "pump")
        XCTAssertEqual(try reopened.historyEvents(sourceID: "pump", limit: 10), [])
        XCTAssertEqual(try reopened.historyEvents(sourceID: "other", limit: 10), [older])
    }

    /// A source keeps only its newest `eventLimit` events; records sharing a time come back later record
    /// first, the order the session keeps in memory.
    func testHistoryEventsAreTrimmedToTheLimitAndTiesGoBySequence() throws {
        let store = try makeStore()
        let events = (1...5).map { i in
            HistoryEvent(
                id: UInt32(i), date: t0.addingTimeInterval(i <= 2 ? 0 : Double(i) * 60), category: .bolus, title: "\(i)"
            )
        }
        try store.ingestPumpHistory(
            glucose: [], boluses: [], carbs: [], events: events, eventLimit: 4, sourceID: "pump", glucosePriority: 50)
        XCTAssertEqual(try store.historyEvents(sourceID: "pump", limit: 10).map(\.id), [5, 4, 3, 2])
        XCTAssertEqual(events.sorted(by: HistoryEvent.newestFirst).map(\.id), [5, 4, 3, 2, 1])
    }

    func testTimeInRange() throws {
        let store = try makeStore()
        // 8 in-range (120) + 2 low (50) over distinct 5-min slots → 80% TIR.
        var readings: [GlucoseReading] = []
        for i in 0..<8 { readings.append(GlucoseReading(date: t0.addingTimeInterval(Double(i) * 300), mgdl: 120)) }
        for i in 8..<10 { readings.append(GlucoseReading(date: t0.addingTimeInterval(Double(i) * 300), mgdl: 50)) }
        store.ingestGlucose(readings, sourceID: "dexcomG7", priority: 100)
        let stats = store.statistics(in: t0.addingTimeInterval(-60)...t0.addingTimeInterval(3000))
        XCTAssertEqual(stats.count, 10)
        XCTAssertEqual(stats.timeInRangePct, 80, accuracy: 0.1)
    }

    func testClearAndRetention() throws {
        let store = try makeStore()
        store.ingestGlucose(
            [GlucoseReading(date: t0.addingTimeInterval(-40 * 86400), mgdl: 100)],  // old
            sourceID: "dexcomG7", priority: 100)
        store.ingestGlucose([GlucoseReading(date: t0, mgdl: 120)], sourceID: "dexcomG7", priority: 100)  // recent
        XCTAssertEqual(store.glucoseCount(), 2)

        store.deleteGlucose(olderThan: t0.addingTimeInterval(-30 * 86400))
        XCTAssertEqual(store.glucoseCount(), 1, "auto-delete drops the >30-day-old reading")

        store.clear()
        XCTAssertEqual(store.glucoseCount(), 0, "clear wipes everything")
    }

    func testBolusesPersist() throws {
        let store = try makeStore()
        store.ingestBoluses([BolusMarker(date: t0, units: 4.5)], sourceID: "pump")
        XCTAssertEqual(store.boluses(in: t0.addingTimeInterval(-60)...t0.addingTimeInterval(60)).first?.units, 4.5)
    }

    /// Writing the same pump history twice (a retried sync) keeps one bolus and one carb entry.
    func testPumpHistoryWrittenTwiceIsKeptOnce() throws {
        let store = try makeStore()
        let range = t0.addingTimeInterval(-600)...t0.addingTimeInterval(600)
        // The second write's times are a fraction of a second off, as a re-anchored pump clock places them.
        for shift in [0, 0.4] {
            let at = t0.addingTimeInterval(shift)
            try store.ingestPumpHistory(
                glucose: [GlucoseReading(date: at, mgdl: 140)], boluses: [BolusMarker(date: at, units: 2)],
                carbs: [(date: at, grams: 30)], sourceID: "pump", glucosePriority: 50)
        }
        XCTAssertEqual(store.boluses(in: range).count, 1)
        XCTAssertEqual(store.carbs(in: range).count, 1)
        XCTAssertEqual(store.glucose(in: range).count, 1)
    }

    func testCarbsPersist() throws {
        let store = try makeStore()
        store.ingestCarbs([(date: t0, grams: 45)], sourceID: "fabolus")
        let c = store.carbs(in: t0.addingTimeInterval(-60)...t0.addingTimeInterval(60))
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c.first?.grams, 45)
    }

    // MARK: - CR-01: excludingSourceIDs — the HealthKit-export echo-guard's building block

    func testCarbsExcludingSourceIDsDropsMatchingRowsOnly() throws {
        let store = try makeStore()
        store.ingestCarbs([(date: t0, grams: 30)], sourceID: "healthkit-import")
        store.ingestCarbs([(date: t0.addingTimeInterval(60), grams: 45)], sourceID: "fabolus")
        let range = t0.addingTimeInterval(-60)...t0.addingTimeInterval(300)

        let unfiltered = store.carbs(in: range)
        XCTAssertEqual(unfiltered.count, 2, "default excludingSourceIDs is empty — existing callers unchanged")

        let filtered = store.carbs(in: range, excludingSourceIDs: ["healthkit-import"])
        XCTAssertEqual(filtered.map(\.grams), [45], "the healthkit-import row must be excluded, the rest kept")
    }

    func testBolusesExcludingSourceIDsDropsMatchingRowsOnly() throws {
        let store = try makeStore()
        store.ingestBoluses([BolusMarker(date: t0, units: 2.4)], sourceID: "healthkit-import")
        store.ingestBoluses([BolusMarker(date: t0.addingTimeInterval(60), units: 4.5)], sourceID: "pump")
        let range = t0.addingTimeInterval(-60)...t0.addingTimeInterval(300)

        XCTAssertEqual(store.boluses(in: range).count, 2)
        let filtered = store.boluses(in: range, excludingSourceIDs: ["healthkit-import"])
        XCTAssertEqual(filtered.map(\.units), [4.5], "the healthkit-import row must be excluded, the rest kept")
    }

    func testGlucoseExcludingSourceIDsDropsMatchingRowsBeforeThePrioritySlotMerge() throws {
        let store = try makeStore()
        // Distinct 5-min slots so both rows would otherwise survive the merge independently.
        store.ingestGlucose([GlucoseReading(date: t0, mgdl: 130)], sourceID: "healthkit-import", priority: 10)
        store.ingestGlucose(
            [GlucoseReading(date: t0.addingTimeInterval(600), mgdl: 145)], sourceID: "dexcomG7",
            priority: 100)
        let range = t0.addingTimeInterval(-60)...t0.addingTimeInterval(900)

        XCTAssertEqual(store.glucose(in: range).count, 2)
        let filtered = store.glucose(in: range, excludingSourceIDs: ["healthkit-import"])
        XCTAssertEqual(filtered.map(\.mgdl), [145], "the healthkit-import reading must be excluded, the rest kept")
    }

}
