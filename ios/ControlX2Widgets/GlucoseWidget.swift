import WidgetKit
import SwiftUI

/// Blood glucose + trend arrow. Supports the Lock Screen accessory families (the row under the
/// clock) and a Home Screen small tile. Tapping opens the app.
struct GlucoseWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ControlX2Glucose", provider: ControlX2Provider()) { entry in
            GlucoseWidgetView(snap: entry.snap)
                .widgetURL(ControlX2DeepLink.open)
        }
        .configurationDisplayName("Glucose")
        .description("Current glucose and trend from your pump's CGM.")
        .supportedFamilies([.accessoryInline, .accessoryCircular, .accessoryRectangular, .systemSmall])
    }
}

struct GlucoseWidgetView: View {
    @Environment(\.widgetFamily) private var family
    let snap: WidgetSnapshot

    private var color: Color { WidgetUI.glucoseColor(snap.rangeCategory) }
    private var bg: String { WidgetUI.glucoseText(snap) }
    private var arrow: String { snap.trendAscii }

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
                    if WidgetUI.isStale(snap) {
                        Text(snap.updatedAt, style: .relative).font(.caption2).foregroundStyle(.orange)
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .containerBackground(.fill.tertiary, for: .widget)
        }
    }
}
