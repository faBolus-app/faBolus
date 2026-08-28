import Foundation

/// Shared glucose-plot Y-axis bound math. Every chart surface and every test consumes this for the
/// plot floor/ceiling — no per-surface literal bound, clamp, or scale computation may reappear
/// (same "one funnel" idea as `GlucoseThresholds` / `GlucoseUnit`).
///
/// Display-only. Never references any dose/delivery/signed-path type. Computes the Y-axis range a
/// chart renders in; never alters, filters, or judges a glucose reading's clinical meaning.
public enum GlucosePlotScale {

    /// Discrete floor presets, mg/dL. Capped at 50 so the `veryLow` (54) reference line and any
    /// severe-low reading always stay on-chart.
    public static let floorOptions: [Int] = [40, 50]

    /// Discrete ceiling presets, mg/dL. Hard min 250 so `veryHigh` (250) always stays on-chart.
    public static let ceilingOptions: [Int] = [250, 300, 350, 400]

    /// Defaults matching the original hardcoded chart view.
    public static let defaultFloor = 40
    public static let defaultCeiling = 300

    /// Enforced minimum floor↔ceiling gap. `floorOptions.max` (50) and `ceilingOptions.min` (250)
    /// are already 200 mg/dL apart, so any combination of today's presets clears this; it exists as
    /// a safety floor against a future preset-set edit that narrows the options too far.
    public static let minGap = 100

    /// Snap a stored (possibly absent/out-of-set/corrupt) floor+ceiling pair to a safe in-set pair.
    /// An absent value or a value not in the option set lands on the nearest option (default when
    /// `nil`); the returned pair always satisfies `floor < ceiling` with at least `minGap` between
    /// them — if snapping the two independently would violate the gap (impossible with today's
    /// option sets, but defensive against a future edit), the ceiling is pushed up to the smallest
    /// ceiling option that clears the gap, falling back to `defaultCeiling` if no option clears it.
    public static func resolve(storedFloor: Int?, storedCeiling: Int?) -> (floor: Int, ceiling: Int) {
        let floor = nearestOption(to: storedFloor, in: floorOptions, default: defaultFloor)
        var ceiling = nearestOption(to: storedCeiling, in: ceilingOptions, default: defaultCeiling)
        if ceiling - floor < minGap {
            if let safe = ceilingOptions.first(where: { $0 - floor >= minGap }) {
                ceiling = safe
            } else {
                ceiling = defaultCeiling
            }
        }
        return (floor, ceiling)
    }

    private static func nearestOption(to value: Int?, in options: [Int], default def: Int) -> Int {
        guard let value else { return def }
        if options.contains(value) { return value }
        return options.min(by: { abs($0 - value) < abs($1 - value) }) ?? def
    }

    /// Plot-layer clamp only: a reading above `ceiling` pins to `ceiling`; below `floor` pins to
    /// `floor`; an in-range value is returned unchanged. The stored reading itself is never mutated —
    /// callers apply this only to the value handed to the plotting layer, never as a dose input.
    public static func clamp(_ mgdl: Int, floor: Int, ceiling: Int) -> Int {
        if mgdl > ceiling { return ceiling }
        if mgdl < floor { return floor }
        return mgdl
    }

    /// Maps a secondary-axis unit value (e.g. IOB units) linearly into the glucose domain:
    /// `0 -> floor`, `unitMax -> ceiling`. Used by the iPhone chart's IOB overlay so the overlay's
    /// scale always tracks both the user's floor and ceiling, never a hardcoded pair.
    public static func scaleUnits(_ u: Double, unitMax: Double, floor: Int, ceiling: Int) -> Double {
        guard unitMax != 0 else { return Double(floor) }
        let fraction = u / unitMax
        return Double(floor) + fraction * Double(ceiling - floor)
    }

    /// Inverse of `scaleUnits` — recovers the original unit value from a glucose-domain Y position,
    /// so the right-axis label at any Y position matches what was scaled there.
    public static func recoverUnits(_ y: Double, unitMax: Double, floor: Int, ceiling: Int) -> Double {
        let span = Double(ceiling - floor)
        guard span != 0 else { return 0 }
        let fraction = (y - Double(floor)) / span
        return fraction * unitMax
    }

    /// mg/dL integer, or a clinically-rounded 1-decimal mmol label, mapped from the canonical mg/dL
    /// `Int` via the same `GlucoseUnit` funnel every other glucose display uses — no second
    /// conversion implementation.
    public static func boundLabel(_ mgdl: Int, unit: GlucoseUnit) -> String {
        unit.format(mgdl: mgdl)
    }

    /// True exactly when the band edges (70/180) AND all four threshold marks (veryLow/low/high/
    /// veryHigh) fall within `[floor, ceiling]` inclusive. Used by the drift-guard test (every
    /// preset combo keeps the clinical marks on-chart) and available to any render-time check.
    public static func allBandMarksWithinDomain(floor: Int, ceiling: Int) -> Bool {
        let marks = [
            GlucoseThresholds.veryLow,
            GlucoseThresholds.low,
            GlucoseThresholds.high,
            GlucoseThresholds.veryHigh,
        ]
        return marks.allSatisfy { floor <= $0 && $0 <= ceiling }
    }
}
