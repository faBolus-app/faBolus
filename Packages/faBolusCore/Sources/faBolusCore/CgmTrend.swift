import Foundation

/// Maps Dexcom Share's numeric trend encoding to the neutral `GlucoseTrend`. Lives in faBolusCore
/// so it's unit-testable.
///
/// C8: faBolus never *calculates* a trend arrow. A provider's explicit "steady/flat" code is a
/// *reported* trend and maps to `.flat`; but an absent, unknown, none, not-computable, or
/// out-of-range code means the source reports **no** trend and maps to `nil` — which renders as no
/// arrow, never a flat one. (These used to fall back to `.flat`, silently dressing "no trend" as an
/// inferred "steady".)
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

extension CgmTrend {
    /// A Dexcom rate of change (mg/dL per minute) as the arrow the Dexcom app shows: the same seven
    /// arrows Share reports, on the boundaries CGMBLEKit and G7SensorKit use (±1, ±2, ±3). `nil` (the
    /// sensor reports no rate) is no arrow.
    public static func dexcom(rate: Double?) -> GlucoseTrend? {
        guard let rate, rate.isFinite else { return nil }
        switch rate {
        case ...(-3): return .downDown
        case ...(-2): return .down
        case ...(-1): return .falling
        case ..<1: return .flat
        case ..<2: return .rising
        case ..<3: return .up
        default: return .upUp
        }
    }
}
