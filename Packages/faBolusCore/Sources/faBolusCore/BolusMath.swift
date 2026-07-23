import Foundation

/// The single, canonical bolus-dose calculator for faBolus.
///
/// This is a faithful Swift port of the vendored Tandem oracle `BolusCalculator.parse()`
/// (PumpX2Kit `vendor/pumpx2-oracle/.../calculator/BolusCalculator.java`). It replaces four
/// divergent formulas that previously lived in `TandemBackend`, `RemoteClientModel`, the Garmin
/// `AppState`, and `MockBackend`. The most important behavior it fixes (audit C-01): a **below-target**
/// BG correction is kept **signed** and only the *total* is floored at zero — so a low glucose reduces
/// the dose, instead of the old `max(0, …)` that clamped the correction term before combining and
/// produced an over-recommendation.
///
/// The pump cannot compute a dose from carbs; this mirrors the calculator the pump/t:connect use so a
/// faBolus-computed dose matches what the pump would suggest. Every surface (phone, Watch, Mac,
/// remote-iPhone) must route through this; the Garmin watch carries a hand-port of the same branch
/// logic in `AppState.mc` (Monkey C can't call Swift) that is kept in lockstep.
///
/// Verified against the real oracle: `BolusMathParityTests` runs ~2.8k input vectors through the actual
/// `BolusCalculator.java` (fixtures captured from the JVM) and asserts this port matches its `getTotal()`.
public enum BolusMath {

    /// The pump bolus-calculator profile inputs, already scaled to human units (the oracle stores carb
    /// ratio and IOB ×1000; callers pass the divided values, matching `BolusCalcDataSnapshotResponse`
    /// accessors like `carbRatioGramsPerUnit`).
    public struct Profile: Sendable, Equatable {
        public var carbRatioGramsPerUnit: Double   // g/U
        public var isfMgdlPerUnit: Int             // mg/dL per U
        public var targetBgMgdl: Int               // mg/dL
        public var iobUnits: Double                // U (≤ 0 is treated as no IOB, matching the oracle's `iob > 0` gate)
        public init(carbRatioGramsPerUnit: Double, isfMgdlPerUnit: Int, targetBgMgdl: Int, iobUnits: Double) {
            self.carbRatioGramsPerUnit = carbRatioGramsPerUnit
            self.isfMgdlPerUnit = isfMgdlPerUnit
            self.targetBgMgdl = targetBgMgdl
            self.iobUnits = iobUnits
        }
    }

    /// The decomposed result. `totalUnits` is the oracle's `getTotal()` — the amount the pump would
    /// suggest, always ≥ 0 and 0 when a sanity check fails. Components are the (rounded) contributions.
    public struct Result: Sendable, Equatable {
        public var totalUnits: Double
        public var fromCarbs: Double
        public var fromBG: Double
        public var fromIOB: Double
        /// True when the carb ratio is invalid, the target BG is outside [40, 400], or (with a BG
        /// present) the ISF is ≤ 0. The oracle returns 0 units in these cases; callers should treat this
        /// as "profile unavailable / do not trust", not as a real 0-unit recommendation.
        public var sanityFailed: Bool
    }

    /// Faithful port of `BolusCalculator.parse()` for the food/correction/IOB path.
    /// - Parameters:
    ///   - carbsGrams: grams of carbohydrate, or `nil` for a correction-only bolus (no carb component).
    ///   - bgMgdl: the glucose used for the correction, or `nil` when no (fresh) BG is available — in
    ///     which case there is no BG correction (matching the oracle when `lastBG` is absent).
    ///   - profile: the pump calculator inputs.
    public static func estimate(carbsGrams: Double?, bgMgdl: Int?, profile: Profile) -> Result {
        // --- addedFromCarbs (getAddedFromCarbs): each component is doublePrecision-rounded first ---
        var fromCarbs = 0.0
        var carbSanityFail = false
        if let carbs = carbsGrams {
            if profile.carbRatioGramsPerUnit > 0 {
                fromCarbs = dp(carbs / profile.carbRatioGramsPerUnit)
            } else {
                carbSanityFail = true   // FailedSanityCheck: invalid carb ratio
            }
        }

        // --- addedFromGlucose (getAddedFromGlucose) ---
        var fromBG = 0.0
        var bgSanityFail = false
        if let bg = bgMgdl {
            if profile.targetBgMgdl < 40 || profile.targetBgMgdl > 400 {
                bgSanityFail = true     // target out of range / empty
            } else if profile.isfMgdlPerUnit <= 0 {
                bgSanityFail = true     // no ISF present
            } else {
                fromBG = dp(Double(bg - profile.targetBgMgdl) / Double(profile.isfMgdlPerUnit))
            }
        }

        // --- addedFromIOB (getAddedFromIOB): only positive IOB reduces the dose ---
        let fromIOB = profile.iobUnits > 0 ? dp(-profile.iobUnits) : 0.0

        // --- parse() combination ---
        var total = fromCarbs
        if fromBG >= 0 {
            // at or above target
            let corr = fromBG + fromIOB
            if corr < 0 {
                // NO_POSITIVE_BG_CORRECTION — IOB exceeds the correction; add nothing
            } else if corr == 0 {
                // do nothing
            } else {
                total += corr   // POSITIVE_BG_CORRECTION
            }
        } else {
            // below target — correction is negative and *reduces* the dose
            let corr = fromBG + fromIOB
            if corr == 0 {
                // do nothing (unreachable: fromBG < 0 here)
            } else if total + corr > 0 {
                total += corr   // NEGATIVE_BG_CORRECTION
            } else {
                total = 0.0     // correction + IOB would take it negative → floor the total at 0
            }
        }
        total = dp(total)

        let sanityFailed = carbSanityFail || bgSanityFail
        if sanityFailed {
            // Oracle returns fromUser(0) when any FailedSanityCheck is present.
            return Result(totalUnits: 0, fromCarbs: 0, fromBG: 0, fromIOB: 0, sanityFailed: true)
        }
        return Result(totalUnits: max(0, total), fromCarbs: fromCarbs, fromBG: fromBG, fromIOB: fromIOB,
                      sanityFailed: false)
    }

    /// Convenience: just the recommended total units (≥ 0), matching the oracle `getTotal()`.
    public static func recommendedUnits(carbsGrams: Double?, bgMgdl: Int?, profile: Profile) -> Double {
        estimate(carbsGrams: carbsGrams, bgMgdl: bgMgdl, profile: profile).totalUnits
    }

    /// The oracle's `BolusCalcUnits.doublePrecision`: `BigDecimal.valueOf(v).setScale(2, HALF_UP)`.
    /// Replicated with `Decimal` built from the value's shortest decimal string (so it rounds the
    /// human-decimal value, not the binary artifact — e.g. 2.675 → 2.68, matching BigDecimal) and
    /// `.plain` rounding (round half away from zero == Java HALF_UP).
    static func dp(_ v: Double) -> Double {
        if !v.isFinite { return v }
        var d = Decimal(string: String(v)) ?? Decimal(v)
        var r = Decimal()
        NSDecimalRound(&r, &d, 2, .plain)
        return NSDecimalNumber(decimal: r).doubleValue
    }
}
