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

    // MARK: SiteAtlas (09.18a-01, D-10)

    func testSiteRoundTrip() throws {
        let store = try makeStore()
        store.ingestSite(siteID: "site-1", kind: "pump", bodySide: "front",
                         normalizedX: 0.58, normalizedY: 0.44, note: "left abdomen",
                         date: t0, sourceID: "fabolus", recordedAt: t0)
        let sites = store.allSites()
        XCTAssertEqual(sites.count, 1)
        let s = try XCTUnwrap(sites.first)
        XCTAssertEqual(s.siteID, "site-1")
        XCTAssertEqual(s.kind, "pump")
        XCTAssertEqual(s.bodySide, "front")
        XCTAssertEqual(s.normalizedX, 0.58, accuracy: 1e-9)
        XCTAssertEqual(s.normalizedY, 0.44, accuracy: 1e-9)
        XCTAssertEqual(s.note, "left abdomen")
        XCTAssertEqual(s.date, t0)
        XCTAssertEqual(s.sourceID, "fabolus")
        XCTAssertEqual(s.recordedAt, t0)
    }

    func testSitePumpAndSensorInsertThenDeleteOne() throws {
        let store = try makeStore()
        store.ingestSite(siteID: "pump-1", kind: "pump", bodySide: "front",
                         normalizedX: 0.5, normalizedY: 0.4, note: nil,
                         date: t0, sourceID: "fabolus", recordedAt: t0)
        store.ingestSite(siteID: "sensor-1", kind: "sensor", bodySide: "back",
                         normalizedX: 0.22, normalizedY: 0.30, note: nil,
                         date: t0.addingTimeInterval(60), sourceID: "fabolus", recordedAt: t0)
        XCTAssertEqual(store.allSites().count, 2)
        // sorted by date desc → the later-dated sensor comes first.
        XCTAssertEqual(store.allSites().map(\.siteID), ["sensor-1", "pump-1"])

        store.deleteSite(id: "pump-1")
        let remaining = store.allSites()
        XCTAssertEqual(remaining.count, 1, "delete by siteID removes exactly one row")
        XCTAssertEqual(remaining.first?.siteID, "sensor-1", "the other site remains")
    }

    func testSitesInRangeFilters() throws {
        let store = try makeStore()
        store.ingestSite(siteID: "old", kind: "pump", bodySide: "front",
                         normalizedX: 0.5, normalizedY: 0.4, note: nil,
                         date: t0.addingTimeInterval(-40 * 86400), sourceID: "fabolus", recordedAt: t0)
        store.ingestSite(siteID: "recent", kind: "sensor", bodySide: "back",
                         normalizedX: 0.5, normalizedY: 0.4, note: nil,
                         date: t0, sourceID: "fabolus", recordedAt: t0)
        let inWindow = store.sites(in: t0.addingTimeInterval(-7 * 86400)...t0.addingTimeInterval(60))
        XCTAssertEqual(inWindow.map(\.siteID), ["recent"])
    }

    func testClearWipesSites() throws {
        let store = try makeStore()
        store.ingestSite(siteID: "s", kind: "pump", bodySide: "front",
                         normalizedX: 0.5, normalizedY: 0.4, note: nil,
                         date: t0, sourceID: "fabolus", recordedAt: t0)
        XCTAssertEqual(store.allSites().count, 1)
        store.clear()
        XCTAssertEqual(store.allSites().count, 0, "clear() wipes site PHI too (data-minimization)")
    }

    // MARK: Caffeine / Alcohol benign trackers (09.18d-02, D-14/D-17)

    func testCaffeineRoundTrip() throws {
        let store = try makeStore()
        store.ingestCaffeine(entryID: "c1", milligrams: 95, source: "Coffee",
                             date: t0, sourceID: "fabolus", recordedAt: t0)
        let rows = store.caffeine(in: t0.addingTimeInterval(-60)...t0.addingTimeInterval(60))
        XCTAssertEqual(rows.count, 1)
        let c = try XCTUnwrap(rows.first)
        XCTAssertEqual(c.entryID, "c1")
        XCTAssertEqual(c.milligrams, 95, accuracy: 1e-9)
        XCTAssertEqual(c.source, "Coffee")
        XCTAssertEqual(c.date, t0)
        XCTAssertEqual(c.sourceID, "fabolus")
        XCTAssertEqual(c.recordedAt, t0)
    }

    func testCaffeineInsertThenDeleteOne() throws {
        let store = try makeStore()
        store.ingestCaffeine(entryID: "c1", milligrams: 95, source: "Coffee",
                             date: t0, sourceID: "fabolus", recordedAt: t0)
        store.ingestCaffeine(entryID: "c2", milligrams: 40, source: "Tea",
                             date: t0.addingTimeInterval(60), sourceID: "fabolus", recordedAt: t0)
        let window = t0.addingTimeInterval(-60)...t0.addingTimeInterval(120)
        XCTAssertEqual(store.caffeine(in: window).count, 2)
        // sorted by date desc → the later "c2" comes first.
        XCTAssertEqual(store.caffeine(in: window).map(\.entryID), ["c2", "c1"])
        store.deleteCaffeine(id: "c1")
        let remaining = store.caffeine(in: window)
        XCTAssertEqual(remaining.count, 1, "delete by entryID removes exactly one row")
        XCTAssertEqual(remaining.first?.entryID, "c2", "the other entry remains")
    }

    func testCaffeineInRangeFilters() throws {
        let store = try makeStore()
        store.ingestCaffeine(entryID: "old", milligrams: 60, source: "Cola",
                             date: t0.addingTimeInterval(-40 * 86400), sourceID: "fabolus", recordedAt: t0)
        store.ingestCaffeine(entryID: "recent", milligrams: 95, source: "Coffee",
                             date: t0, sourceID: "fabolus", recordedAt: t0)
        let inWindow = store.caffeine(in: t0.addingTimeInterval(-7 * 86400)...t0.addingTimeInterval(60))
        XCTAssertEqual(inWindow.map(\.entryID), ["recent"])
    }

    func testAlcoholRoundTripAndDelete() throws {
        let store = try makeStore()
        store.ingestAlcohol(entryID: "a1", standardDrinks: 1.5, source: "Wine",
                            date: t0, sourceID: "fabolus", recordedAt: t0)
        store.ingestAlcohol(entryID: "a2", standardDrinks: 1.0, source: "Beer",
                            date: t0.addingTimeInterval(60), sourceID: "fabolus", recordedAt: t0)
        let window = t0.addingTimeInterval(-60)...t0.addingTimeInterval(120)
        let rows = store.alcohol(in: window)
        XCTAssertEqual(rows.count, 2)
        // sorted by date desc.
        XCTAssertEqual(rows.map(\.entryID), ["a2", "a1"])
        let a = try XCTUnwrap(rows.last)
        XCTAssertEqual(a.entryID, "a1")
        XCTAssertEqual(a.standardDrinks, 1.5, accuracy: 1e-9)
        XCTAssertEqual(a.source, "Wine")
        XCTAssertEqual(a.date, t0)
        store.deleteAlcohol(id: "a2")
        XCTAssertEqual(store.alcohol(in: window).map(\.entryID), ["a1"])
    }

    func testClearWipesTrackers() throws {
        let store = try makeStore()
        store.ingestCaffeine(entryID: "c", milligrams: 95, source: "Coffee",
                             date: t0, sourceID: "fabolus", recordedAt: t0)
        store.ingestAlcohol(entryID: "a", standardDrinks: 1, source: "Beer",
                            date: t0, sourceID: "fabolus", recordedAt: t0)
        let window = t0.addingTimeInterval(-60)...t0.addingTimeInterval(60)
        XCTAssertEqual(store.caffeine(in: window).count, 1)
        XCTAssertEqual(store.alcohol(in: window).count, 1)
        store.clear()
        XCTAssertEqual(store.caffeine(in: window).count, 0, "clear() wipes caffeine PHI too")
        XCTAssertEqual(store.alcohol(in: window).count, 0, "clear() wipes alcohol PHI too")
    }
}
