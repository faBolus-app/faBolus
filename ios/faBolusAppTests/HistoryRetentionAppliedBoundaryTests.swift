import Testing
import Foundation
import faBolusCore
import HistoryStore
@testable import faBolus

/// The pinned 24h history retention must actually prune samples older than the window, not sit as an
/// inert setting.
@Suite(.serialized) @MainActor
struct HistoryRetentionAppliedBoundaryTests {

    private func makeModelWithInMemoryHistory() throws -> AppModel {
        let backend = MockBackend()
        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("history-retention-boundary-ledger-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)
        let store = try GlucoseHistoryStore(inMemory: true)
        model.setHistoryStoreForTesting(store)
        return model
    }

    @Test func applyRetentionPrunesGlucoseOlderThanThePinnedWindowAndKeepsFreshSamples() throws {
        let model = try makeModelWithInMemoryHistory()
        let now = Date()
        let stale = now.addingTimeInterval(-48 * 3600)     // 48h old — outside the 24h (1-day) pin
        let fresh = now.addingTimeInterval(-1 * 3600)       // 1h old — inside the pin

        // Ingest directly into a fresh in-memory store, then hand it to the model via the same test
        // seam `makeModelWithInMemoryHistory` used — `storedGlucoseForTesting`/`setHistoryStoreForTesting`
        // are the only test seams AppModel exposes onto its private `history`.
        let seededStore = try GlucoseHistoryStore(inMemory: true)
        seededStore.ingestGlucose([GlucoseReading(date: stale, mgdl: 110),
                                    GlucoseReading(date: fresh, mgdl: 120)],
                                   sourceID: "boundary-test", priority: 0)
        model.setHistoryStoreForTesting(seededStore)

        // Pre-condition: both samples are present before retention runs.
        let before = model.storedGlucoseForTesting(in: (now.addingTimeInterval(-72 * 3600))...now)
        #expect(before.count == 2, "both seeded samples must be present before applyRetention runs")

        // The SAME call the new App.swift launch call site performs.
        #expect(AppSettings.shared.historyRetentionDays == 1)   // 24h == 1 day
        model.applyRetention(days: AppSettings.shared.historyRetentionDays)

        let after = model.storedGlucoseForTesting(in: (now.addingTimeInterval(-72 * 3600))...now)
        #expect(after.count == 1, "the stale (48h) sample must be pruned")
        #expect(after.first?.mgdl == 120, "the fresh (1h) sample must survive")
    }

    /// A retention of 0 ("keep everything") must remain a no-op: `applyRetention`'s `guard days > 0`
    /// is unaffected by which value the pin passes in.
    @Test func applyRetentionIsANoOpForTheKeepEverythingValue() throws {
        let model = try makeModelWithInMemoryHistory()
        let now = Date()
        let ancient = now.addingTimeInterval(-365 * 24 * 3600)
        let seededStore = try GlucoseHistoryStore(inMemory: true)
        seededStore.ingestGlucose([GlucoseReading(date: ancient, mgdl: 100)], sourceID: "boundary-test", priority: 0)
        model.setHistoryStoreForTesting(seededStore)

        model.applyRetention(days: 0)   // 0 = keep everything

        let after = model.storedGlucoseForTesting(in: (now.addingTimeInterval(-400 * 24 * 3600))...now)
        #expect(after.count == 1, "days == 0 must never prune anything")
    }
}
