import SwiftUI
import faBolusCore
import faBolusDesign

/// The full-bleed, edge-to-edge, zone-colored glucose curve — the shared plot primitive every later
/// 09.26 plan builds on (Phase 09.26-01 tracer). Extends the pure-`Path` `Sparkline` idiom
/// (`StatusWidget.swift:105-151`) rather than replacing it: same `GeometryReader` + x-proportional-
/// to-timestamp math (gaps stay gaps, never compressed) — NOT Swift Charts, which ActivityKit
/// forbids (gestures/scroll/`@State`/`.chartOverlay` scrubber, D-03).
///
/// **This tracer's scope is the normal case only** (`points.count >= 2` after the future-point
/// guard): sparse/collecting-history (D-20), optional axis chrome (D-18/D-19, range lines), and
/// on-curve extrema labels (deliberately dropped, D-10) are later plans / out of scope here.
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
    /// Injected so tests can pin "now" instead of the view silently reading `Date()` — mirrors the
    /// `GlucoseLiveActivityManager.makeContent(from:now:)` injection idiom already used in this
    /// codebase for the same reason (deterministic tests).
    var now: Date = Date()

    /// Future-point guard (D-04, UI-SPEC "Future-point guard") — filter BEFORE building any Path, so
    /// a fast-clock artifact is never plotted as real history, mirroring `futureSkewTolerance`'s
    /// intent applied to the whole series rather than just the single live value.
    private var plottedPoints: [WidgetSnapshot.Point] {
        points.filter { $0.t <= now }
    }

    // Reuses `Sparkline`'s exact x-proportional-to-timestamp math (`StatusWidget.swift:114-120`).
    private var t0: TimeInterval { (plottedPoints.first?.t ?? now).timeIntervalSinceReferenceDate }
    private var tSpan: TimeInterval {
        max(1, (plottedPoints.last?.t ?? plottedPoints.first?.t ?? now).timeIntervalSinceReferenceDate - t0)
    }
    private func x(_ pt: WidgetSnapshot.Point, _ width: CGFloat) -> CGFloat {
        width * CGFloat((pt.t.timeIntervalSinceReferenceDate - t0) / tSpan)
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
        guard let last = plottedPoints.last else { return AppTheme.stale }
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
            if plottedPoints.count >= 2 {
                ZStack {
                    // Edge-to-edge silhouette fill (D-11) — from the plotted line down to the bottom
                    // edge of the card, not a mid-widget sparkline.
                    fillPath(in: size)
                        .fill(LinearGradient(
                            colors: [lastZoneColor.opacity(0.30), lastZoneColor.opacity(0.04)],
                            startPoint: .top, endPoint: .bottom))
                    // Zone-segmented stroke (D-17): N-1 short Path segments, each colored by the
                    // LATER point's `GlucoseRange.classify` — historical segments are facts and are
                    // never greyed by the live-value staleness gate (D-04).
                    ForEach(Array(strokeSegments(in: size).enumerated()), id: \.offset) { _, segment in
                        segment.path.stroke(
                            segment.color,
                            style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    }
                    // Now-dot: 6pt, current-zone color (greys when stale), inset 10pt from the right
                    // edge so the system corner radius never clips it (D-17a) — note this is a fixed
                    // inset from the edge, NOT the last point's timestamp-derived x (which sits
                    // exactly at the edge by construction of `tSpan` above).
                    if let last = plottedPoints.last {
                        Circle()
                            .fill(nowDotColor)
                            .frame(width: 6, height: 6)
                            .position(x: max(0, size.width - 10), y: y(last.mgdl, size.height))
                    }
                }
            }
        }
        // Decorative Path — VoiceOver reads the BG numeral/top-right/bottom-row overlays, never this
        // shape (Accessibility contract, UI-SPEC "FullBleedGlucosePlot ... gets .accessibilityHidden(true)").
        .accessibilityHidden(true)
    }

    private func fillPath(in size: CGSize) -> Path {
        Path { p in
            guard let first = plottedPoints.first, let last = plottedPoints.last else { return }
            p.move(to: CGPoint(x: x(first, size.width), y: y(first.mgdl, size.height)))
            for pt in plottedPoints.dropFirst() {
                p.addLine(to: CGPoint(x: x(pt, size.width), y: y(pt.mgdl, size.height)))
            }
            p.addLine(to: CGPoint(x: x(last, size.width), y: size.height))
            p.addLine(to: CGPoint(x: x(first, size.width), y: size.height))
            p.closeSubpath()
        }
    }

    private struct StrokeSegment { let path: Path; let color: Color }
    private func strokeSegments(in size: CGSize) -> [StrokeSegment] {
        guard plottedPoints.count >= 2 else { return [] }
        var result: [StrokeSegment] = []
        result.reserveCapacity(plottedPoints.count - 1)
        for i in 1..<plottedPoints.count {
            let a = plottedPoints[i - 1]
            let b = plottedPoints[i]
            var path = Path()
            path.move(to: CGPoint(x: x(a, size.width), y: y(a.mgdl, size.height)))
            path.addLine(to: CGPoint(x: x(b, size.width), y: y(b.mgdl, size.height)))
            // "Later point" classifies the segment (UI-SPEC [RESOLVED]) — the color boundary sits
            // exactly where the reading crossed the threshold.
            result.append(StrokeSegment(path: path, color: AppTheme.glucoseColor(b.mgdl, stale: false)))
        }
        return result
    }
}
