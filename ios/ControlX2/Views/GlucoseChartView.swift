import SwiftUI
import Charts

/// Loop-style recent-glucose chart with an in-range band (70–180) and range-colored points.
struct GlucoseChartView: View {
    let readings: [GlucoseReading]

    var body: some View {
        Chart {
            RectangleMark(
                yStart: .value("Low", 70), yEnd: .value("High", 180)
            )
            .foregroundStyle(LoopTheme.inRange.opacity(0.12))

            ForEach(readings) { r in
                PointMark(x: .value("Time", r.date), y: .value("Glucose", r.mgdl))
                    .foregroundStyle(LoopTheme.glucoseColor(r.mgdl))
                    .symbolSize(28)
            }
        }
        .chartYScale(domain: 40...300)
        .chartYAxis {
            AxisMarks(values: [70, 180, 250]) { value in
                AxisGridLine()
                AxisValueLabel { if let v = value.as(Int.self) { Text("\(v)") } }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour)) { _ in
                AxisGridLine(); AxisValueLabel(format: .dateTime.hour())
            }
        }
        .frame(height: 180)
    }
}
