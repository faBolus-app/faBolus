import SwiftUI
import faBolusCore

/// Opt-in statistics card (Settings → Display → "Show statistics card"). Summarizes the in-memory
/// ~24 h glucose history: Time-in-Range, the AGP band breakdown, GMI, average, and variability (CV).
/// Collapsible so it stays out of the way even when enabled.
struct StatsCardView: View {
    let history: [GlucoseReading]
    @State private var expanded = true

    private var stats: GlucoseStatistics { GlucoseStatistics(readings: history) }

    var body: some View {
        if history.count >= 2 {
            let s = stats
            DisclosureGroup(isExpanded: $expanded) {
                VStack(spacing: 12) {
                    tirBar(s)
                    HStack {
                        metric("Time in range", "\(pct(s.timeInRangePct))", .green)
                        Divider()
                        metric("Avg", "\(Int(s.mean.rounded())) mg/dL", .primary)
                        Divider()
                        metric("GMI", String(format: "%.1f%%", s.gmi), .primary)
                        Divider()
                        metric("CV", "\(pct(s.cv))", s.cv <= 36 ? .green : .orange)
                    }
                    .frame(maxWidth: .infinity)
                    Text("Over \(spanLabel(s.spanHours)) · \(s.count) readings · CV ≤ 36% is a common stability target")
                        .font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.top, 6)
            } label: {
                Label("Statistics (last \(spanLabel(s.spanHours)))", systemImage: "chart.bar.xaxis")
                    .font(.headline)
            }
            .padding()
            .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14))
            .padding(.horizontal)
        }
    }

    /// Stacked AGP band bar: very-low / low / in-range / high / very-high.
    @ViewBuilder private func tirBar(_ s: GlucoseStatistics) -> some View {
        GeometryReader { geo in
            HStack(spacing: 0) {
                band(s.veryLowPct, .red, geo)
                band(s.lowPct, .orange, geo)
                band(s.inRangePct, .green, geo)
                band(s.highPct, .yellow, geo)
                band(s.veryHighPct, Color.yellow.opacity(0.6), geo)
            }
            .clipShape(RoundedRectangle(cornerRadius: 5))
        }
        .frame(height: 16)
        .accessibilityLabel("Time in range \(pct(s.timeInRangePct)), low \(pct(s.veryLowPct + s.lowPct)), high \(pct(s.highPct + s.veryHighPct))")
    }

    private func band(_ pctVal: Double, _ color: Color, _ geo: GeometryProxy) -> some View {
        color.frame(width: geo.size.width * CGFloat(pctVal / 100))
    }

    private func metric(_ title: String, _ value: String, _ color: Color) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.subheadline).fontWeight(.semibold).foregroundStyle(color)
            Text(title).font(.caption2).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private func pct(_ v: Double) -> String { "\(Int(v.rounded()))%" }

    private func spanLabel(_ hours: Double) -> String {
        hours >= 1 ? "\(Int(hours.rounded()))h" : "\(Int((hours * 60).rounded()))m"
    }
}
