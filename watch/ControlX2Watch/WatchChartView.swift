import SwiftUI
import Charts

/// History page: a Loop-style glucose plot of the recent readings the phone sends (oldest→newest,
/// ~5-min spacing). Points are range-colored with an in-range band, mirroring the phone chart.
struct WatchChartView: View {
    @Bindable var model: WatchModel

    private var points: [(i: Int, mgdl: Int)] {
        Array(model.history.suffix(72).enumerated()).map { ($0.offset, $0.element) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("History").font(.headline)
            if points.isEmpty {
                Spacer()
                Text("No history yet").font(.caption2).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
                Spacer()
            } else {
                Chart {
                    RectangleMark(yStart: .value("Low", 70), yEnd: .value("High", 180))
                        .foregroundStyle(.green.opacity(0.12))
                    ForEach(points, id: \.i) { p in
                        PointMark(x: .value("t", p.i), y: .value("bg", p.mgdl))
                            .foregroundStyle(watchGlucoseColor(p.mgdl, stale: false))
                            .symbolSize(10)
                    }
                }
                .chartYScale(domain: 40...300)
                .chartYAxis { AxisMarks(values: [70, 180, 250]) }
                .chartXAxis(.hidden)
            }
        }
        .padding(6)
    }
}
