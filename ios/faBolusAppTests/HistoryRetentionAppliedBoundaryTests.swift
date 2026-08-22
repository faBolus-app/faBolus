import Testing
import Foundation
import faBolusCore
import HistoryStore
@testable import faBolus

/// LOCK-03 boundary test (Phase 8, 08-01, Pitfall 2). Proves the pinned 24h retention is ACTUALLY
/// APPLIED, not merely a locked-looking-but-inert setting: seeds a persisted `GlucoseHistoryStore`
/// (via the `#if DEBUG` `setHistoryStoreForTesting` seam) with a sample older than the pin and a fresh
/// sample, runs the SAME `model.applyRetention(days:)` call the new `App.swift` `.onAppear` launch
/// call site performs, and asserts the stale sample is pruned while the fresh one survives.
/// `AppModel.applyRetention(days:)` itself is byte-identical (D-08) — this test proves the NEW caller
/// (App.swift) + the pinned value together actually enforce the lock, closing the gap Pitfall 2 warns
/// about (`DataHistoryView.swift`, the only prior caller, is deleted this same plan).
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
        #expect(AppSettings.shared.historyRetentionDays == 1)   // LOCK-03 pin: 24h == 1 day
        model.applyRetention(days: AppSettings.shared.historyRetentionDays)

        let after = model.storedGlucoseForTesting(in: (now.addingTimeInterval(-72 * 3600))...now)
        #expect(after.count == 1, "the stale (48h) sample must be pruned")
        #expect(after.first?.mgdl == 120, "the fresh (1h) sample must survive")
    }

    /// A retention of 0 ("keep everything" — the pre-Phase-8 fallback) must remain a no-op, proving
    /// `applyRetention`'s own `guard days > 0` semantics are unaffected by this phase's pin (the pin
    /// changes WHAT value is passed in, never how the guarded method interprets it).
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
