import XCTest
import faBolusCore
@testable import HistoryStore

@MainActor
final class HistoryStoreTests: XCTestCase {
    let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> GlucoseHistoryStore { try GlucoseHistoryStore(inMemory: true) }

    func testPersistAndQueryGlucose() throws {
        let store = try makeStore()
        store.ingestGlucose([GlucoseReading(date: t0, mgdl: 120),
                             GlucoseReading(date: t0.addingTimeInterval(300), mgdl: 130)],
                            sourceID: "dexcomG7", priority: 100)
        let out = store.glucose(in: t0.addingTimeInterval(-60)...t0.addingTimeInterval(600))
        XCTAssertEqual(out.map(\.mgdl), [120, 130])
    }

    func testHigherPrioritySourceWinsSameSlot() throws {
        let store = try makeStore()
        // Same 5-min slot from two sources: the higher-priority (local BLE) must win over the cloud follow.
        store.ingestGlucose([GlucoseReading(date: t0, mgdl: 100)], sourceID: "nightscout", priority: 30)
        store.ingestGlucose([GlucoseReading(date: t0.addingTimeInterval(60), mgdl: 142)], sourceID: "dexcomG7", priority: 100)
        let out = store.glucose(in: t0.addingTimeInterval(-300)...t0.addingTimeInterval(300))
        XCTAssertEqual(out.count, 1, "one reading per 5-min slot")
        XCTAssertEqual(out[0].mgdl, 142, "higher-priority source wins")
    }

    func testRecencyBreaksTieSamePriority() throws {
        let store = try makeStore()
        store.ingestGlucose([GlucoseReading(date: t0, mgdl: 100)], sourceID: "nightscout", priority: 30,
                            recordedAt: t0)
        store.ingestGlucose([GlucoseReading(date: t0.addingTimeInterval(60), mgdl: 110)], sourceID: "nightscout",
                            priority: 30, recordedAt: t0.addingTimeInterval(3600))
        let out = store.glucose(in: t0.addingTimeInterval(-300)...t0.addingTimeInterval(300))
        XCTAssertEqual(out[0].mgdl, 110, "later recordedAt wins the tie")
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
        store.ingestGlucose([GlucoseReading(date: t0.addingTimeInterval(-40 * 86400), mgdl: 100)],  // old
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

    func testCarbsPersist() throws {
        let store = try makeStore()
        store.ingestCarbs([(date: t0, grams: 45)], sourceID: "fabolus")
        let c = store.carbs(in: t0.addingTimeInterval(-60)...t0.addingTimeInterval(60))
        XCTAssertEqual(c.count, 1)
        XCTAssertEqual(c.first?.grams, 45)
    }
}
