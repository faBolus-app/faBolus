import Foundation

/// Maps Dexcom Share's numeric trend encoding to the neutral `GlucoseTrend`. Lives in faBolusCore
/// so it's unit-testable.
///
/// C8: faBolus never *calculates* a trend arrow. A provider's explicit "steady/flat" code is a
/// *reported* trend and maps to `.flat`; but an absent, unknown, none, not-computable, or
/// out-of-range code means the source reports **no** trend and maps to `nil` — which renders as no
/// arrow, never a flat one. (These used to fall back to `.flat`, silently dressing "no trend" as an
/// inferred "steady" — the same drift `GlucoseTrend.token(from:)` was fixed to eliminate.)
public enum CgmTrend {
    /// Dexcom Share numeric trend (1…7). 0 None, 8 NotComputable, 9 RateOutOfRange, other → no trend.
    public static func dexcom(_ n: Int) -> GlucoseTrend? {
        switch n {
        case 1: return .upUp
        case 2: return .up
        case 3: return .rising
        case 4: return .flat
        case 5: return .falling
        case 6: return .down
        case 7: return .downDown
        default: return nil  // 0 None / 8 NotComputable / 9 RateOutOfRange / other → no arrow
        }
    }
}
