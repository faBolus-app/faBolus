import PhoneApp
import SwiftUI
import faBolusCore
import faBolusDesign

/// Time in range, mean, GMI and variability over the chart's day. Off by default (Settings → Display).
struct StatsCardView: View {
    let history: [GlucoseReading]
    let unit: GlucoseUnit
    let showUnitLabels: Bool
    @State private var expanded = true

    var body: some View {
        if history.count >= 2 {
            let s = GlucoseStatistics(readings: history)
            DisclosureGroup(isExpanded: $expanded) {
                VStack(spacing: 12) {
                    tirBar(s)
                    HStack {
                        metric("Time in range", pct(s.timeInRangePct), AppTheme.inRange)
                        Divider()
                        metric("Avg", glucose(Int(s.mean.rounded())), .primary)
                        Divider()
                        metric("GMI", String(format: "%.1f%%", s.gmi), .primary)
                        Divider()
                        metric("CV", pct(s.cv), s.cv <= 36 ? AppTheme.inRange : .orange)
                    }
                    .frame(maxWidth: .infinity)
                    Text("Over \(span(s.spanHours)) · \(s.count) readings · CV ≤ 36% is a common stability target")
                        .font(.caption2).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 6)
            } label: {
                Label("Statistics (last \(span(s.spanHours)))", systemImage: "chart.bar.xaxis").font(.headline)
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
        }
    }

    private func glucose(_ mgdl: Int) -> String { unit.format(mgdl: mgdl) + (showUnitLabels ? " mg/dL" : "") }

    private func tirBar(_ s: GlucoseStatistics) -> some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                band(s.veryLowPct, AppTheme.veryLow, geo)
                band(s.lowPct, AppTheme.low, geo)
                band(s.inRangePct, AppTheme.inRange, geo)
                band(s.highPct, AppTheme.high, geo)
                band(s.veryHighPct, AppTheme.veryHigh, geo)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .frame(height: 16)
        .accessibilityLabel(
            "Time in range \(pct(s.timeInRangePct)), very low \(pct(s.veryLowPct)), low \(pct(s.lowPct)), high \(pct(s.highPct)), very high \(pct(s.veryHighPct))"
        )
    }

    private func band(_ value: Double, _ color: Color, _ geo: GeometryProxy) -> some View {
        color.frame(width: geo.size.width * CGFloat(value / 100))
    }

    private func metric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline).fontWeight(.semibold).foregroundStyle(color)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }
    private func span(_ hours: Double) -> String {
        hours >= 1 ? "\(Int(hours.rounded()))h" : "\(Int((hours * 60).rounded()))m"
    }
}
