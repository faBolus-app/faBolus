import Testing
import Foundation
@testable import faBolus

/// Phase 09.26-03 (D-05/D-13/D-15/D-20) — the pure `LAMetrics` derivation helpers: the 30-minute
/// windowed glucose delta, its glyph mapping, and time-in-range. No ActivityKit I/O; every case here
/// is a plain injected `[WidgetSnapshot.Point]` array (+ a pinned `now`), so the window-boundary /
/// short-history-omission / closed-convention rules are unit-testable without a device.
struct LAMetricsTests {

    private func pt(_ minutesAgo: Double, _ mgdl: Int, now: Date) -> WidgetSnapshot.Point {
        WidgetSnapshot.Point(t: now.addingTimeInterval(-minutesAgo * 60), mgdl: mgdl)
    }

    // MARK: - delta: short-history omission (< 10 min span)

    @Test func deltaIsNilWhenSeriesSpansLessThanTenMinutes() {
        let now = Date()
        let points = [pt(9, 100, now: now), pt(4, 110, now: now), pt(0, 120, now: now)]
        #expect(LAMetrics.delta(points: points, now: now) == nil)
    }

    @Test func deltaIsNilForEmptyOrSinglePointSeries() {
        let now = Date()
        #expect(LAMetrics.delta(points: [], now: now) == nil)
        #expect(LAMetrics.delta(points: [pt(0, 120, now: now)], now: now) == nil)
    }

    @Test func deltaIsExactlyAtTheTenMinuteBoundary() {
        // Span is EXACTLY 10 minutes (>= 10 passes) — the boundary itself is a valid computation.
        let now = Date()
        let points = [pt(10, 100, now: now), pt(5, 110, now: now), pt(0, 120, now: now)]
        #expect(LAMetrics.delta(points: points, now: now) != nil)
    }

    // MARK: - delta: correct signed value over a real window

    @Test func deltaComputesLastMinusNearestToThirtyMinutesAgo() {
        let now = Date()
        // Oldest -> newest, spans 40 min. Nearest to now-30min is the 29-min-ago point (100).
        let points = [pt(40, 90, now: now), pt(29, 100, now: now), pt(15, 110, now: now), pt(0, 125, now: now)]
        #expect(LAMetrics.delta(points: points, now: now) == 25)   // 125 - 100
    }

    @Test func deltaCanBeNegativeWhenGlucoseFell() {
        let now = Date()
        let points = [pt(35, 200, now: now), pt(30, 190, now: now), pt(0, 150, now: now)]
        #expect(LAMetrics.delta(points: points, now: now) == -40)  // 150 - 190
    }

    @Test func deltaPicksTheNearestPointToTheThirtyMinuteTargetNotJustTheClosestOlderOne() {
        let now = Date()
        // Candidates at 31 min (closer) and 20 min (farther) from the 30-min target.
        let points = [pt(31, 105, now: now), pt(20, 95, now: now), pt(0, 130, now: now)]
        #expect(LAMetrics.delta(points: points, now: now) == 25)  // 130 - 105 (31min is nearer to 30 than 20min)
    }

    // MARK: - delta: nil on a stale feed (CR-01, 09.26-review) — the freshest point itself must be
    // recent, otherwise `nearest` degenerates to `last` (a fabricated "0" flat delta).

    @Test func deltaIsNilWhenTheFreshestPointIsStaleEvenWithAWideSpan() {
        let now = Date()
        // Long span (45 min) so the OLD 10-minute short-history guard alone would pass; but `last`
        // itself is 45 minutes stale (feed down) — must still be nil, never a fabricated 0.
        let points = [pt(45, 90, now: now), pt(30, 100, now: now), pt(15, 110, now: now)]
        #expect(LAMetrics.delta(points: points, now: now) == nil)
    }

    @Test func deltaIsNonNilExactlyAtTheStalenessBoundary() {
        // `last` is EXACTLY 10 minutes stale (<= 10 passes) — the boundary itself is still valid.
        let now = Date()
        let points = [pt(40, 90, now: now), pt(25, 100, now: now), pt(10, 120, now: now)]
        #expect(LAMetrics.delta(points: points, now: now) != nil)
    }

    // MARK: - deltaGlyph: boundary mapping (±10 / 0)

    @Test func deltaGlyphMapsTheDocumentedBoundaries() {
        #expect(LAMetrics.deltaGlyph(10) == "↑")
        #expect(LAMetrics.deltaGlyph(25) == "↑")
        #expect(LAMetrics.deltaGlyph(9) == "↗")
        #expect(LAMetrics.deltaGlyph(1) == "↗")
        #expect(LAMetrics.deltaGlyph(0) == "→")
        #expect(LAMetrics.deltaGlyph(-1) == "↘")
        #expect(LAMetrics.deltaGlyph(-9) == "↘")
        #expect(LAMetrics.deltaGlyph(-10) == "↓")
        #expect(LAMetrics.deltaGlyph(-25) == "↓")
    }

    // MARK: - tir: closed [70,180] convention, matching GlucoseStatistics.timeInRangePct

    @Test func tirCountsBoundaryValuesSeventyAndOneEightyAsInRange() {
        let now = Date()
        let points = [pt(10, 70, now: now), pt(5, 180, now: now)]
        #expect(LAMetrics.tir(points: points) == 100)
    }

    @Test func tirExcludesJustOutsideTheBoundaries() {
        let now = Date()
        let points = [pt(10, 69, now: now), pt(5, 181, now: now)]
        #expect(LAMetrics.tir(points: points) == 0)
    }

    @Test func tirComputesAMixedPercentageRoundedToNearestWholePercent() {
        let now = Date()
        // 3 of 4 in-range -> 75%.
        let points = [pt(15, 100, now: now), pt(10, 150, now: now), pt(5, 60, now: now), pt(0, 175, now: now)]
        #expect(LAMetrics.tir(points: points) == 75)
    }

    @Test func tirIsZeroForEmptyInput() {
        #expect(LAMetrics.tir(points: []) == 0)
    }

    // MARK: - friendlyAge: human-friendly age string (Phase 09.26 UAT fix, Defect 5 — replaces the
    // built-in `Text(date, style: .relative)`, which showed "0 sec" for a just-arrived reading)

    @Test func friendlyAgeIsNowForAnAgeUnderSixtySeconds() {
        let now = Date()
        #expect(LAMetrics.friendlyAge(date: now, now: now) == "now")
        #expect(LAMetrics.friendlyAge(date: now.addingTimeInterval(-59), now: now) == "now")
    }

    @Test func friendlyAgeSwitchesToMinutesAtTheSixtySecondBoundary() {
        let now = Date()
        #expect(LAMetrics.friendlyAge(date: now.addingTimeInterval(-60), now: now) == "1m")
        #expect(LAMetrics.friendlyAge(date: now.addingTimeInterval(-179), now: now) == "2m")
    }

    @Test func friendlyAgeSwitchesToHoursAtTheSixtyMinuteBoundary() {
        let now = Date()
        #expect(LAMetrics.friendlyAge(date: now.addingTimeInterval(-59 * 60), now: now) == "59m")
        #expect(LAMetrics.friendlyAge(date: now.addingTimeInterval(-60 * 60), now: now) == "1h")
        #expect(LAMetrics.friendlyAge(date: now.addingTimeInterval(-125 * 60), now: now) == "2h")
    }

    @Test func friendlyAgeNeverGoesNegativeForAFutureDatedTimestamp() {
        let now = Date()
        #expect(LAMetrics.friendlyAge(date: now.addingTimeInterval(600), now: now) == "now")
    }
}
