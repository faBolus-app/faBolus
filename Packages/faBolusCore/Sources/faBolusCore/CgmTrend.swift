import Foundation

/// Maps each cloud provider's trend encoding to the neutral `GlucoseTrend`, plus a helper for the
/// .NET `/Date(...)/` timestamps Dexcom Share returns. Lives in faBolusCore so it's unit-testable.
///
/// C8: faBolus never *calculates* a trend arrow. A provider's explicit "steady/flat" code is a
/// *reported* trend and maps to `.flat`; but an absent, unknown, none, not-computable, or
/// out-of-range code means the source reports **no** trend and maps to `nil` — which renders as no
/// arrow, never a flat one. (These used to fall back to `.flat`, silently dressing "no trend" as an
/// inferred "steady" — the same drift `GlucoseTrend.token(from:)` was fixed to eliminate.)
public enum CgmTrend {
    /// Nightscout `direction` strings. `nil`/"NONE"/"NOT COMPUTABLE"/"RATE OUT OF RANGE"/unknown → no trend.
    public static func nightscout(_ s: String?) -> GlucoseTrend? {
        switch s {
        case "DoubleUp": return .upUp
        case "SingleUp": return .up
        case "FortyFiveUp": return .rising
        case "Flat": return .flat
        case "FortyFiveDown": return .falling
        case "SingleDown": return .down
        case "DoubleDown": return .downDown
        default: return nil  // absent / NONE / NOT COMPUTABLE / RATE OUT OF RANGE → no arrow
        }
    }

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

    /// Dexcom Share string trend (newer API). "none"/"notcomputable"/"rateoutofrange"/unknown → no trend.
    public static func dexcom(name: String) -> GlucoseTrend? {
        switch name.lowercased() {
        case "doubleup": return .upUp
        case "singleup": return .up
        case "fortyfiveup": return .rising
        case "flat": return .flat
        case "fortyfivedown": return .falling
        case "singledown": return .down
        case "doubledown": return .downDown
        default: return nil
        }
    }

    /// LibreLinkUp `TrendArrow` (1…5). 3 is Flat (steady); absent/unknown → no trend.
    public static func libre(_ n: Int) -> GlucoseTrend? {
        switch n {
        case 1: return .down
        case 2: return .falling
        case 3: return .flat
        case 4: return .rising
        case 5: return .up
        default: return nil  // absent / unknown → no arrow
        }
    }

    /// Parse a .NET `/Date(1620000000000)/` (optionally with a `-0800` offset) to a Date.
    public static func dotNetDate(_ s: String) -> Date? {
        guard let open = s.firstIndex(of: "("), let close = s.firstIndex(of: ")") else { return nil }
        var digits = String(s[s.index(after: open)..<close])
        if let sign = digits.firstIndex(where: { $0 == "+" || $0 == "-" }) { digits = String(digits[..<sign]) }
        guard let ms = Double(digits) else { return nil }
        return Date(timeIntervalSince1970: ms / 1000)
    }
}
