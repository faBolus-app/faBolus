import WidgetKit
import SwiftUI
import faBolusCore
import faBolusDesign

/// Home Screen medium overview: glucose + trend + a sparkline, with Active Insulin, reservoir,
/// and last bolus. Tapping opens the app.
struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FaBolusStatus", provider: FaBolusProvider()) { entry in
            StatusWidgetView(snap: entry.snap, now: entry.date)
                .widgetURL(FaBolusDeepLink.open)
        }
        .configurationDisplayName("Pump Overview")
        .description("Glucose trend, active insulin, reservoir, and last bolus.")
        .supportedFamilies([.systemMedium])
    }
}

struct StatusWidgetView: View {
    let snap: WidgetSnapshot
    /// Entry display date — staleness is evaluated against this, not wall-clock (see `GlucoseWidgetView`).
    var now: Date = Date()
    /// Phase 09.1 (D-03): classifies via `faBolusCore.GlucoseRange.classify` and colors via
    /// `faBolusDesign.AppTheme.glucoseColor(_:stale:)` — byte-identical to the deleted local switch
    /// (stale, or an unknown/missing reading, greys exactly as before).
    private var color: Color {
        guard let g = snap.glucose else { return .gray }
        return AppTheme.glucoseColor(g, stale: WidgetUI.isStale(snap, now: now))
    }
    /// Phase 04-03: resolve the active display unit from the snapshot (nil ⇒ mgdl) and render the
    /// glucose number through the `WidgetGlucoseUnit` mirror instead of the bare mg/dL "\(g)" text.
    private var unit: WidgetGlucoseUnit { WidgetGlucoseUnit(wireToken: snap.displayUnit) }
    private var bg: String {
        if snap.isHidden(asOf: now) { return "--" }
        guard let g = snap.glucose, g > 0 else { return "--" }
        return unit.format(mgdl: g)
    }
    private var arrow: String { WidgetUI.isStale(snap, now: now) ? "" : snap.trendArrow }
    /// CR-01 (09.29 review): the classified band, kept ONLY to restore the VoiceOver zone word that
    /// the deleted `BandIndicator(...)` used to speak via its own `.accessibilityLabel(shortLabel)` —
    /// no visual glyph is reintroduced. `nil` while stale/hidden/unknown, mirroring `bg`'s gating.
    private var band: GlucoseRange? {
        guard !WidgetUI.isStale(snap, now: now), let g = snap.glucose, g > 0 else { return nil }
        return GlucoseRange.classify(g)
    }
    /// CR-01: the spoken glucose+trend(+band) sentence, mirroring `StatusRingView.a11yLabel`.
    private var glucoseA11yLabel: String {
        band.map { "\(bg), \(arrow), \($0.shortLabel)" } ?? "\(bg), \(arrow)"
    }
    var body: some View {
        HStack(spacing: 14) {
            // Left: current glucose + trend + sparkline.
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(bg)
                        .font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(color)
                    Text(arrow).font(.title3).foregroundStyle(color)
                }
                // CR-01: combine the value+arrow into one spoken element carrying the band word back
                // (the deleted BandIndicator was the only VoiceOver source for it on this tile); the
                // age caption and sparkline below stay separate, unchanged elements.
                .accessibilityElement(children: .combine)
                .accessibilityLabel(glucoseA11yLabel)
                // The SAMPLE age (orange once stale), replacing a static unit label — so a stale relay
                // is visible on the overview, not silently shown as current (group A / C7).
                if let d = snap.glucoseDate {
                    Text(d, style: .relative).font(.caption2)
                        .foregroundStyle(WidgetUI.isStale(snap, now: now) ? .orange : .secondary)
                } else if snap.showUnitLabel {
                    // Owner-requested toggle: this fallback caption (no reading yet, so no age to
                    // show) is the only persistent unit caption this tile renders.
                    Text(unit.unitLabel).font(.caption2).foregroundStyle(.secondary)
                }
                Sparkline(points: snap.recentPoints).frame(height: 34).padding(.top, 2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider()

            // Right: pump metrics.
            VStack(alignment: .leading, spacing: 6) {
                metric("syringe", "Active Insulin", String(format: "%.2f U", snap.iobUnits))
                metric("drop", "Reservoir", "\(Int(snap.reservoirUnits)) U")
                if let u = snap.lastBolusUnits, let d = snap.lastBolusDate {
                    metric("clock.arrow.circlepath", "Last bolus",
                           "\(String(format: "%.2f U", u)) · \(d.formatted(.relative(presentation: .numeric)))")
                } else {
                    // Phase 09.27-02 (D-04/D-05) — routes the glyph + "Charging" text through the
                    // SAME `BatteryChargingPresentation.make` helper every other battery-rendering
                    // surface uses. IN-01 review fix: this is NOT byte-identical to the pre-09.27
                    // code for every percent — the prior fallback here was hardcoded to
                    // `metric("battery.100", "Battery", "\(snap.batteryPercent)%")`, i.e. always the
                    // full-battery glyph regardless of the actual level. Routing through the shared
                    // helper also fixes that pre-existing bug: a not-charging medium widget now
                    // correctly renders the level-appropriate glyph (`battery.0/.25/.50/.75/.100`)
                    // instead of always showing a full battery below 88%.
                    let battery = BatteryChargingPresentation.make(percent: snap.batteryPercent, charging: snap.batteryCharging)
                    // WR-02 review fix: consume the centralized `valueText` instead of
                    // re-interpolating the "N% · Charging" string here.
                    metric(battery.symbolName, "Battery", battery.valueText)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .containerBackground(.fill.tertiary, for: .widget)
    }

    private func metric(_ icon: String, _ title: String, _ value: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon).font(.caption).foregroundStyle(.secondary).frame(width: 16)
            VStack(alignment: .leading, spacing: 0) {
                Text(title).font(.caption2).foregroundStyle(.secondary)
                Text(value).font(.caption).fontWeight(.semibold)
            }
        }
    }
}

/// Minimal glucose sparkline (avoids a Charts dependency in the widget). Scales to the min/max
/// of the recent points, with a faint in-range band at 70–180.
struct Sparkline: View {
    let points: [WidgetSnapshot.Point]

    private var lo: Int { min(points.map { $0.mgdl }.min() ?? WidgetGlucoseThresholds.low, WidgetGlucoseThresholds.low) }
    private var hi: Int { max(points.map { $0.mgdl }.max() ?? WidgetGlucoseThresholds.high, WidgetGlucoseThresholds.high) }

    // E5: plot x PROPORTIONAL to each point's own timestamp, not the array index — so a gap in the data
    // (a dropped relay, a sensor gap) shows as a horizontal gap instead of being compressed into evenly
    // spaced dots that misread as continuous.
    private var t0: TimeInterval { (points.first?.t ?? Date()).timeIntervalSinceReferenceDate }
    private var tSpan: TimeInterval {
        max(1, ((points.last?.t ?? points.first?.t ?? Date()).timeIntervalSinceReferenceDate) - t0)
    }
    private func x(_ pt: WidgetSnapshot.Point, _ width: CGFloat) -> CGFloat {
        width * CGFloat((pt.t.timeIntervalSinceReferenceDate - t0) / tSpan)
    }

    private func y(_ v: Int, _ height: CGFloat) -> CGFloat {
        let span = max(hi - lo, 1)
        return height * (1 - CGFloat(v - lo) / CGFloat(span))
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            ZStack {
                // In-range band (70–180).
                Rectangle().fill(.green.opacity(0.12))
                    .frame(height: max(0, y(WidgetGlucoseThresholds.low, size.height) - y(WidgetGlucoseThresholds.high, size.height)))
                    .position(x: size.width / 2, y: (y(WidgetGlucoseThresholds.low, size.height) + y(WidgetGlucoseThresholds.high, size.height)) / 2)

                if points.count > 1 {
                    Path { p in
                        for (i, pt) in points.enumerated() {
                            let point = CGPoint(x: x(pt, size.width), y: y(pt.mgdl, size.height))
                            if i == 0 { p.move(to: point) } else { p.addLine(to: point) }
                        }
                    }
                    .stroke(.primary.opacity(0.8), style: StrokeStyle(lineWidth: 1.5, lineJoin: .round))
                } else {
                    Text("no recent data").font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
    }
}
