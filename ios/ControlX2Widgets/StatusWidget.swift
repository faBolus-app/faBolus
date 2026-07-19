import WidgetKit
import SwiftUI

/// Home Screen medium overview: glucose + trend + a sparkline, with Active Insulin, reservoir,
/// and last bolus. Tapping opens the app.
struct StatusWidget: Widget {
    var body: some WidgetConfiguration {
        StaticConfiguration(kind: "ControlX2Status", provider: ControlX2Provider()) { entry in
            StatusWidgetView(snap: entry.snap)
                .widgetURL(ControlX2DeepLink.open)
        }
        .configurationDisplayName("Pump Overview")
        .description("Glucose trend, active insulin, reservoir, and last bolus.")
        .supportedFamilies([.systemMedium])
    }
}

struct StatusWidgetView: View {
    let snap: WidgetSnapshot
    private var color: Color { WidgetUI.glucoseColor(snap.rangeCategory) }

    var body: some View {
        HStack(spacing: 14) {
            // Left: current glucose + trend + sparkline.
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(WidgetUI.glucoseText(snap))
                        .font(.system(size: 40, weight: .bold, design: .rounded)).foregroundStyle(color)
                    Text(snap.isGlucoseStale ? "" : snap.trendArrow).font(.title3).foregroundStyle(color)
                }
                Text("mg/dL").font(.caption2).foregroundStyle(.secondary)
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
                    metric("battery.100", "Battery", "\(snap.batteryPercent)%")
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

    private var lo: Int { min(points.map { $0.mgdl }.min() ?? 70, 70) }
    private var hi: Int { max(points.map { $0.mgdl }.max() ?? 180, 180) }

    private func y(_ v: Int, _ height: CGFloat) -> CGFloat {
        let span = max(hi - lo, 1)
        return height * (1 - CGFloat(v - lo) / CGFloat(span))
    }

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let step = points.count > 1 ? size.width / CGFloat(points.count - 1) : 0
            ZStack {
                // In-range band (70–180).
                Rectangle().fill(.green.opacity(0.12))
                    .frame(height: max(0, y(70, size.height) - y(180, size.height)))
                    .position(x: size.width / 2, y: (y(70, size.height) + y(180, size.height)) / 2)

                if points.count > 1 {
                    Path { p in
                        for (i, pt) in points.enumerated() {
                            let point = CGPoint(x: CGFloat(i) * step, y: y(pt.mgdl, size.height))
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
