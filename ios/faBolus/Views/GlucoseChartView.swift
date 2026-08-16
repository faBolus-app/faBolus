import SwiftUI
import faBolusCore
import faBolusDesign
import Charts

/// modern chart: glucose (left axis, in-range band, range-colored points) plus an optional
/// **IOB line** and optional **vertical bolus bars** (height ∝ units) on a second (right) axis.
/// Glucose, IOB, and bolus bars each toggle independently. IOB/bolus values (units) share the
/// right-axis scale, which autoscales to whichever unit series are currently shown.
struct GlucoseChartView: View {
    let readings: [GlucoseReading]
    var iob: [IOBSample] = []
    var boluses: [BolusMarker] = []
    var windowHours: Int = 3
    var showGlucose: Bool = true
    var showIOB: Bool = true
    var showBolusBars: Bool = true

    /// Phase 04-02 (D-10): the display-unit funnel the Y-axis tick LABELS and the "mg/dL"/"mmol/L"
    /// caption route through. The chart domain, PointMark data, and AxisMarks tick VALUES stay
    /// mg/dL-scaled (Pitfall 4) — only the rendered text below changes.
    private var unit: GlucoseUnit { AppSettings.shared.glucoseDisplayUnit }

    /// True when any unit-scaled (right-axis) series is visible.
    private var showUnitsAxis: Bool { showIOB || showBolusBars }

    private var start: Date { Date().addingTimeInterval(-Double(windowHours) * 3600) }
    private var visible: [GlucoseReading] { readings.filter { $0.date >= start } }
    private var visibleIOB: [IOBSample] { iob.filter { $0.date >= start } }
    private var visibleBoluses: [BolusMarker] { boluses.filter { $0.date >= start } }

    // Glucose plot domain (left axis). IOB/bolus (units) are scaled into this domain and labeled
    // on the right axis. The units scale autoscales to the visible window.
    private let gLo = 40.0, gHi = 300.0
    private var iobMax: Double {
        // Autoscale the right axis to only the unit series that are actually shown.
        let iobPeak = showIOB ? (visibleIOB.map(\.iob).max() ?? 0) : 0
        let bolusPeak = showBolusBars ? (visibleBoluses.map(\.units).max() ?? 0) : 0
        return max(4, (max(iobPeak, bolusPeak) * 1.1).rounded(.up))
    }
    private func scaleUnits(_ u: Double) -> Double { gLo + (u / iobMax) * (gHi - gLo) }

    var body: some View {
        Chart {
            if showGlucose {
                RectangleMark(yStart: .value("Low", GlucoseThresholds.low), yEnd: .value("High", GlucoseThresholds.high))
                    .foregroundStyle(AppTheme.inRange.opacity(0.12))
                ForEach(visible) { r in
                    PointMark(x: .value("Time", r.date), y: .value("Glucose", r.mgdl))
                        .foregroundStyle(AppTheme.glucoseColor(r.mgdl)).symbolSize(24)
                }
            }
            if showBolusBars {
                ForEach(visibleBoluses) { b in
                    RuleMark(x: .value("Time", b.date),
                             yStart: .value("Base", gLo), yEnd: .value("Bolus", scaleUnits(b.units)))
                        .foregroundStyle(AppTheme.insulin.opacity(0.55)).lineStyle(.init(lineWidth: 3))
                }
            }
            if showIOB {
                ForEach(visibleIOB) { s in
                    LineMark(x: .value("Time", s.date), y: .value("IOB", scaleUnits(s.iob)),
                             series: .value("Series", "IOB"))
                        .foregroundStyle(AppTheme.insulin).interpolationMethod(.monotone)
                }
            }
        }
        .chartXScale(domain: start...Date())
        .chartYScale(domain: gLo...gHi)
        .chartYAxis {
            if showGlucose {
                AxisMarks(position: .leading, values: [GlucoseThresholds.low, 120, GlucoseThresholds.high, GlucoseThresholds.veryHigh]) { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Int.self) { Text(unit.format(mgdl: v)) } }
                }
            }
            if showUnitsAxis {
                AxisMarks(position: .trailing, values: [scaleUnits(0), scaleUnits(iobMax / 2), scaleUnits(iobMax)]) { value in
                    AxisValueLabel {
                        if let p = value.as(Double.self) {
                            Text(String(format: "%.1f", (p - gLo) / (gHi - gLo) * iobMax))
                        }
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .hour, count: xStride)) { _ in
                AxisGridLine(); AxisValueLabel(format: .dateTime.hour())
            }
        }
        .overlay(alignment: .topLeading) {
            // Owner-requested toggle: this axis caption is the only persistent unit label the chart
            // draws — hidden entirely when off, never a bare fallback (the axis itself stays labeled
            // with numeric ticks either way).
            if showGlucose && AppSettings.shared.showGlucoseUnitLabels {
                Text(unit == .mmol ? String(localized: "mmol/L") : String(localized: "mg/dL"))
                    .font(.caption2).foregroundStyle(.secondary).padding(.leading, 2)
            }
        }
        .overlay(alignment: .topTrailing) {
            if showUnitsAxis { Text("U").font(.caption2).foregroundStyle(AppTheme.insulin).padding(.trailing, 2) }
        }
        .frame(height: 160)
    }

    private var xStride: Int {
        switch windowHours {
        case ...3: return 1
        case ...6: return 1
        case ...12: return 2
        default: return 4
        }
    }
}
