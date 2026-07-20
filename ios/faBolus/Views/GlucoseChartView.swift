import SwiftUI
import Charts

/// modern chart: glucose (left axis, in-range band, range-colored points) plus an optional
/// **IOB overlay** on a second (right) axis with **vertical bolus bars** (height ∝ units). Each
/// axis can be toggled independently. IOB/bolus values (units) share the right-axis scale.
struct GlucoseChartView: View {
    let readings: [GlucoseReading]
    var iob: [IOBSample] = []
    var boluses: [BolusMarker] = []
    var windowHours: Int = 3
    var showGlucose: Bool = true
    var showIOB: Bool = true

    private var start: Date { Date().addingTimeInterval(-Double(windowHours) * 3600) }
    private var visible: [GlucoseReading] { readings.filter { $0.date >= start } }
    private var visibleIOB: [IOBSample] { iob.filter { $0.date >= start } }
    private var visibleBoluses: [BolusMarker] { boluses.filter { $0.date >= start } }

    // Glucose plot domain (left axis). IOB/bolus (units) are scaled into this domain and labeled
    // on the right axis. The units scale autoscales to the visible window.
    private let gLo = 40.0, gHi = 300.0
    private var iobMax: Double {
        let m = max(visibleIOB.map(\.iob).max() ?? 0, visibleBoluses.map(\.units).max() ?? 0)
        return max(4, (m * 1.1).rounded(.up))
    }
    private func scaleUnits(_ u: Double) -> Double { gLo + (u / iobMax) * (gHi - gLo) }

    var body: some View {
        Chart {
            if showGlucose {
                RectangleMark(yStart: .value("Low", 70), yEnd: .value("High", 180))
                    .foregroundStyle(AppTheme.inRange.opacity(0.12))
                ForEach(visible) { r in
                    PointMark(x: .value("Time", r.date), y: .value("Glucose", r.mgdl))
                        .foregroundStyle(AppTheme.glucoseColor(r.mgdl)).symbolSize(24)
                }
            }
            if showIOB {
                ForEach(visibleBoluses) { b in
                    RuleMark(x: .value("Time", b.date),
                             yStart: .value("Base", gLo), yEnd: .value("Bolus", scaleUnits(b.units)))
                        .foregroundStyle(AppTheme.insulin.opacity(0.55)).lineStyle(.init(lineWidth: 3))
                }
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
                AxisMarks(position: .leading, values: [70, 120, 180, 250]) { value in
                    AxisGridLine()
                    AxisValueLabel { if let v = value.as(Int.self) { Text("\(v)") } }
                }
            }
            if showIOB {
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
            if showGlucose { Text("mg/dL").font(.caption2).foregroundStyle(.secondary).padding(.leading, 2) }
        }
        .overlay(alignment: .topTrailing) {
            if showIOB { Text("U").font(.caption2).foregroundStyle(AppTheme.insulin).padding(.trailing, 2) }
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
