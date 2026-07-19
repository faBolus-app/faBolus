import SwiftUI
import Charts

/// Loop-style recent-glucose chart with an in-range band (70–180), range-colored points, a
/// selectable time window, and axis labels.
struct GlucoseChartView: View {
    let readings: [GlucoseReading]
    /// Visible window in hours (3 / 6 / 12 / 24).
    var windowHours: Int = 3

    private var start: Date { Date().addingTimeInterval(-Double(windowHours) * 3600) }
    private var visible: [GlucoseReading] { readings.filter { $0.date >= start } }

    var body: some View {
        Chart {
            RectangleMark(yStart: .value("Low", 70), yEnd: .value("High", 180))
                .foregroundStyle(LoopTheme.inRange.opacity(0.12))

            ForEach(visible) { r in
                PointMark(x: .value("Time", r.date), y: .value("Glucose", r.mgdl))
                    .foregroundStyle(LoopTheme.glucoseColor(r.mgdl))
                    .symbolSize(24)
            }
        }
        .chartXScale(domain: start...Date())
        .chartYScale(domain: 40...300)
        .chartYAxis {
            AxisMarks(position: .leading, values: [70, 120, 180, 250]) { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Int.self) { Text("\(v)") } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: xStride)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour())
            }
        }
        // Y-axis unit label.
        .overlay(alignment: .topLeading) {
            Text("mg/dL").font(.caption2).foregroundStyle(.secondary).padding(.leading, 2)
        }
        .frame(height: 190)
    }

    /// Hour spacing on the X axis so labels stay readable per window.
    private var xStride: Int {
        switch windowHours {
        case ...3: return 1
        case ...6: return 1
        case ...12: return 2
        default: return 4
        }
    }
}
