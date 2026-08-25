import Testing
import Foundation
@testable import faBolus
import faBolusCore

/// C2-02 (monotonic-by-timestamp `latest`) + C2-05 (sub-40 urgent-low sentinel, isolated from the dose
/// path) hygiene tests for the CGM failover ingest boundary. `PollingGlucoseSource` is an APP-TARGET
/// class (imports `faBolusCore`, `ios/faBolus/Data/Sources/PollingGlucoseSource.swift:1`), so these live
/// in `faBolusAppTests` and run via xcodebuild — `Packages/faBolusCore/Tests` cannot instantiate it
/// (codex MEDIUM, addressed in the 13-03 plan review).
@MainActor
struct PollingGlucoseSourceHygieneTests {

    // MARK: - C2-02: `latest` never steps backward in time

    /// A late/stale poll delivering an OLDER-timestamped reading after a newer one has already been
    /// ingested must not step `latest` backward — the failover value must never appear to regress.
    @Test func olderTimestampAfterNewerLeavesLatestAtTheNewerReading() {
        let source = PollingGlucoseSource(id: "test", priority: 0)
        let now = Date()
        let newer = GlucoseSample(mgdl: 110, date: now, sourceID: "test")!
        let older = GlucoseSample(mgdl: 90, date: now.addingTimeInterval(-600), sourceID: "test")!
        source.ingest([newer])
        source.ingest([older])
        #expect(source.latest?.mgdl == 110, "a late/stale poll must not step `latest` backward in time")
        #expect(source.latest?.date == now)
    }

    /// A strictly-newer reading always advances `latest` — the guard must not block genuine forward
    /// progress.
    @Test func strictlyNewerReadingAdvancesLatest() {
        let source = PollingGlucoseSource(id: "test", priority: 0)
        let now = Date()
        let first = GlucoseSample(mgdl: 100, date: now.addingTimeInterval(-300), sourceID: "test")!
        let second = GlucoseSample(mgdl: 130, date: now, sourceID: "test")!
        source.ingest([first])
        source.ingest([second])
        #expect(source.latest?.mgdl == 130)
        #expect(source.latest?.date == now)
    }

    /// An equal-timestamp duplicate (a re-delivered poll result) must not be treated as "newer" and
    /// regress/replace `latest` — the guard is strict (`>`), not `>=`.
    @Test func equalTimestampDuplicateDoesNotRegressLatest() {
        let source = PollingGlucoseSource(id: "test", priority: 0)
        let now = Date()
        let first = GlucoseSample(mgdl: 100, date: now, sourceID: "test")!
        let duplicate = GlucoseSample(mgdl: 100, date: now, sourceID: "test")!
        source.ingest([first])
        source.ingest([duplicate])
        #expect(source.latest?.date == now)
        #expect(source.latest?.mgdl == 100)
    }

    // MARK: - C2-05: sub-40 vendor reading -> SEPARATE urgent-low sentinel, never a GlucoseSample

    /// A below-measurable-range (sub-40) vendor reading at the ingest boundary must be surfaced via a
    /// SEPARATE typed sentinel — but the D-05 gate (`GlucoseSample.init?`) still rejects it exactly as
    /// before, so it never becomes `latest`, and feeding it through the REAL `GlucoseArbiter.merge`
    /// leaves `PumpSnapshot.glucose` untouched (T-13-07b: never a dose-input leak on the frozen path).
    @Test func subFortyReadingProducesSentinelAndNeverBecomesLatestOrPumpSnapshotGlucose() {
        let source = PollingGlucoseSource(id: "test", priority: 0)
        let now = Date()
        source.ingestRawReading(mgdl: 32, date: now)

        // The D-05 gate itself is untouched — a sub-40 value still fails GlucoseSample.init?.
        #expect(GlucoseSample(mgdl: 32, date: now, sourceID: "test") == nil)
        // It never becomes `latest` — never a dose-eligible numeric sample.
        #expect(source.latest == nil)
        // It IS surfaced separately, for a future display/alert layer.
        #expect(source.urgentLowSentinel?.date == now)
        #expect(source.urgentLowSentinel?.sourceID == "test")

        // Isolation proof through the REAL arbiter: with no numeric `latest`, merge must publish the
        // pump's OWN unrelated snapshot unchanged — the sentinel can never become `PumpSnapshot.glucose`.
        var pumpSnapshot = PumpSnapshot()
        pumpSnapshot.glucose = 150
        pumpSnapshot.glucoseDate = now
        let (merged, _, provenance) = GlucoseArbiter.merge(pumpSnapshot: pumpSnapshot, pumpHistory: [], source: source)
        #expect(merged.glucose == 150, "a sub-40 sentinel must never become PumpSnapshot.glucose")
        #expect(provenance == .pump)
    }

    /// Above-400 handling is UNCHANGED by this fix — only a below-range reading is a genuine dropped-
    /// hypo safety signal worth surfacing; an above-range (decode-garbage) reading still just silently
    /// fails the gate with no sentinel.
    @Test func aboveFourHundredReadingProducesNoSentinel() {
        let source = PollingGlucoseSource(id: "test", priority: 0)
        source.ingestRawReading(mgdl: 500, date: Date())
        #expect(source.urgentLowSentinel == nil, "above-400 handling is unchanged — no urgent-low sentinel")
        #expect(source.latest == nil)
    }
}
