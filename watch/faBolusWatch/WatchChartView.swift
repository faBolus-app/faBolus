import SwiftUI
import faBolusCore
import faBolusDesign
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
    /// Recent readings for the selected window, plotted against REAL time when the host sent per-point
    /// timestamps (`historyDates`, same length as `history`) — so a data gap renders as a gap rather than
    /// evenly-spaced dots (E5: the plot had no time axis, only uniform index spacing). Falls back to a
    /// synthesized ~5-min spacing back from now when timestamps aren't available.
    private var points: [(date: Date, mgdl: Int)] {
        let h = model.history
        guard !h.isEmpty else { return [] }
        let dates = model.historyDates
        if dates.count == h.count {
            let cutoff = Date().addingTimeInterval(-Double(windowHours) * 3600)
            return zip(dates, h).filter { $0.0 >= cutoff }.map { (date: $0.0, mgdl: $0.1) }
        }
        let recent = Array(h.suffix(windowHours * 12))   // ~5-min spacing → 12 points/hour
        let now = Date()
        return recent.enumerated().map { i, mgdl in
            (date: now.addingTimeInterval(Double(i - recent.count) * 300), mgdl: mgdl)
        }
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
                    RectangleMark(yStart: .value("Low", GlucoseThresholds.low), yEnd: .value("High", GlucoseThresholds.high))
                        .foregroundStyle(AppTheme.inRange.opacity(0.12))
                    ForEach(points.indices, id: \.self) { idx in
                        PointMark(x: .value("t", points[idx].date), y: .value("bg", points[idx].mgdl))
                            .foregroundStyle(AppTheme.glucoseColor(points[idx].mgdl, stale: false))
                            .symbolSize(10)
                    }
                }
                .chartYScale(domain: 40...300)
                .chartYAxis { AxisMarks(values: [GlucoseThresholds.low, GlucoseThresholds.high, GlucoseThresholds.veryHigh]) }
                .chartXAxis(.hidden)   // time is the X *value* (proportional spacing); labels stay off on the small face
            }
        }
        .padding(6)
        .contentShape(Rectangle())
        .onTapGesture { cycleRange() }
    }
}
