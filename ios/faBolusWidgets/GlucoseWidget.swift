import WidgetKit
import SwiftUI
import faBolusCore
import faBolusDesign

/// Blood glucose + trend arrow. Supports the Lock Screen accessory families (the row under the
/// clock) and a Home Screen small tile. Tapping opens the app.
struct GlucoseWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "FaBolusGlucose", provider: FaBolusProvider()) { entry in
            GlucoseWidgetView(snap: entry.snap, now: entry.date)
                .widgetURL(FaBolusDeepLink.open)
        }
        .configurationDisplayName("Glucose")
        .description("Current glucose and trend from your pump's CGM.")
        .supportedFamilies([.accessoryInline, .accessoryCircular, .accessoryRectangular, .systemSmall])
    }
}

struct GlucoseWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snap: WidgetSnapshot
    /// The widget entry's display date — staleness is evaluated against THIS, not wall-clock `Date()`
    /// (a widget renders ahead of time), so a fresh entry greys/hides at its stale/hide crossing entry.
    var now: Date = Date()

    /// Phase 09.1 (D-03): classifies via `faBolusCore.GlucoseRange.classify` and colors via
    /// `faBolusDesign.AppTheme.glucoseColor(_:stale:)` — byte-identical to the deleted local switch
    /// (stale, or an unknown/missing reading, greys exactly as before).
    private var color: Color {
        guard let g = snap.glucose else { return .gray }
        return AppTheme.glucoseColor(g, stale: WidgetUI.isStale(snap, now: now))
    }
    /// Phase 04-03: same fresh/stale/hidden logic as `WidgetUI.glucoseText(_:now:)`, but the
    /// numeric value renders through the `WidgetGlucoseUnit` mirror in the active display unit
    /// (nil `displayUnit` ⇒ mgdl) instead of a bare mg/dL `"\(g)"`.
    private var unit: WidgetGlucoseUnit { WidgetGlucoseUnit(wireToken: snap.displayUnit) }
    private var bg: String {
        if snap.isHidden(asOf: now) { return "--" }
        guard let g = snap.glucose, g > 0 else { return "--" }
        return unit.format(mgdl: g)
    }
    private var arrow: String { WidgetUI.isStale(snap, now: now) ? "" : snap.trendArrow }
    /// CR-01 (09.29 review): the classified band, kept ONLY to restore the VoiceOver zone word that
    /// the deleted `BandIndicator(...)` used to speak via its own `.accessibilityLabel(shortLabel)` —
    /// no visual glyph is reintroduced. `nil` while stale/hidden/unknown (mirrors the gating the
    /// pre-teardown `band` property used, plus the `g > 0` guard `bg` already applies).
    private var band: GlucoseRange? {
        guard !WidgetUI.isStale(snap, now: now), let g = snap.glucose, g > 0 else { return nil }
        return GlucoseRange.classify(g)
    }
    /// CR-01: the spoken glucose+trend(+band) sentence, mirroring `StatusRingView.a11yLabel` /
    /// `WatchGlanceView.glanceGlucoseLabel` — speaks the band word for a live reading so VoiceOver
    /// never depends on zone color alone.
    private var glucoseA11yLabel: String {
        band.map { "\(bg), \(arrow), \($0.shortLabel)" } ?? "\(bg), \(arrow)"
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            // The single line the system places under the clock — only one leading glyph fits;
            // this is a neutral, non-status icon (D-02), not a good/bad band glyph.
            Label("\(bg) \(arrow)", systemImage: "drop.fill")
                .accessibilityLabel(glucoseA11yLabel)

        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Text(bg).font(.system(size: 22, weight: .bold, design: .rounded)).minimumScaleFactor(0.5)
                    HStack(spacing: 2) {
                        // Owner-requested toggle: keep showing the arrow always; only the unitLabel-
                        // as-fallback (when there's no arrow to show) is gated — an empty string when
                        // off, never the unit.
                        Text(arrow.isEmpty ? (snap.showUnitLabel ? unit.unitLabel : "") : arrow).font(.system(size: 11))
                    }
                }
                // CR-01: combine the value+arrow into one spoken element and add the band word back
                // (the deleted BandIndicator was the only VoiceOver source for it on this family).
                .accessibilityElement(children: .combine)
                .accessibilityLabel(glucoseA11yLabel)
            }
            .containerBackground(.clear, for: .widget)

        case .accessoryRectangular:
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "drop.fill").font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(bg) \(arrow)").font(.system(size: 22, weight: .semibold, design: .rounded))
                        // CR-01: restore the VoiceOver band word on the value itself, leaving the IOB
                        // caption below as its own separate, unchanged spoken element.
                        .accessibilityLabel(glucoseA11yLabel)
                    Text("IOB \(String(format: "%.1f U", snap.iobUnits))").font(.caption2)
                }
            }
            .containerBackground(.clear, for: .widget)

        default:  // .systemSmall
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(bg).font(.system(size: 44, weight: .bold, design: .rounded)).foregroundStyle(color)
                    Text(arrow).font(.title2).foregroundStyle(color)
                    Spacer()
                }
                // CR-01: combine the value+arrow row into one spoken element carrying the band word
                // back (the deleted BandIndicator was the only VoiceOver source for it on this tile);
                // the unit caption / IOB / age rows below stay separate, unchanged elements.
                .accessibilityElement(children: .combine)
                .accessibilityLabel(glucoseA11yLabel)
                // Owner-requested toggle: this is the systemSmall tile's only persistent unit caption.
                if snap.showUnitLabel {
                    Text(unit.unitLabel).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                HStack {
                    Label(String(format: "%.1f U", snap.iobUnits), systemImage: "syringe")
                        .font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    // The SAMPLE age (from the reading's own timestamp), not the publish time — always
                    // shown, and orange once the reading is stale, so an old value is never mistaken for
                    // current (group A / C7). Live-updating relative text keyed off the entry date.
                    if let d = snap.glucoseDate {
                        Text(d, style: .relative).font(.caption2)
                            .foregroundStyle(WidgetUI.isStale(snap, now: now) ? .orange : .secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(.fill.tertiary, for: .widget)
        }
    }
}
