import WidgetKit
import SwiftUI

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

    private var color: Color { WidgetUI.glucoseColor(snap, now: now) }
    private var bg: String { WidgetUI.glucoseText(snap, now: now) }
    private var arrow: String { WidgetUI.isStale(snap, now: now) ? "" : snap.trendArrow }

    var body: some View {
        switch family {
        case .accessoryInline:
            // The single line the system places under the clock.
            Label("\(bg) \(arrow)", systemImage: "drop.fill")

        case .accessoryCircular:
            ZStack {
                AccessoryWidgetBackground()
                VStack(spacing: 0) {
                    Text(bg).font(.system(size: 22, weight: .bold, design: .rounded)).minimumScaleFactor(0.5)
                    Text(arrow.isEmpty ? "mg/dL" : arrow).font(.system(size: 11))
                }
            }
            .containerBackground(.clear, for: .widget)

        case .accessoryRectangular:
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: "drop.fill").font(.title3)
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(bg) \(arrow)").font(.system(size: 22, weight: .semibold, design: .rounded))
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
                Text("mg/dL").font(.caption).foregroundStyle(.secondary)
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
