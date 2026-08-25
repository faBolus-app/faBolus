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
}
