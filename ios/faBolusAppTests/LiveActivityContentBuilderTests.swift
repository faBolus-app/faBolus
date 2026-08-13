import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Phase 5 tracer (05-01-PLAN.md, Task 1) — the pure Live Activity content-builder behaviors
/// (SC-1). Exercises ONLY `GlucoseLiveActivityManager.makeContent(from:now:)` — no ActivityKit I/O,
/// which is device/simulator-only (05-RESEARCH.md § Environment Availability). Mirrors
/// `CrossSurfaceStalenessTests`'s pattern: inject a snapshot at a known `now`, assert the projected
/// state / staleDate / timestamp.
struct LiveActivityContentBuilderTests {

    private func snap(glucose: Int? = 120, glucoseDate: Date?, trendArrow: String = "→",
                       staleAfterSec: TimeInterval? = nil, displayUnit: String? = nil,
                       points: [WidgetSnapshot.Point] = []) -> WidgetSnapshot {
        WidgetSnapshot(glucose: glucose, glucoseDate: glucoseDate, trendArrow: trendArrow,
                       recentPoints: points, staleAfterSec: staleAfterSec, displayUnit: displayUnit)
    }

    /// D-06: staleDate == the SAMPLE date + the published stale threshold, never `now + fixed`
    /// (Loop's own `now + 1h` is exactly the bug this rule forbids — 05-RESEARCH.md Pitfall #3).
    @Test func staleDateIsSampleDatePlusStaleAfterNeverNowPlusFixed() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let taken = now.addingTimeInterval(-120)               // sampled 2 min ago
        let s = snap(glucoseDate: taken, staleAfterSec: 300)   // 5-min stale threshold
        let (_, staleDate, _) = GlucoseLiveActivityManager.makeContent(from: s, now: now)
        #expect(staleDate == taken.addingTimeInterval(300))
        #expect(staleDate != now.addingTimeInterval(300))      // NOT now + fixed
    }

    /// Default stale threshold (nil `staleAfterSec`) falls back to 360s (6 min), matching
    /// `GlucoseFreshness`'s own default.
    @Test func staleDateFallsBackToSixMinutesWhenStaleAfterSecIsNil() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let s = snap(glucoseDate: now, staleAfterSec: nil)
        let (_, staleDate, _) = GlucoseLiveActivityManager.makeContent(from: s, now: now)
        #expect(staleDate == now.addingTimeInterval(360))
    }

    /// D-06 monotonicity: the builder exposes the SAMPLE date as `timestamp`, so a 60-min-old sample
    /// arriving "now" yields an already-past staleDate — proving `Activity.update(timestamp:)` can
    /// never let this older sample read as fresher than a newer one.
    @Test func sixtyMinuteOldSampleArrivingNowYieldsAnAlreadyPastStaleDate() {
        let now = Date(timeIntervalSince1970: 3_000_000)
        let taken = now.addingTimeInterval(-3600)
        let s = snap(glucoseDate: taken, staleAfterSec: 300)
        let (_, staleDate, timestamp) = GlucoseLiveActivityManager.makeContent(from: s, now: now)
        #expect(timestamp == taken)
        #expect(staleDate < now)   // already in the past relative to "now"
    }

    /// C8: no synthesized trend. Fresh → carries the snapshot's arrow verbatim. Stale-as-of-now →
    /// "" (never a flat/synthesized fallback).
    @Test func trendArrowCarriedWhenFreshSuppressedWhenStale() {
        let now = Date(timeIntervalSince1970: 4_000_000)

        let fresh = snap(glucoseDate: now.addingTimeInterval(-30), trendArrow: "↑", staleAfterSec: 300)
        let (freshState, _, _) = GlucoseLiveActivityManager.makeContent(from: fresh, now: now)
        #expect(freshState.trendArrow == "↑")

        let stale = snap(glucoseDate: now.addingTimeInterval(-600), trendArrow: "↑", staleAfterSec: 300)
        let (staleState, _, _) = GlucoseLiveActivityManager.makeContent(from: stale, now: now)
        #expect(staleState.trendArrow == "")
    }

    /// D-09: the Phase-4 mmol wire token is carried verbatim; `nil` resolves to mg/dL at render time
    /// via `WidgetGlucoseUnit(wireToken:)` — the builder itself never inlines a conversion.
    @Test func displayUnitTokenCarriedVerbatimNilOrSet() {
        let now = Date(timeIntervalSince1970: 5_000_000)

        let mmolSnap = snap(glucoseDate: now, staleAfterSec: 300, displayUnit: "mmol")
        let (mmolState, _, _) = GlucoseLiveActivityManager.makeContent(from: mmolSnap, now: now)
        #expect(mmolState.displayUnitToken == "mmol")

        let nilSnap = snap(glucoseDate: now, staleAfterSec: 300, displayUnit: nil)
        let (nilState, _, _) = GlucoseLiveActivityManager.makeContent(from: nilSnap, now: now)
        #expect(nilState.displayUnitToken == nil)
        #expect(WidgetGlucoseUnit(wireToken: nilState.displayUnitToken) == .mgdl)
    }

    /// 05-RESEARCH.md Pitfall #2 — the ~4KB `ContentState` ceiling. Cap `recentPoints` to 24
    /// (tighter than the Home Screen widget's 48) and assert the ACTUAL encoded size, not an
    /// estimate.
    @Test func encodedContentStateStaysUnderTheFourKBCeilingWithACappedPointArray() throws {
        let now = Date(timeIntervalSince1970: 6_000_000)
        let points = (0..<48).map {
            WidgetSnapshot.Point(t: now.addingTimeInterval(Double($0 - 48) * 300), mgdl: 100 + $0)
        }
        let s = snap(glucoseDate: now, staleAfterSec: 300, displayUnit: "mmol", points: points)
        let (state, _, _) = GlucoseLiveActivityManager.makeContent(from: s, now: now)

        #expect(state.recentPoints.count == 24)   // capped at 24, not the widget's 48
        let data = try JSONEncoder().encode(state)
        #expect(data.count < 4096)
    }
}
