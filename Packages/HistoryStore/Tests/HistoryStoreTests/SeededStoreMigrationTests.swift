import XCTest
import SwiftData
import faBolusCore
@testable import HistoryStore

/// The deletion gate for the SwiftData 7→3 entity removal (StoredSite / StoredCaffeine /
/// StoredAlcohol / StoredHeartRate): proves the destructive lightweight migration does not silently
/// yield an open store with zero rows. Every other test in this package constructs
/// `GlucoseHistoryStore(inMemory: true)`, so nothing else here has ever opened a real on-disk
/// container — a `try?` at the store's call site cannot tell "opened, empty" apart from
/// "opened, unchanged".
///
/// Seeds a real on-disk container declaring the CURRENT full entity set, then reopens the SAME file
/// with a container declaring only the survivor entities, and asserts the survivor rows are still
/// readable. The 4 removed entities no longer exist in `HistoryStore`, so the seed step declares
/// local shadow `@Model` types below, same class names as the production types they stand in for, so
/// SwiftData derives the same on-disk table names and the seed is a genuine 7-table store.
@Model private final class StoredSite {
    var siteID: String
    var kind: String
    var bodySide: String
    var normalizedX: Double
    var normalizedY: Double
    var note: String?
    var date: Date
    var sourceID: String
    var recordedAt: Date
    init(siteID: String, kind: String, bodySide: String,
         normalizedX: Double, normalizedY: Double, note: String?,
         date: Date, sourceID: String, recordedAt: Date) {
        self.siteID = siteID; self.kind = kind; self.bodySide = bodySide
        self.normalizedX = normalizedX; self.normalizedY = normalizedY
        self.note = note
        self.date = date; self.sourceID = sourceID; self.recordedAt = recordedAt
    }
}

@Model private final class StoredCaffeine {
    var entryID: String
    var milligrams: Double
    var source: String
    var date: Date
    var sourceID: String
    var recordedAt: Date
    init(entryID: String, milligrams: Double, source: String,
         date: Date, sourceID: String, recordedAt: Date) {
        self.entryID = entryID; self.milligrams = milligrams; self.source = source
        self.date = date; self.sourceID = sourceID; self.recordedAt = recordedAt
    }
}

@Model private final class StoredAlcohol {
    var entryID: String
    var standardDrinks: Double
    var source: String
    var date: Date
    var sourceID: String
    var recordedAt: Date
    init(entryID: String, standardDrinks: Double, source: String,
         date: Date, sourceID: String, recordedAt: Date) {
        self.entryID = entryID; self.standardDrinks = standardDrinks; self.source = source
        self.date = date; self.sourceID = sourceID; self.recordedAt = recordedAt
    }
}

@Model private final class StoredHeartRate {
    var entryID: String
    var bpm: Double
    var source: String
    var date: Date
    var sourceID: String
    var recordedAt: Date
    init(entryID: String, bpm: Double, source: String,
         date: Date, sourceID: String, recordedAt: Date) {
        self.entryID = entryID; self.bpm = bpm; self.source = source
        self.date = date; self.sourceID = sourceID; self.recordedAt = recordedAt
    }
}

@MainActor
final class SeededStoreMigrationTests: XCTestCase {
    private func makeTempStoreURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("seeded-store-migration-\(UUID().uuidString)")
            .appendingPathExtension("store")
    }

    private func removeStoreFiles(at url: URL) {
        let fm = FileManager.default
        for suffix in ["", "-wal", "-shm"] {
            try? fm.removeItem(atPath: url.path + suffix)
        }
    }

    func testSurvivorRowsReadableAfterDestructiveEntityRemoval() throws {
        let url = makeTempStoreURL()
        defer { removeStoreFiles(at: url) }
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)

        // Seed: a real on-disk container declaring every current @Model type, one row each.
        do {
            let config = ModelConfiguration(url: url)
            let container = try ModelContainer(for: StoredGlucose.self, StoredBolus.self, StoredCarb.self,
                                                StoredSite.self, StoredCaffeine.self, StoredAlcohol.self,
                                                StoredHeartRate.self,
                                                configurations: config)
            let context = container.mainContext
            context.insert(StoredGlucose(date: t0, mgdl: 120, sourceID: "dexcomG7", priority: 100, recordedAt: t0))
            context.insert(StoredBolus(date: t0, units: 4.5, sourceID: "pump", recordedAt: t0))
            context.insert(StoredCarb(date: t0, grams: 45, sourceID: "fabolus", recordedAt: t0))
            context.insert(StoredSite(siteID: "site-1", kind: "pump", bodySide: "front",
                                       normalizedX: 0.5, normalizedY: 0.4, note: nil,
                                       date: t0, sourceID: "fabolus", recordedAt: t0))
            context.insert(StoredCaffeine(entryID: "c1", milligrams: 95, source: "Coffee",
                                           date: t0, sourceID: "fabolus", recordedAt: t0))
            context.insert(StoredAlcohol(entryID: "a1", standardDrinks: 1, source: "Wine",
                                          date: t0, sourceID: "fabolus", recordedAt: t0))
            context.insert(StoredHeartRate(entryID: "h1", bpm: 72, source: "healthkit",
                                           date: t0, sourceID: "healthkit", recordedAt: t0))
            try context.save()

            // Non-vacuity: the seed itself must have written rows, so a silently-empty seed can't
            // make the reopen assertions below pass trivially.
            XCTAssertGreaterThan(try context.fetchCount(FetchDescriptor<StoredGlucose>()), 0)
            XCTAssertGreaterThan(try context.fetchCount(FetchDescriptor<StoredBolus>()), 0)
            XCTAssertGreaterThan(try context.fetchCount(FetchDescriptor<StoredCarb>()), 0)
            XCTAssertGreaterThan(try context.fetchCount(FetchDescriptor<StoredSite>()), 0)
            XCTAssertGreaterThan(try context.fetchCount(FetchDescriptor<StoredCaffeine>()), 0)
            XCTAssertGreaterThan(try context.fetchCount(FetchDescriptor<StoredAlcohol>()), 0)
            XCTAssertGreaterThan(try context.fetchCount(FetchDescriptor<StoredHeartRate>()), 0)
        }

        // Reopen the SAME on-disk file with a container declaring ONLY the survivor entities.
        let reopenConfig = ModelConfiguration(url: url)
        let reopenedContainer = try ModelContainer(for: StoredGlucose.self, StoredBolus.self, StoredCarb.self,
                                                    configurations: reopenConfig)
        let reopenedContext = reopenedContainer.mainContext

        let glucoseRows = try reopenedContext.fetch(FetchDescriptor<StoredGlucose>())
        let bolusRows = try reopenedContext.fetch(FetchDescriptor<StoredBolus>())
        let carbRows = try reopenedContext.fetch(FetchDescriptor<StoredCarb>())

        XCTAssertEqual(glucoseRows.count, 1, "the glucose row must survive the destructive migration")
        XCTAssertEqual(glucoseRows.first?.mgdl, 120)
        XCTAssertEqual(bolusRows.count, 1, "the bolus row must survive the destructive migration")
        XCTAssertEqual(try XCTUnwrap(bolusRows.first).units, 4.5, accuracy: 1e-9)
        XCTAssertEqual(carbRows.count, 1, "the carb row must survive the destructive migration")
        XCTAssertEqual(try XCTUnwrap(carbRows.first).grams, 45, accuracy: 1e-9)
    }
}
