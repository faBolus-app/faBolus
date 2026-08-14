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
    /// Phase 09.1 (D-04) — the classified band for the redundant icon(+word) non-color channel,
    /// `nil` while stale/unknown (the number is already greyed then; no band color to duplicate,
    /// mirroring `StatusRingView`).
    private var band: GlucoseRange? {
        guard !WidgetUI.isStale(snap, now: now), let g = snap.glucose else { return nil }
        return GlucoseRange.classify(g)
    }

    var body: some View {
        switch family {
        case .accessoryInline:
            // The single line the system places under the clock — only one leading glyph fits, so
            // the band's own symbol (icon-only backstop, UI-SPEC #4) replaces the generic drop icon
            // instead of adding a second element this family can't render.
            Label("\(bg) \(arrow)", systemImage: band?.symbolName ?? "drop.fill")

        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Text(bg).font(.system(size: 22, weight: .bold, design: .rounded)).minimumScaleFactor(0.5)
                    HStack(spacing: 2) {
                        if let band {
                            BandIndicator(band: band, showWord: false)
                                .font(.system(size: 10))
                        }
                        // Owner-requested toggle: keep showing the arrow always; only the unitLabel-
                        // as-fallback (when there's no arrow to show) is gated — an empty string when
                        // off, never the unit.
                        Text(arrow.isEmpty ? (snap.showUnitLabel ? unit.unitLabel : "") : arrow).font(.system(size: 11))
                    }
                }
            }
            .containerBackground(.clear, for: .widget)

        case .accessoryRectangular:
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: band?.symbolName ?? "drop.fill").font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(bg) \(arrow)").font(.system(size: 22, weight: .semibold, design: .rounded))
                    if let band {
                        BandIndicator(band: band, showWord: true)
                            .font(.caption2)
                    }
                    Text("IOB \(String(format: "%.1f U", snap.iobUnits))").font(.caption2)
                }
            }
            .containerBackground(.clear, for: .widget)

        default: // .systemSmall
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(bg).font(.system(size: 44, weight: .bold, design: .rounded)).foregroundStyle(color)
                    Text(arrow).font(.title2).foregroundStyle(color)
                    Spacer()
                }
                if let band {
                    BandIndicator(band: band, showWord: true)
                        .font(.caption2).foregroundStyle(.secondary)
                }
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
