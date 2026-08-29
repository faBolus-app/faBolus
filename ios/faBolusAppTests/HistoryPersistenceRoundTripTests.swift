import Testing
import Foundation
import faBolusCore
import HistoryStore
import TandemMessages
import TandemBLE
@testable import faBolus

/// Phase 16 GO-1 Step 5 (16-05, REMED-16, R24/R29). Characterizes the identity-diff persist
/// round-trip (`AppModel.persistNewHistory`, the Phase 09.7-01 Pitfall-3 fix) BEFORE it moves into
/// `HistoryPersistenceCoordinator` (Task 2), so this file is the wall the extraction must stay
/// green against. Reuses the proven `TandemBackend` + `FakePumpTransport` gap-sync idiom
/// `HistoryLogSyncTests.oldGapRecordPersists` already established for driving a real
/// `refresh() -> persistNewHistory` cycle end-to-end — no new `AppModel`/`MockBackend` test seam
/// needed.
@Suite(.serialized) @MainActor
struct HistoryPersistenceRoundTripTests {

    /// Mirrors `HistoryLogSyncTests.withCleanCoverage` — the gap-sync coverage map is a
    /// process-shared `AppSettings.shared` singleton, so it must never leak across suites.
    private func withCleanCoverage(_ body: () throws -> Void) rethrows {
        let saved = AppSettings.shared.historyCoverage
        defer { AppSettings.shared.historyCoverage = saved }
        AppSettings.shared.historyCoverage = HistoryCoverageMap()
        try body()
    }

    private func makeBackend() -> (TandemBackend, FakePumpTransport) {
        let fake = FakePumpTransport()
        let backend = TandemBackend(testTransport: fake)
        return (backend, fake)
    }

    /// Mirrors `HistoryLogSyncTests.injectHistoryStreamChunked` — a `HistoryLogStreamResponse`
    /// frame's one-byte cargo length caps it at ≤9 26-byte records per frame.
    private func injectHistoryStreamChunked(
        _ backend: TandemBackend, _ readings: [(seq: UInt32, pumpTimeSec: UInt32, mgdl: Int)]
    ) {
        var idx = 0
        while idx < readings.count {
            let chunk = Array(readings[idx..<min(idx + 9, readings.count)])
            backend.injectHistoryLogFrameForTesting(FakePumpTransport.historyLogStream(cgmReadings: chunk))
            idx += 9
        }
    }

    // MARK: - Pitfall-3: a gap-sync record older than the last snapshot still ingests

    /// A gap-fill record dated OLDER than every reading already persisted must still reach
    /// `GlucoseHistoryStore` — the identity-diff keys on "was this exact timestamp in the LAST
    /// persisted set", never on date ordering, so an interior/forward gap record from D-02 is never
    /// silently dropped by a forward-only watermark.
    @Test func gapSyncRecordOlderThanLastSnapshotStillIngests() {
        withCleanCoverage {
            let (backend, fake) = makeBackend()
            let model = AppModel(source: backend)
            let store = try! GlucoseHistoryStore(inMemory: true)
            model.setHistoryStoreForTesting(store)

            backend.injectStatusFrameForTesting(FakePumpTransport.timeResponse())
            backend.injectStatusFrameForTesting(
                FakePumpTransport.historyLogStatus(numEntries: 100, firstSequenceNum: 1, lastSequenceNum: 100))
            // WR-03: receive the whole 1...100 window so held coverage is [1...100].
            injectHistoryStreamChunked(
                backend,
                stride(from: UInt32(100), through: UInt32(1), by: -1).map {
                    (seq: $0, pumpTimeSec: UInt32(5_000) * $0, mgdl: 111)
                })
            backend.fireHistorySyncTickForTesting()

            let afterFirstSync = model.storedGlucoseForTesting(in: Date(timeIntervalSince1970: 0)...Date())
            let countAfterFirst = afterFirstSync.count
            #expect(
                countAfterFirst > 0, "the first sync must persist something before the gap-record case is meaningful")

            // Second sync: the pump's range grew to 1...130; the interior window 101...130 holds a
            // record with pumpTimeSec 50 -- far OLDER than every pumpTimeSec (5,000...500,000) the
            // first sync already ingested. Exactly the case a forward date-watermark used to drop.
            backend.injectStatusFrameForTesting(
                FakePumpTransport.historyLogStatus(numEntries: 130, firstSequenceNum: 1, lastSequenceNum: 130))
            backend.injectHistoryLogFrameForTesting(
                FakePumpTransport.historyLogStream(cgmReadings: [(seq: 105, pumpTimeSec: 50, mgdl: 77)]))
            backend.fireHistorySyncTickForTesting()  // finishBackfill -> onChange -> AppModel.refresh() -> persist

            _ = fake  // keep the fake alive for the duration of the assertions
            let afterSecondSync = model.storedGlucoseForTesting(in: Date(timeIntervalSince1970: 0)...Date())
            #expect(
                afterSecondSync.contains { $0.mgdl == 77 },
                "a gap-sync record dated older than the last persisted snapshot must still reach the store")
            #expect(
                afterSecondSync.count == countAfterFirst + 1,
                "exactly one NEW reading is added -- the identity-diff must not re-ingest everything already held")
        }
    }

    // MARK: - Identity-diff: an unchanged reading/bolus does not re-insert

    /// A second `refresh()` cycle over the EXACT SAME `glucoseHistory`/`bolusMarkers` content must
    /// not grow the persisted store at all — `persistNewHistory` diffs against the previous call's
    /// identity-key set, not merely "does this exist in the store" (which would be a needless
    /// per-tick SwiftData re-write, not incorrect, but exactly what the identity-diff exists to
    /// avoid on every ~20s `refresh()` heartbeat tick).
    @Test func identicalRefreshDoesNotReinsertGlucoseOrBoluses() {
        let backend = MockBackend()
        let model = AppModel(source: backend)
        let store = try! GlucoseHistoryStore(inMemory: true)
        model.setHistoryStoreForTesting(store)

        // First refresh: `seedDeterministicGlucoseForTesting()` fires `onChange` itself, so this one
        // call both seeds a FIXED (no `Double.random`) 37-reading trace and drives the persist path.
        // `bolusMarkers` (2 fixed markers, set at `MockBackend.init`) rides along on the same refresh.
        backend.seedDeterministicGlucoseForTesting()

        let wideRange = Date(timeIntervalSince1970: 0)...Date()
        let glucoseAfterFirst = model.storedGlucoseForTesting(in: wideRange)
        #expect(glucoseAfterFirst.count == 37, "the first refresh must persist every seeded reading")
        let bolusesAfterFirst = model.sharedHistoryStore?.boluses(in: wideRange) ?? []
        #expect(bolusesAfterFirst.count == 2, "the first refresh must persist both seeded bolus markers")
        let bytesAfterFirst = model.storedHistoryApproxBytes()
        #expect(bytesAfterFirst == 37 * 100)

        // Second refresh: `setLiveIob` fires `onChange` (driving another `refresh()` -> persist
        // cycle) but never touches `glucoseHistory`/`bolusMarkers` -- the identity-diff's exact target.
        backend.setLiveIob(1.9)

        let glucoseAfterSecond = model.storedGlucoseForTesting(in: wideRange)
        #expect(
            glucoseAfterSecond.count == 37,
            "an unchanged reading must never re-insert (identity-diff, Pitfall-3)")
        let bolusesAfterSecond = model.sharedHistoryStore?.boluses(in: wideRange) ?? []
        #expect(bolusesAfterSecond.count == 2, "an unchanged bolus marker must never re-insert")
        #expect(
            model.storedHistoryApproxBytes() == bytesAfterFirst,
            "approxBytes (raw row count) must not grow across a refresh with unchanged content")
    }

    // MARK: - Retention / statistics / approxBytes forwarding stays byte-identical

    /// Pins `applyRetention`/`storedStatistics`/`storedHistoryApproxBytes` against a known-shape
    /// seeded store so Task 2's move (facade forwarding into the coordinator) cannot silently change
    /// the schema or the values these read/write.
    @Test func retentionStatisticsAndApproxBytesForwardConsistently() {
        let backend = MockBackend()
        let model = AppModel(source: backend)
        let now = Date()
        let stale = now.addingTimeInterval(-48 * 3600)
        let fresh = now.addingTimeInterval(-1 * 3600)
        let seeded = try! GlucoseHistoryStore(inMemory: true)
        seeded.ingestGlucose(
            [GlucoseReading(date: stale, mgdl: 90), GlucoseReading(date: fresh, mgdl: 130)],
            sourceID: "round-trip-test", priority: 0)
        model.setHistoryStoreForTesting(seeded)

        #expect(model.storedHistoryApproxBytes() == 200, "2 readings * 100 approx bytes/reading")
        #expect(model.storedStatistics(days: 90) != nil)

        model.applyRetention(days: 1)  // 24h window: prunes the 48h-old sample, keeps the 1h-old one
        #expect(model.storedHistoryApproxBytes() == 100, "the stale sample must be pruned; the fresh one survives")
        let after = model.storedGlucoseForTesting(in: (now.addingTimeInterval(-72 * 3600))...now)
        #expect(after.count == 1)
        #expect(after.first?.mgdl == 130)
    }

    // MARK: - recordCarbs / therapyInsights stay wired to the same store

    @Test func recordCarbsPersistsAndTherapyInsightsRuns() {
        let backend = MockBackend()
        let model = AppModel(source: backend)
        let store = try! GlucoseHistoryStore(inMemory: true)
        model.setHistoryStoreForTesting(store)

        model.recordCarbs(grams: 45)
        let carbs = model.sharedHistoryStore?.carbs(in: Date(timeIntervalSince1970: 0)...Date()) ?? []
        #expect(carbs.contains { $0.grams == 45 }, "recordCarbs must reach the persistent store")

        // Never crashes / always returns an array, even over a sparse persisted history.
        _ = model.therapyInsights()
    }
}
