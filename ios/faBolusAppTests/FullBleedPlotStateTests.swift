import Testing
import Foundation
@testable import faBolus

/// Phase 09.26-04 (Task 2, D-20) — the pure `FullBleedPlotState.classify` boundary behaviors: the
/// four-branch sparse/not-fully-populated decision that keeps the full-bleed plot from ever drawing
/// a misleading full-width fill/line across time for which there is no data. Exercises ONLY the pure
/// classifier — no SwiftUI, no ActivityKit (the render itself is build-sim/human-judgment verified,
/// same precedent as `FullBleedGlucosePlot`'s other UI surfaces).
struct FullBleedPlotStateTests {

    /// A point `secondsAgo` seconds before `now`, oldest→newest ordering left to the caller.
    private func pt(_ secondsAgo: TimeInterval, mgdl: Int = 120, from now: Date) -> WidgetSnapshot.Point {
        WidgetSnapshot.Point(t: now.addingTimeInterval(-secondsAgo), mgdl: mgdl)
    }

    @Test func zeroPointsClassifiesAsEmpty() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        #expect(FullBleedPlotState.classify(points: [], plotRangeHours: 2, now: now) == .empty)
    }

    @Test func onePointClassifiesAsSingle() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let points = [pt(60, from: now)]
        #expect(FullBleedPlotState.classify(points: points, plotRangeHours: 2, now: now) == .single)
    }

    @Test func twoPointsWithShortSpanClassifiesAsPartial() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // 30-minute span vs a 2h (7200s) selected range — well short of the range.
        let points = [pt(1800, from: now), pt(0, from: now)]
        #expect(FullBleedPlotState.classify(points: points, plotRangeHours: 2, now: now) == .partial)
    }

    /// Boundary: a span EXACTLY equal to the selected range counts as `.full` (the UI-SPEC's own
    /// "span covers the full selected plot range" — inclusive of the boundary itself).
    @Test func spanExactlyEqualToTheSelectedRangeClassifiesAsFull() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Exactly 2h (7200s) span for a 2h selected range.
        let points = [pt(7200, from: now), pt(3600, from: now), pt(0, from: now)]
        #expect(FullBleedPlotState.classify(points: points, plotRangeHours: 2, now: now) == .full)
    }

    @Test func spanExceedingTheSelectedRangeClassifiesAsFull() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let points = [pt(10_000, from: now), pt(0, from: now)]
        #expect(FullBleedPlotState.classify(points: points, plotRangeHours: 2, now: now) == .full)
    }

    /// Same absolute span (3h = 10800s), different selected ranges: `.full` at 2h (the span exceeds
    /// the range) but `.partial` at 6h (the SAME span is short of the range) — proves the boundary
    /// is RELATIVE to the selected `plotRangeHours`, not a fixed absolute threshold.
    @Test func sameAbsoluteSpanClassifiesDifferentlyForTwoHourVersusSixHourRange() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let points = [pt(10_800, from: now), pt(0, from: now)]
        #expect(FullBleedPlotState.classify(points: points, plotRangeHours: 2, now: now) == .full)
        #expect(FullBleedPlotState.classify(points: points, plotRangeHours: 6, now: now) == .partial)
    }

    /// Future-dated points (a fast-clock artifact) must be excluded BEFORE classification — a
    /// future-dated "point" that would otherwise cover the whole range on its own must never turn a
    /// genuinely single-fact history into a misleading `.full`.
    @Test func futureDatedPointsAreExcludedBeforeClassification() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let future = WidgetSnapshot.Point(t: now.addingTimeInterval(600), mgdl: 120)
        let real = pt(60, from: now)
        #expect(FullBleedPlotState.classify(points: [future, real], plotRangeHours: 2, now: now) == .single)
    }

    @Test func onlyFutureDatedPointsClassifyAsEmpty() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let future = WidgetSnapshot.Point(t: now.addingTimeInterval(600), mgdl: 120)
        #expect(FullBleedPlotState.classify(points: [future], plotRangeHours: 2, now: now) == .empty)
    }

    /// Phase 09.26 (WR-03 review fix) — pins the exact "all points aged out of the window" scenario
    /// the view-layer fix (`FullBleedGlucosePlot`'s `curvePoints.isEmpty` fallback) depends on:
    /// `classify` operates on the UNWINDOWED valid span (only future points are excluded before
    /// classification — never a "points older than `now - plotRangeHours`" filter), so a
    /// long-enough CGM outage can leave `classify` reporting `.full` even though EVERY point is now
    /// older than `now - plotRangeHours` (i.e. the view's own windowed `curvePoints` would be
    /// empty). `classify` itself is correct here (it is, by design, not window-aware — see its own
    /// doc comment) — this test documents why the render layer needs its own additional
    /// `curvePoints.isEmpty` guard rather than trusting `.full`/`.partial` alone to mean "there is
    /// something in-window to draw."
    @Test func allPointsAgedOutOfTheSelectedWindowStillClassifiesAsFull() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        // Both points are 8h+ stale — entirely outside a 2h selected window (windowStart = now-2h) —
        // yet their mutual span (exactly 2h) still meets the `.full` boundary.
        let points = [pt(36_000, from: now), pt(28_800, from: now)]
        #expect(FullBleedPlotState.classify(points: points, plotRangeHours: 2, now: now) == .full)
    }
}
