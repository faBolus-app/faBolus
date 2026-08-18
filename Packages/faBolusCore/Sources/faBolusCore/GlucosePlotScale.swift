import Foundation

/// The single shared glucose-plot Y-axis bound math (Phase 09.13 "glucose plot height
/// customization", D-01/D-02/D-08/D-09/D-10). Every surface's chart (iPhone, Watch, Mac, Garmin's
/// mirror) and every test consumes THIS math for the plot floor/ceiling — no per-surface literal
/// bound, clamp, or scale computation may reappear anywhere else (mirrors the `GlucoseThresholds`/
/// `GlucoseUnit` "one funnel" precedent).
///
/// **Display-only (D-11).** This type never references or imports any dose/delivery/signed-path
/// type. It only computes the Y-axis RANGE a chart renders in — it never alters, filters, or judges
/// a glucose reading's clinical meaning.
public enum GlucosePlotScale {

    /// Discrete floor presets, mg/dL (D-02). Capped at 50 so the §13 `veryLow` (54) reference line
    /// and any severe-low reading always stay on-chart (owner-chosen conservative floor, D-10).
    public static let floorOptions: [Int] = [40, 50]

    /// Discrete ceiling presets, mg/dL (D-02). Hard min 250 so `veryHigh` (250) always stays
    /// on-chart (D-10).
    public static let ceilingOptions: [Int] = [250, 300, 350, 400]

    /// D-01 defaults — preserve today's hardcoded view exactly.
    public static let defaultFloor = 40
    public static let defaultCeiling = 300

    /// The enforced minimum floor↔ceiling gap (Claude's discretion, documented per the plan).
    /// `floorOptions.max` (50) and `ceilingOptions.min` (250) are already 200 mg/dL apart, so any
    /// combination of the discrete presets naturally clears this gap; it exists purely as a safety
    /// floor against a future preset-set edit that narrows the options too far.
    public static let minGap = 100

    /// Snap a stored (possibly absent/out-of-set/corrupt) floor+ceiling pair to a safe in-set pair
    /// (D-01/D-02/D-10; threat T-09.13-01). An absent value or a value not in the option set lands
    /// on the nearest option (default when `nil`); the returned pair always satisfies
    /// `floor < ceiling` with at least `minGap` between them — if snapping the two independently
    /// would violate the gap (impossible with today's option sets, but defensive against a future
    /// edit), the ceiling is pushed up to the smallest ceiling option that clears the gap, falling
    /// back to `defaultCeiling` if no option clears it.
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

    /// Symmetric clamp (D-08): a reading above `ceiling` pins to `ceiling`; below `floor` pins to
    /// `floor`; an in-range value is returned unchanged. The input reading itself is never mutated
    /// by this call — callers apply this only to the value handed to the plotting layer.
    public static func clamp(_ mgdl: Int, floor: Int, ceiling: Int) -> Int {
        if mgdl > ceiling { return ceiling }
        if mgdl < floor { return floor }
        return mgdl
    }

    /// Maps a secondary-axis unit value (e.g. IOB units) linearly into the glucose domain:
    /// `0 -> floor`, `unitMax -> ceiling` (D-09). Used by the iPhone chart's IOB overlay so the
    /// overlay's scale always tracks BOTH the user's floor and ceiling, never a hardcoded pair.
    public static func scaleUnits(_ u: Double, unitMax: Double, floor: Int, ceiling: Int) -> Double {
        guard unitMax != 0 else { return Double(floor) }
        let fraction = u / unitMax
        return Double(floor) + fraction * Double(ceiling - floor)
    }

    /// The exact inverse of `scaleUnits` (D-09) — recovers the original unit value from a glucose-
    /// domain Y position, so the right-axis label at any Y position matches what was scaled there.
    public static func recoverUnits(_ y: Double, unitMax: Double, floor: Int, ceiling: Int) -> Double {
        let span = Double(ceiling - floor)
        guard span != 0 else { return 0 }
        let fraction = (y - Double(floor)) / span
        return fraction * unitMax
    }

    /// mg/dL integer, or a clinically-rounded 1-decimal mmol label (D-02), mapped from the
    /// canonical mg/dL `Int` via the same `GlucoseUnit` funnel every other glucose display uses —
    /// no second conversion implementation.
    public static func boundLabel(_ mgdl: Int, unit: GlucoseUnit) -> String {
        unit.format(mgdl: mgdl)
    }

    /// D-10 — true exactly when the §13 band edges (70/180) AND all four threshold marks
    /// (veryLow/low/high/veryHigh) fall within `[floor, ceiling]` inclusive. Used both by the drift
    /// guard (`GlucosePlotBandIntegrityTests`, proving every preset combo keeps the clinical marks
    /// on-chart) and available to any render-time assertion that wants the same check.
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
