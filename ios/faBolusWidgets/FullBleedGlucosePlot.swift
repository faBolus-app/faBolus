import SwiftUI
import faBolusCore
import faBolusDesign

/// The full-bleed, edge-to-edge, zone-colored glucose curve — the shared plot primitive every later
/// 09.26 plan builds on (Phase 09.26-01 tracer). Extends the pure-`Path` `Sparkline` idiom
/// (`StatusWidget.swift:105-151`) rather than replacing it: same `GeometryReader` + x-proportional-
/// to-timestamp math (gaps stay gaps, never compressed) — NOT Swift Charts, which ActivityKit
/// forbids (gestures/scroll/`@State`/`.chartOverlay` scrubber, D-03).
///
/// Phase 09.26-04 adds:
/// - (D-18/D-19) an OPTIONAL chrome layer — axis hairlines/ticks + dashed high/low range lines, each
///   independently toggled, ALL default OFF (the owner-approved clean full-bleed look).
/// - (D-20) the four-branch sparse/not-fully-populated render (`FullBleedPlotState`) — the curve's
///   canvas maps to the FULL selected `plotRangeHours` window (not just the data's own extent), so a
///   short history naturally anchors right (now) instead of being stretched to fill the width.
///
/// Phase 09.26-05 adds (D-06 "Always-on"): reads `@Environment(\.isLuminanceReduced)` independently
/// of its caller — under AOD, the fill flattens to a flat low-opacity tint (no gradient stops) and
/// ALL chrome (axis lines/ticks/range lines) is forced off regardless of the user's own toggles.
/// This view never carries the load-bearing facts (BG numeral/arrow/time-since/top-right slot,
/// `BandIndicator`) — those are the CALLER's job and are unaffected by anything in this file.
///
/// Display-only (D-11 lineage) — this view never reads or writes a dose/delivery/signed-path type;
/// it only decides WHERE on a Y-axis a glucose fact renders.
struct FullBleedGlucosePlot: View {
    /// The history series to plot (`ContentState.recentPoints`, oldest → newest).
    let points: [WidgetSnapshot.Point]
    /// The plot's Y-axis bounds (`ContentState.plotFloorMgdl`/`plotCeilingMgdl`, already resolved by
    /// `GlucosePlotScale.resolve` at publish time — this view just clamps into them, D-03).
    let floorMgdl: Int
    let ceilingMgdl: Int
    /// The LIVE glucose value (`ContentState.glucose`) — drives the now-dot's color, distinct from
    /// `points.last`'s value (normally the same fact, but kept separate so the dot always reflects
    /// the same number the BG numeral overlay shows).
    let currentGlucose: Int?
    /// `context.isStale`, re-checked at render time by the caller (D-04) — greys the now-dot only;
    /// the historical segments/fill below never grey, since they render facts, not the live value.
    let isStale: Bool
    /// Phase 09.26-04 (D-14) — the LA-specific plot time-range (`ContentState.plotRangeHours`, 2h
    /// default or 6h) this plot's canvas represents. Drives the D-20 anchor-right math below —
    /// independent of the phone/watch chart's own range setting.
    var plotRangeHours: Int = 2
    // Phase 09.26-04 (D-18/D-19) — optional chrome, each an INDEPENDENT toggle, ALL default OFF (the
    // owner-approved clean full-bleed look). None of these ever draws a filled band rectangle
    // (D-12/D-19 — the dashed range lines REPLACE the old hard in-range band).
    /// 1pt hairline along the bottom edge of the plot area.
    var showXAxisLine: Bool = false
    /// 1pt hairline along the left edge of the plot area.
    var showYAxisLine: Bool = false
    /// Short (4pt) UNLABELED perpendicular hairlines along the bottom edge — chrome, not a labeled
    /// axis (UI-SPEC [RESOLVED]: no numeric text is ever drawn at a tick).
    var showXAxisTicks: Bool = false
    /// Short (4pt) UNLABELED perpendicular hairlines along the left edge.
    var showYAxisTicks: Bool = false
    /// Dashed high/low threshold hairlines, at the unit-aware `WidgetGlucoseThresholds.low`/`.high`
    /// mapped through the SAME `y()` the curve uses.
    var showRangeLines: Bool = false
    /// Injected so tests can pin "now" instead of the view silently reading `Date()` — mirrors the
    /// `GlucoseLiveActivityManager.makeContent(from:now:)` injection idiom already used in this
    /// codebase for the same reason (deterministic tests).
    var now: Date = Date()

    /// Phase 09.26-05 (D-06 "Always-on") — when the display is Always-On (`isLuminanceReduced`),
    /// the fill flattens to a single flat low-opacity tint (no `LinearGradient` stops, avoids a
    /// muddy/banded gradient under AOD's reduced palette + reduces the burn-in/power surface) and
    /// ALL axis/range chrome is forced off below, regardless of the user's own toggles. This view
    /// reads the environment key independently of its caller, so BOTH the Lock Screen and DI-
    /// expanded `.bottom` presentations get the same treatment with no extra wiring.
    @Environment(\.isLuminanceReduced) private var isLuminanceReduced

    /// Future-point guard (D-04, UI-SPEC "Future-point guard") — filter BEFORE building any Path, so
    /// a fast-clock artifact is never plotted as real history, mirroring `futureSkewTolerance`'s
    /// intent applied to the whole series rather than just the single live value. Delegates to
    /// `FullBleedPlotState.validPoints` (IN-01, 09.26-review) — the SAME "drop future-dated points"
    /// rule `classify` below applies, now a single shared implementation instead of two independently
    /// maintained copies.
    private var validPoints: [WidgetSnapshot.Point] {
        FullBleedPlotState.validPoints(points, now: now)
    }

    /// Phase 09.26-04 (D-20) — the pure four-branch sparse/not-fully-populated classification for
    /// `validPoints` at the selected `plotRangeHours`. Drives which of the four render branches below
    /// actually draws.
    private var plotState: FullBleedPlotState {
        FullBleedPlotState.classify(points: points, plotRangeHours: plotRangeHours, now: now)
    }

    /// The start of the FULL selected plot-range window (e.g. "6h ago") — the canvas's LEFT edge.
    /// Using the WINDOW's bounds (not the data's own min/max) is what makes `.partial` anchor right:
    /// a short history's points land at their real proportional position within this wider window,
    /// leaving the uncovered left region genuinely empty rather than stretched to fill the width.
    private var windowStart: Date {
        now.addingTimeInterval(-Double(max(plotRangeHours, 1)) * 3600)
    }

    /// `validPoints` further restricted to the selected window — the points the curve itself draws.
    /// (Task 3's `makeContent` already sizes `recentPoints` to roughly this window at the source; this
    /// filter is a defensive belt-and-suspenders trim, not the primary sizing mechanism.)
    private var curvePoints: [WidgetSnapshot.Point] {
        validPoints.filter { $0.t >= windowStart }
    }

    // x() maps the FULL [windowStart, now] domain to [0, width] — NOT the data's own min/max — so a
    // short/partial history anchors right instead of being stretched edge-to-edge (D-20).
    private func x(_ pt: WidgetSnapshot.Point, _ width: CGFloat) -> CGFloat {
        let start = windowStart.timeIntervalSinceReferenceDate
        let span = max(1, now.timeIntervalSinceReferenceDate - start)
        let raw = width * CGFloat((pt.t.timeIntervalSinceReferenceDate - start) / span)
        return min(width, max(0, raw))
    }
    /// Y-position from the shared `GlucosePlotScale.clamp` (D-03) — a reading outside
    /// `[floorMgdl, ceilingMgdl]` pins to the nearer bound rather than drawing off-canvas.
    private func y(_ mgdl: Int, _ height: CGFloat) -> CGFloat {
        let clamped = GlucosePlotScale.clamp(mgdl, floor: floorMgdl, ceiling: ceilingMgdl)
        let span = max(ceilingMgdl - floorMgdl, 1)
        return height * (1 - CGFloat(clamped - floorMgdl) / CGFloat(span))
    }

    /// The last plotted point's zone color, UNSTALED — the fill/segments render historical facts and
    /// must "stay colored while the live value is stale" (D-04 must-have); only the now-dot below
    /// follows the staleness gate.
    private var lastZoneColor: Color {
        guard let last = curvePoints.last else { return AppTheme.stale }
        return AppTheme.glucoseColor(last.mgdl, stale: false)
    }

    /// The now-dot's color: the CURRENT zone, greyed via the SAME staleness rule the BG numeral
    /// overlay uses (D-04/D-17) — a stale reading can never present as the live value.
    private var nowDotColor: Color {
        guard let g = currentGlucose else { return AppTheme.stale }
        return AppTheme.glucoseColor(g, stale: isStale)
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                switch plotState {
                case .empty:
                    // No dot, no line, no fill — only the hint (D-20). The BG numeral/overlays still
                    // render independently from `state.glucose` (the curve and the live value are
                    // independent facts) — that's the CALLER's job, not this view's.
                    collectingHistoryHint
                case .single:
                    // A single fact can't draw a line — now-dot + hint only, no line/fill.
                    if let only = curvePoints.last ?? validPoints.last {
                        Circle()
                            .fill(nowDotColor)
                            .frame(width: 6, height: 6)
                            .position(x: max(0, size.width - 10), y: y(only.mgdl, size.height))
                    }
                    collectingHistoryHint
                case .partial:
                    // Phase 09.26 (WR-03 review fix): `plotState` classifies against the UNWINDOWED
                    // valid span (only future points excluded), while `curvePoints` below is further
                    // restricted to `[windowStart, now]`. A long-enough CGM outage can leave the
                    // unwindowed span still >= the classify boundary (so `.partial`/`.full` is
                    // reported) while every point has aged OUT of the window `curveLayer`/
                    // `partialGapOverlay` actually draw from — without this guard that combination
                    // rendered a fully blank canvas (no dot/line/hint at all). Fall back to the SAME
                    // "Collecting history…" hint the `.empty`/`.single` branches already use whenever
                    // there is nothing left in-window to draw, mirroring `.single`'s own
                    // `curvePoints.last ?? validPoints.last` defensive fallback.
                    if curvePoints.isEmpty {
                        collectingHistoryHint
                    } else {
                        curveLayer(in: size)
                        partialGapOverlay(in: size)
                    }
                case .full:
                    if curvePoints.isEmpty {
                        collectingHistoryHint
                    } else {
                        curveLayer(in: size)
                    }
                }
                // Phase 09.26-05 (D-06) — ALL chrome forced off under always-on, regardless of the
                // user's own toggles (reduce visual noise + power draw); the load-bearing facts
                // rendered by the CALLER (BG numeral, arrow, time-since, top-right slot) and the
                // non-color `BandIndicator` channel are unaffected — this view never touches them.
                if !isLuminanceReduced {
                    chromeLayer(in: size)
                }
            }
        }
        // Decorative Path — VoiceOver reads the BG numeral/top-right/bottom-row overlays, never this
        // shape (Accessibility contract, UI-SPEC "FullBleedGlucosePlot ... gets .accessibilityHidden(true)").
        .accessibilityHidden(true)
    }

    /// The `.empty`/`.single` caption — plain, centered text (ZStack's default alignment), spanning
    /// the plot's width (UI-SPEC "Sparse/not-fully-populated history").
    private var collectingHistoryHint: some View {
        Text("Collecting history…")
            .font(.caption2)
            .foregroundStyle(.secondary)
    }

    // MARK: - Curve (fill + zone-segmented stroke + now-dot), shared by `.partial`/`.full`

    /// Draws the curve ONLY across `curvePoints` — the REAL data span. For `.full` this happens to
    /// span (approximately) the full canvas; for `.partial` it draws only the right-hand portion the
    /// data actually covers, by construction of the window-based `x()` above — never a fill/line
    /// stretched into time for which there is no data (D-20).
    @ViewBuilder
    private func curveLayer(in size: CGSize) -> some View {
        if curvePoints.count >= 2 {
            // Edge-to-edge silhouette fill (D-11) — from the plotted line down to the bottom edge of
            // the card, not a mid-widget sparkline. Phase 09.26-05 (D-06): under always-on, the
            // gradient flattens to a single flat low-opacity tint (no `LinearGradient` stops) —
            // avoids a muddy/banded look under AOD's reduced palette and trims the burn-in surface.
            if isLuminanceReduced {
                fillPath(in: size).fill(lastZoneColor.opacity(0.12))
            } else {
                fillPath(in: size)
                    .fill(LinearGradient(
                        colors: [lastZoneColor.opacity(0.30), lastZoneColor.opacity(0.04)],
                        startPoint: .top, endPoint: .bottom))
            }
            // Zone-segmented stroke (D-17): N-1 short Path segments, each colored by the LATER
            // point's `GlucoseRange.classify` — historical segments are facts and are never greyed by
            // the live-value staleness gate (D-04).
            ForEach(Array(strokeSegments(in: size).enumerated()), id: \.offset) { _, segment in
                segment.path.stroke(
                    segment.color,
                    style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
            }
        }
        // Now-dot: 6pt, current-zone color (greys when stale), inset 10pt from the right edge so the
        // system corner radius never clips it (D-17a).
        if let last = curvePoints.last {
            Circle()
                .fill(nowDotColor)
                .frame(width: 6, height: 6)
                .position(x: max(0, size.width - 10), y: y(last.mgdl, size.height))
        }
    }

    private func fillPath(in size: CGSize) -> Path {
        Path { p in
            guard let first = curvePoints.first, let last = curvePoints.last else { return }
            p.move(to: CGPoint(x: x(first, size.width), y: y(first.mgdl, size.height)))
            for pt in curvePoints.dropFirst() {
                p.addLine(to: CGPoint(x: x(pt, size.width), y: y(pt.mgdl, size.height)))
            }
            p.addLine(to: CGPoint(x: x(last, size.width), y: size.height))
            p.addLine(to: CGPoint(x: x(first, size.width), y: size.height))
            p.closeSubpath()
        }
    }

    private struct StrokeSegment { let path: Path; let color: Color }
    private func strokeSegments(in size: CGSize) -> [StrokeSegment] {
        guard curvePoints.count >= 2 else { return [] }
        var result: [StrokeSegment] = []
        result.reserveCapacity(curvePoints.count - 1)
        for i in 1..<curvePoints.count {
            let a = curvePoints[i - 1]
            let b = curvePoints[i]
            var path = Path()
            path.move(to: CGPoint(x: x(a, size.width), y: y(a.mgdl, size.height)))
            path.addLine(to: CGPoint(x: x(b, size.width), y: y(b.mgdl, size.height)))
            // "Later point" classifies the segment (UI-SPEC [RESOLVED]) — the color boundary sits
            // exactly where the reading crossed the threshold.
            result.append(StrokeSegment(path: path, color: AppTheme.glucoseColor(b.mgdl, stale: false)))
        }
        return result
    }

    // MARK: - `.partial`'s uncovered-left-region gap (D-20)

    /// The faint baseline + "Collecting history…" hint that fills the un-covered LEFT region for
    /// `.partial` — from the canvas's left edge (x=0) out to where the real data begins. NEVER a
    /// fill/line drawn across this region (only a faint 1pt hairline at the earliest point's OWN
    /// value, distinct from the colored curve fill/stroke above).
    @ViewBuilder
    private func partialGapOverlay(in size: CGSize) -> some View {
        if let earliest = curvePoints.first {
            let earliestX = x(earliest, size.width)
            let baselineY = y(earliest.mgdl, size.height)
            Path { p in
                p.move(to: CGPoint(x: 0, y: baselineY))
                p.addLine(to: CGPoint(x: earliestX, y: baselineY))
            }
            .stroke(Color.primary.opacity(0.06), lineWidth: 1)
            Text("Collecting history…")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .minimumScaleFactor(0.6)
                .frame(width: max(1, earliestX), alignment: .leading)
                .position(x: earliestX / 2, y: size.height / 2)
        }
    }

    // MARK: - Optional chrome (D-18/D-19)

    /// Axis hairlines/ticks + dashed high/low range lines — each independently gated on its own
    /// toggle. NEVER a filled band rectangle (D-12/D-19 — the range lines REPLACE the old hard band
    /// idiom; that band is Classic-only, `StatusWidget.swift`'s `Sparkline`, and is never reused
    /// here).
    @ViewBuilder
    private func chromeLayer(in size: CGSize) -> some View {
        if showXAxisLine {
            Path { p in
                p.move(to: CGPoint(x: 0, y: size.height))
                p.addLine(to: CGPoint(x: size.width, y: size.height))
            }
            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
        }
        if showYAxisLine {
            Path { p in
                p.move(to: CGPoint(x: 0, y: 0))
                p.addLine(to: CGPoint(x: 0, y: size.height))
            }
            .stroke(Color.primary.opacity(0.15), lineWidth: 1)
        }
        if showXAxisTicks {
            ForEach(axisTickFractions, id: \.self) { f in
                Path { p in
                    let tx = size.width * f
                    p.move(to: CGPoint(x: tx, y: size.height))
                    p.addLine(to: CGPoint(x: tx, y: size.height - 4))
                }
                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
            }
        }
        if showYAxisTicks {
            ForEach(axisTickFractions, id: \.self) { f in
                Path { p in
                    let ty = size.height * f
                    p.move(to: CGPoint(x: 0, y: ty))
                    p.addLine(to: CGPoint(x: 4, y: ty))
                }
                .stroke(Color.primary.opacity(0.15), lineWidth: 1)
            }
        }
        if showRangeLines {
            rangeLine(mgdl: WidgetGlucoseThresholds.low, in: size)
            rangeLine(mgdl: WidgetGlucoseThresholds.high, in: size)
        }
    }

    /// Four evenly-spaced interior tick positions (chrome, not a labeled axis — no numeric text is
    /// ever drawn at these positions, UI-SPEC [RESOLVED] "ticks carry no numeric labels").
    private let axisTickFractions: [CGFloat] = [0.2, 0.4, 0.6, 0.8]

    /// A single dashed hairline at `mgdl`'s y-position, mapped through the SAME `y()` the curve uses
    /// (so a range line always lines up with the curve's own Y-scale/floor/ceiling) — no numeric
    /// label on the line (chrome, not annotation, matching the tick rule above).
    private func rangeLine(mgdl: Int, in size: CGSize) -> some View {
        let ypos = y(mgdl, size.height)
        return Path { p in
            p.move(to: CGPoint(x: 0, y: ypos))
            p.addLine(to: CGPoint(x: size.width, y: ypos))
        }
        .stroke(Color.secondary.opacity(0.4), style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
    }
}
