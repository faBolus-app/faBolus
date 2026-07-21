import SwiftUI
import faBolusCore
import Charts

/// History page: a modern glucose plot of the recent readings the phone sends (oldest→newest,
/// ~5-min spacing). Points are range-colored with an in-range band, mirroring the phone chart.
struct WatchChartView: View {
    @Bindable var model: WatchModel
    /// Index into `model.chartRanges` (the phone-selected tap-through ranges). Tap to advance.
    @State private var rangeIndex = 0

    /// Current window in hours (clamped to the mirrored enabled ranges).
    private var windowHours: Int {
        let ranges = model.chartRanges.isEmpty ? [6] : model.chartRanges
        return ranges[rangeIndex % ranges.count]
    }
    /// ~5-min spacing → 12 points/hour; take the most recent window.
    private var points: [(i: Int, mgdl: Int)] {
        Array(model.history.suffix(windowHours * 12).enumerated()).map { ($0.offset, $0.element) }
    }

    private func cycleRange() {
        let count = max(1, model.chartRanges.isEmpty ? 1 : model.chartRanges.count)
        rangeIndex = (rangeIndex + 1) % count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("History").font(.headline)
                Spacer()
                Text("\(windowHours)h").font(.caption2).foregroundStyle(.secondary)
            }
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
        .contentShape(Rectangle())
        .onTapGesture { cycleRange() }
    }
}
