import SwiftUI
import faBolusCore
import faBolusDesign

/// Opt-in statistics card (Settings → Display → "Show statistics card"). Summarizes the in-memory
/// ~24 h glucose history: Time-in-Range, the AGP band breakdown, GMI, average, and variability (CV).
/// Collapsible so it stays out of the way even when enabled.
struct StatsCardView: View {
    let history: [GlucoseReading]
    @State private var expanded = true

    private var stats: GlucoseStatistics { GlucoseStatistics(readings: history) }

    /// Phase 04-02 (D-10): the display-unit funnel the "Avg" metric routes through. `s.mean` stays
    /// computed in mg/dL (unchanged); only its displayed string converts.
    private var unit: GlucoseUnit { AppSettings.shared.glucoseDisplayUnit }

    /// "<value> mg/dL"/"<value> mmol/L" — a whole-phrase catalog VARIANT selected by the active
    /// display unit (D-10; not a glued suffix). `Localizable.xcstrings` carries both as siblings.
    /// Owner-requested toggle: bare value (no unit phrase) when labels are hidden.
    private func glucoseLabel(_ mgdl: Int) -> String {
        let value = unit.format(mgdl: mgdl)
        guard AppSettings.shared.showGlucoseUnitLabels else { return value }
        return unit == .mmol
            ? String(format: String(localized: "%@ mmol/L"), value)
            : String(format: String(localized: "%@ mg/dL"), value)
    }

    var body: some View {
        if history.count >= 2 {
            let s = stats
            DisclosureGroup(isExpanded: $expanded) {
                VStack(spacing: 12) {
                    tirBar(s)
                    HStack {
                        metric("Time in range", "\(pct(s.timeInRangePct))", .green)
                        Divider()
                        metric("Avg", glucoseLabel(Int(s.mean.rounded())), .primary)
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
    ///
    /// Phase 17 (D2-03): routed through `faBolusDesign.AppTheme`'s band tokens instead of raw `Color`
    /// literals — `AppTheme.veryLow`/`.veryHigh` are the two NET-NEW severe-band tokens this phase added
    /// specifically for this bar (WCAG-audited by `AppThemeContrastAuditTests`); `.low`/`.inRange`/`.high`
    /// are the pre-existing §13-locked tokens. Pinned raw-literal-free by
    /// `BandDriftGuardTests.noRawBandColorInStatsCardViewTirBar`.
    @ViewBuilder private func tirBar(_ s: GlucoseStatistics) -> some View {
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
        .accessibilityLabel("Time in range \(pct(s.timeInRangePct)), very low \(pct(s.veryLowPct)), low \(pct(s.veryLowPct + s.lowPct)), high \(pct(s.highPct + s.veryHighPct))")
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
