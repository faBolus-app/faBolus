import SwiftUI
import faBolusCore
import faBolusDesign
import Charts
import Accessibility

/// Accessibility helpers for the glucose chart: VoiceOver data points speak time + value + band
/// word (same `GlucoseRange.classify` source as `StatusRingView`), and a non-color symbol shape
/// distinguishes bands so colorblind users can tell hypo from hyper.
enum GlucoseChartAccessibility {
    /// The non-color range cue, as a pure `Equatable` enum — testable without depending on
    /// Swift Charts' `BasicChartSymbolShape` (not `Equatable`, so two shapes can't be compared with
    /// `==` in a test). Mirrors `GlucoseRange`'s four bands 1:1 so `.high` and `.urgentHigh` stay
    /// visually distinguishable from each other, not just from `.inRange`.
    enum SymbolKind: Equatable {
        case low, inRange, high, urgentHigh
    }

    static func symbolKind(for mgdl: Int) -> SymbolKind {
        switch GlucoseRange.classify(mgdl) {
        case .low: return .low
        case .inRange: return .inRange
        case .high: return .high
        case .urgentHigh: return .urgentHigh
        }
    }

    /// Maps the pure `SymbolKind` to the actual shape Swift Charts draws on each `PointMark`.
    static func symbolShape(for kind: SymbolKind) -> BasicChartSymbolShape {
        switch kind {
        case .low: return .square
        case .inRange: return .circle
        case .high: return .triangle
        case .urgentHigh: return .diamond
        }
    }

    /// One AXDataPoint per reading: time + value + unit + band, so VoiceOver can tell WHEN each
    /// point occurred. Locale short time honors 12/24h without a stored DateFormatter.
    static func dataPoints(for readings: [GlucoseReading], unit: GlucoseUnit) -> [AXDataPoint] {
        let unitLabel = unit == .mmol ? "mmol/L" : "mg/dL"
        return readings.map { r in
            let band = GlucoseRange.classify(r.mgdl)
            let time = r.date.formatted(date: .omitted, time: .shortened)
            let label = "\(time), \(unit.format(mgdl: r.mgdl)) \(unitLabel), \(band.shortLabel)"
            return AXDataPoint(x: r.date.timeIntervalSinceReferenceDate, y: Double(r.mgdl), label: label)
        }
    }
}

/// `AXChartDescriptorRepresentable` adapter: wraps the visible glucose readings so
/// `.accessibilityChartDescriptor(_:)` can build an `AXChartDescriptor` from them. Kept as a plain
/// `Equatable` value type distinct from the view itself, per Apple's documented pattern for this
/// modifier — SwiftUI diffs `representable` across body re-evaluations to decide when to rebuild
/// the descriptor.
private struct GlucoseChartAccessibilityRepresentable: AXChartDescriptorRepresentable, Equatable {
    let readings: [GlucoseReading]
    let unit: GlucoseUnit

    func makeChartDescriptor() -> AXChartDescriptor {
        let dataPoints = GlucoseChartAccessibility.dataPoints(for: readings, unit: unit)
        let mgdlValues = readings.map { Double($0.mgdl) }
        let dateValues = readings.map { $0.date.timeIntervalSinceReferenceDate }
        // Empty window (glucose toggled off) must stay a valid non-inverted range.
        let now = Date().timeIntervalSinceReferenceDate
        let xAxis = AXNumericDataAxisDescriptor(
            title: "Time",
            range: (dateValues.min() ?? now)...(dateValues.max() ?? now + 1),
            gridlinePositions: [],
            valueDescriptionProvider: { _ in "" }
        )
        let yAxis = AXNumericDataAxisDescriptor(
            title: "Glucose",
            range: (mgdlValues.min() ?? 0)...(mgdlValues.max() ?? 1),
            gridlinePositions: [],
            valueDescriptionProvider: { value in "\(Int(value)) mg/dL" }
        )
        let series = AXDataSeriesDescriptor(name: "Glucose", isContinuous: false, dataPoints: dataPoints)
        return AXChartDescriptor(title: "Glucose", summary: nil, xAxis: xAxis, yAxis: yAxis, series: [series])
    }
}

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
    /// Y-axis tick labels and the unit caption. Domain, PointMarks, and AxisMarks values stay
    /// mg/dL-scaled — only rendered text converts.
    private var unit: GlucoseUnit { AppSettings.shared.glucoseDisplayUnit }

    /// True when any unit-scaled (right-axis) series is visible.
    private var showUnitsAxis: Bool { showIOB || showBolusBars }

    private var start: Date { Date().addingTimeInterval(-Double(windowHours) * 3600) }
    private var visible: [GlucoseReading] { readings.filter { $0.date >= start } }
    private var visibleIOB: [IOBSample] { iob.filter { $0.date >= start } }
    private var visibleBoluses: [BolusMarker] { boluses.filter { $0.date >= start } }

    // Glucose plot domain: user floor/ceiling via GlucosePlotScale — no hardcoded 40/300.
    // IOB/bolus scale into this domain; right-axis labels recover via the same math.
    private var gLo: Double { Double(AppSettings.shared.glucosePlotFloor) }
    private var gHi: Double { Double(AppSettings.shared.glucosePlotCeiling) }
    private var iobMax: Double {
        // Autoscale the right axis to only the unit series that are actually shown.
        let iobPeak = showIOB ? (visibleIOB.map(\.iob).max() ?? 0) : 0
        let bolusPeak = showBolusBars ? (visibleBoluses.map(\.units).max() ?? 0) : 0
        return max(4, (max(iobPeak, bolusPeak) * 1.1).rounded(.up))
    }
    private func scaleUnits(_ u: Double) -> Double {
        GlucosePlotScale.scaleUnits(u, unitMax: iobMax, floor: AppSettings.shared.glucosePlotFloor,
                                     ceiling: AppSettings.shared.glucosePlotCeiling)
    }

    var body: some View {
        Chart {
            if showGlucose {
                RectangleMark(yStart: .value("Low", GlucoseThresholds.low), yEnd: .value("High", GlucoseThresholds.high))
                    .foregroundStyle(AppTheme.inRange.opacity(0.12))
                ForEach(visible) { r in
                    // Clamp display-only: out-of-range pins to the plot edge instead of clipping
                    // out. r.mgdl (color) is never altered.
                    let plottedY = GlucosePlotScale.clamp(r.mgdl, floor: AppSettings.shared.glucosePlotFloor,
                                                           ceiling: AppSettings.shared.glucosePlotCeiling)
                    // Shape is a non-color channel so colorblind users can still tell bands apart.
                    let symbolKind = GlucoseChartAccessibility.symbolKind(for: r.mgdl)
                    PointMark(x: .value("Time", r.date), y: .value("Glucose", plottedY))
                        .foregroundStyle(AppTheme.glucoseColor(r.mgdl))
                        .symbol(GlucoseChartAccessibility.symbolShape(for: symbolKind))
                        .symbolSize(24)
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
                            // Recover via the same math as scaleUnits so labels stay correct.
                            let recovered = GlucosePlotScale.recoverUnits(
                                p, unitMax: iobMax, floor: AppSettings.shared.glucosePlotFloor,
                                ceiling: AppSettings.shared.glucosePlotCeiling)
                            Text(String(format: "%.1f", recovered))
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
        // VoiceOver swipes individual points (value + band). Empty when glucose is hidden.
        .accessibilityChartDescriptor(GlucoseChartAccessibilityRepresentable(
            readings: showGlucose ? visible : [], unit: unit))
        .overlay(alignment: .topLeading) {
            // Only persistent unit label on the chart. Hidden entirely when off — never a bare fallback.
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
