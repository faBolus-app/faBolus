import Foundation
import SwiftData
import XCTest
import faBolusCore

@testable import HistoryStore

/// The pump's basal rate changes, suspends and resumes, kept for the chart's basal line.
@MainActor
final class DeliveryChangeStoreTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func at(_ minutes: Double) -> Date { t0.addingTimeInterval(minutes * 60) }

    private func write(_ store: GlucoseHistoryStore, _ changes: [DeliveryChange]) throws {
        try store.ingestPumpHistory(
            glucose: [], boluses: [], carbs: [], deliveryChanges: changes, sourceID: "pump", glucosePriority: 50)
    }

    func testTheWindowGetsItsChangesAndWhatWasInEffectAtItsStart() throws {
        let store = try GlucoseHistoryStore(inMemory: true)
        try write(
            store,
            [
                DeliveryChange(date: at(-120), kind: .basalRate, unitsPerHour: 0.5),
                DeliveryChange(date: at(-60), kind: .basalRate, unitsPerHour: 0.7),
                DeliveryChange(date: at(-50), kind: .suspended),
                DeliveryChange(date: at(-40), kind: .resumed),
                DeliveryChange(date: at(10), kind: .suspended),
                DeliveryChange(date: at(90), kind: .resumed)
            ])
        XCTAssertEqual(
            store.deliveryChanges(in: at(0)...at(60)),
            [
                DeliveryChange(date: at(-60), kind: .basalRate, unitsPerHour: 0.7),
                DeliveryChange(date: at(-40), kind: .resumed),
                DeliveryChange(date: at(10), kind: .suspended)
            ])
    }

    /// A retried sync places the same records a fraction of a second apart; they're kept once.
    func testTheSameChangeWrittenTwiceIsKeptOnce() throws {
        let store = try GlucoseHistoryStore(inMemory: true)
        for shift in [0, 0.4] {
            try write(
                store,
                [
                    DeliveryChange(date: at(5).addingTimeInterval(shift), kind: .basalRate, unitsPerHour: 0.8),
                    DeliveryChange(date: at(5).addingTimeInterval(shift), kind: .suspended)
                ])
        }
        try write(store, [DeliveryChange(date: at(5), kind: .basalRate, unitsPerHour: 1.1)])
        // At one time, so in no set order: the rate and the suspend once each, and the other rate.
        let held = store.deliveryChanges(in: at(0)...at(60))
        XCTAssertEqual(held.filter { $0.kind == .suspended }.count, 1)
        XCTAssertEqual(held.filter { $0.kind == .basalRate }.map(\.unitsPerHour).sorted(), [0.8, 1.1])
    }

    /// Retention keeps the rate and the suspend or resume in effect at the cutoff, so a rate that hasn't
    /// changed for a day is still drawn.
    func testRetentionKeepsWhatIsInEffectAtTheCutoff() throws {
        let store = try GlucoseHistoryStore(inMemory: true)
        try write(
            store,
            [
                DeliveryChange(date: at(-200), kind: .basalRate, unitsPerHour: 0.5),
                DeliveryChange(date: at(-150), kind: .basalRate, unitsPerHour: 0.6),
                DeliveryChange(date: at(-140), kind: .suspended),
                DeliveryChange(date: at(-130), kind: .resumed),
                DeliveryChange(date: at(20), kind: .basalRate, unitsPerHour: 0.9)
            ])
        store.deleteGlucose(olderThan: at(0))
        XCTAssertEqual(
            store.deliveryChanges(in: at(-300)...at(60)),
            [
                DeliveryChange(date: at(-150), kind: .basalRate, unitsPerHour: 0.6),
                DeliveryChange(date: at(-130), kind: .resumed),
                DeliveryChange(date: at(20), kind: .basalRate, unitsPerHour: 0.9)
            ])
        store.clear()
        XCTAssertEqual(store.deliveryChanges(in: at(-300)...at(60)), [])
    }

    /// A store written before delivery changes were kept opens with its rows, and takes them.
    func testAStoreFromBeforeOpensWithItsRows() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("delivery-\(UUID().uuidString).store")
        defer {
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        }
        do {
            let before = try ModelContainer(
                for: StoredGlucose.self, StoredBolus.self, StoredCarb.self, StoredHistoryEvent.self,
                configurations: ModelConfiguration(url: url))
            before.mainContext.insert(StoredBolus(date: at(1), units: 2, sourceID: "pump", recordedAt: at(1)))
            try before.mainContext.save()
        }
        let store = try GlucoseHistoryStore(url: url)
        XCTAssertEqual(store.boluses(in: at(0)...at(60)).map(\.units), [2])
        try write(store, [DeliveryChange(date: at(2), kind: .suspended)])
        XCTAssertEqual(store.deliveryChanges(in: at(0)...at(60)), [DeliveryChange(date: at(2), kind: .suspended)])
    }

    /// A rate from more than a day before the window isn't carried in: the records since may not be
    /// fetched yet, and a gap is unknown.
    func testAnOldRateIsntCarriedIntoTheWindow() throws {
        let store = try GlucoseHistoryStore(inMemory: true)
        try write(store, [DeliveryChange(date: at(-25 * 60), kind: .basalRate, unitsPerHour: 0.5)])
        XCTAssertEqual(store.deliveryChanges(in: at(0)...at(60)), [])
        try write(store, [DeliveryChange(date: at(-23 * 60), kind: .basalRate, unitsPerHour: 0.6)])
        XCTAssertEqual(
            store.deliveryChanges(in: at(0)...at(60)),
            [DeliveryChange(date: at(-23 * 60), kind: .basalRate, unitsPerHour: 0.6)])
    }

    /// Forgetting a pump, or its log restarting, removes its changes and only its.
    func testClearingASourceRemovesOnlyItsChanges() throws {
        let store = try GlucoseHistoryStore(inMemory: true)
        try write(store, [DeliveryChange(date: at(5), kind: .suspended)])
        try store.ingestPumpHistory(
            glucose: [], boluses: [], carbs: [], deliveryChanges: [DeliveryChange(date: at(6), kind: .resumed)],
            sourceID: "other", glucosePriority: 50)
        try store.clearDeliveryChanges(sourceID: "pump")
        XCTAssertEqual(store.deliveryChanges(in: at(0)...at(60)), [DeliveryChange(date: at(6), kind: .resumed)])
    }
}
