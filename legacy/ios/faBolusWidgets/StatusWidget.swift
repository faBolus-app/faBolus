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
    /// Classifies via `faBolusCore.GlucoseRange.classify` and colors via
    /// `faBolusDesign.AppTheme.glucoseColor(_:stale:)` (stale, or an unknown/missing reading, greys).
    private var color: Color {
        guard let g = snap.glucose else { return .gray }
        return AppTheme.glucoseColor(g, stale: WidgetUI.isStale(snap, now: now))
    }
    /// Resolve the active display unit from the snapshot (nil ⇒ mgdl) and render the
    /// glucose number through the `WidgetGlucoseUnit` mirror instead of the bare mg/dL "\(g)" text.
    private var unit: WidgetGlucoseUnit { WidgetGlucoseUnit(wireToken: snap.displayUnit) }
    private var bg: String {
        if snap.isHidden(asOf: now) { return "--" }
        guard let g = snap.glucose, g > 0 else { return "--" }
        return unit.format(mgdl: g)
    }
    private var arrow: String { WidgetUI.isStale(snap, now: now) ? "" : snap.trendArrow }
    /// The dateless pump metrics (Active Insulin / Reservoir / Battery) carry no intrinsic
    /// timestamp, so they age only against the snapshot's publish time (`updatedAt`). If the host is killed,
    /// no publish re-stamps it — past the TTL these values are no longer trustworthy and must render "--"
    /// rather than freezing pre-suspension numbers as current. Glucose (keyed off `glucoseDate`) and the
    /// dated "Last bolus" row (a real historical fact) are unaffected.
    private var connectionStale: Bool { snap.isConnectionStale(asOf: now) }
    /// The classified band, kept ONLY to restore the VoiceOver zone word that
    /// `BandIndicator` used to speak via its own `.accessibilityLabel(shortLabel)` —
    /// no visual glyph is reintroduced. `nil` while stale/hidden/unknown, mirroring `bg`'s gating.
    private var band: GlucoseRange? {
        guard !WidgetUI.isStale(snap, now: now), let g = snap.glucose, g > 0 else { return nil }
        return GlucoseRange.classify(g)
    }
    /// The spoken glucose+trend(+band) sentence, mirroring `StatusRingView.a11yLabel`.
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
                // Combine the value+arrow into one spoken element carrying the band word;
                // the age caption and sparkline below stay separate, unchanged elements.
                .accessibilityElement(children: .combine)
                .accessibilityLabel(glucoseA11yLabel)
                // The SAMPLE age (orange once stale), replacing a static unit label — so a stale relay
                // is visible on the overview, not silently shown as current.
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
                // AGE-gated, exactly like the reservoir row below: `iobUnits` is a non-optional `0`, and
                // `connectionStale` only answers "did the host stop publishing?" — a LIVE snapshot whose
                // pump never answered op-109 sailed past it and rendered a confident `0.00 U`, and one
                // whose pump answered once and then went quiet did the same forever. A real 0.00 U (no
                // active insulin) still shows `0.00 U` while fresh.
                //
                // Gated on the PUBLISHED IOB window (`iobStaleAfterSec`), not the glucose one, so the
                // widget decays IOB at exactly the moment the phone and the bolus calculator do.
                let iob = PumpValuePresentation.make(
                    snap.iobUnitsIfFresh(asOf: now), format: "%.2f U")
                metric("syringe", "Active Insulin", connectionStale ? "--" : iob.valueText)
                // Through `ReservoirPresentation` on the AGE-gated value, so a reservoir read the pump
                // never answered — or answered once and has not re-answered inside the published
                // staleness window — shows the unknown placeholder rather than a fabricated or
                // long-expired "0 U" (debug `tslim-reservoir-battery-zero`, then
                // `pump-value-decay-to-unknown`). Evaluated at the ENTRY's date, never wall-clock:
                // a widget renders ahead of time.
                //
                // Kept distinct from `connectionStale`'s "--": that means "the host stopped
                // publishing", this means "the pump has not told us lately". The two are independent —
                // an app that is alive and publishing every ~20 s with a dead pump link keeps
                // `connectionStale` false forever, which is exactly the gap this closes.
                let reservoir = ReservoirPresentation.make(
                    units: snap.reservoirUnitsIfFresh(asOf: now))
                metric("drop", "Reservoir", connectionStale ? "--" : reservoir.valueText)
                if let u = snap.lastBolusUnits, let d = snap.lastBolusDate {
                    metric(
                        "clock.arrow.circlepath", "Last bolus",
                        "\(String(format: "%.2f U", u)) · \(d.formatted(.relative(presentation: .numeric)))")
                } else {
                    // Route the glyph + "Charging" text through the SAME `BatteryChargingPresentation.make`
                    // helper every other battery-rendering surface uses, so a not-charging medium widget
                    // renders the level-appropriate glyph (`battery.0/.25/.50/.75/.100`) instead of always
                    // showing a full battery. Charging is never shown as a warning.
                    // Age-gated percent — neither an unread NOR a gone-quiet battery may render as a
                    // dead one. A real 0 % still renders 0 % while fresh.
                    let battery = BatteryChargingPresentation.make(
                        percent: snap.batteryPercentIfFresh(asOf: now),
                        charging: snap.batteryCharging)
                    // Consume the centralized `valueText` instead of re-interpolating the
                    // "N% · Charging" string here. Once the snapshot's publish time is stale (host
                    // killed), the battery value greys to "--" — it is a dateless metric with no
                    // intrinsic timestamp to age against.
                    metric(battery.symbolName, "Battery", connectionStale ? "--" : battery.valueText)
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

    private var lo: Int {
        min(points.map { $0.mgdl }.min() ?? WidgetGlucoseThresholds.low, WidgetGlucoseThresholds.low)
    }
    private var hi: Int {
        max(points.map { $0.mgdl }.max() ?? WidgetGlucoseThresholds.high, WidgetGlucoseThresholds.high)
    }

    // Plot x PROPORTIONAL to each point's own timestamp, not the array index — so a gap in the data
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
                    .frame(
                        height: max(
                            0,
                            y(WidgetGlucoseThresholds.low, size.height) - y(WidgetGlucoseThresholds.high, size.height))
                    )
                    .position(
                        x: size.width / 2,
                        y: (y(WidgetGlucoseThresholds.low, size.height) + y(WidgetGlucoseThresholds.high, size.height))
                            / 2)

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
