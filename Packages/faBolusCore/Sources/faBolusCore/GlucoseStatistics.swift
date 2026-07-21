import Foundation

/// Pure glucose statistics over a window of readings, for the opt-in stats screen. Computed over
/// whatever history is in memory (~24 h today — the app keeps a rolling buffer, not a persistent
/// store). Percentages are reading-count based (each ~5-min CGM point weighted equally), which
/// matches how CGM apps report Time-in-Range for a regular-cadence sensor.
///
/// All values are totals — empty input yields zeros so the UI only has to decide whether to show the
/// card, never to special-case the math.
public struct GlucoseStatistics: Equatable, Sendable {
    public let count: Int
    public let mean: Double            // mg/dL
    public let gmi: Double             // % — ADA Glucose Management Indicator
    public let cv: Double              // % — coefficient of variation (variability)
    public let timeInRangePct: Double  // % in 70–180 (the headline TIR number)
    // Standard AGP breakdown (% of readings), most-severe-low → most-severe-high.
    public let veryLowPct: Double      // < 54
    public let lowPct: Double          // 54–69
    public let inRangePct: Double      // 70–180
    public let highPct: Double         // 181–250
    public let veryHighPct: Double     // > 250
    public let spanHours: Double       // span from first→last reading

    public init(count: Int, mean: Double, gmi: Double, cv: Double, timeInRangePct: Double,
                veryLowPct: Double, lowPct: Double, inRangePct: Double, highPct: Double,
                veryHighPct: Double, spanHours: Double) {
        self.count = count; self.mean = mean; self.gmi = gmi; self.cv = cv
        self.timeInRangePct = timeInRangePct
        self.veryLowPct = veryLowPct; self.lowPct = lowPct; self.inRangePct = inRangePct
        self.highPct = highPct; self.veryHighPct = veryHighPct; self.spanHours = spanHours
    }

    public static let empty = GlucoseStatistics(count: 0, mean: 0, gmi: 0, cv: 0, timeInRangePct: 0,
                                                veryLowPct: 0, lowPct: 0, inRangePct: 0, highPct: 0,
                                                veryHighPct: 0, spanHours: 0)

    /// Compute all statistics over the given readings (order-independent).
    public init(readings: [GlucoseReading]) {
        guard !readings.isEmpty else { self = .empty; return }
        let values = readings.map { Double($0.mgdl) }
        let n = Double(values.count)
        let mean = values.reduce(0, +) / n
        let variance = values.reduce(0) { $0 + ($1 - mean) * ($1 - mean) } / n
        let std = variance.squareRoot()

        func pct(_ predicate: (Int) -> Bool) -> Double {
            Double(readings.filter { predicate($0.mgdl) }.count) / n * 100
        }
        let dates = readings.map { $0.date }
        let span = (dates.max()!.timeIntervalSince(dates.min()!)) / 3600

        self.init(
            count: readings.count,
            mean: mean,
            gmi: 3.31 + 0.02392 * mean,                 // ADA GMI (mg/dL) formula
            cv: mean > 0 ? std / mean * 100 : 0,
            timeInRangePct: pct { $0 >= 70 && $0 <= 180 },
            veryLowPct: pct { $0 < 54 },
            lowPct: pct { $0 >= 54 && $0 < 70 },
            inRangePct: pct { $0 >= 70 && $0 <= 180 },
            highPct: pct { $0 > 180 && $0 <= 250 },
            veryHighPct: pct { $0 > 250 },
            spanHours: span
        )
    }
}
