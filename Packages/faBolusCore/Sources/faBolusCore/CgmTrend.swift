import Foundation

/// Maps each cloud provider's trend encoding to the neutral `GlucoseTrend`, plus a helper for the
/// .NET `/Date(...)/` timestamps Dexcom Share returns. Lives in faBolusCore so it's unit-testable.
public enum CgmTrend {
    /// Nightscout `direction` strings.
    public static func nightscout(_ s: String?) -> GlucoseTrend {
        switch s {
        case "DoubleUp": return .upUp
        case "SingleUp": return .up
        case "FortyFiveUp": return .rising
        case "FortyFiveDown": return .falling
        case "SingleDown": return .down
        case "DoubleDown": return .downDown
        default: return .flat
        }
    }

    /// Dexcom Share numeric trend (1…7).
    public static func dexcom(_ n: Int) -> GlucoseTrend {
        switch n {
        case 1: return .upUp; case 2: return .up; case 3: return .rising
        case 5: return .falling; case 6: return .down; case 7: return .downDown
        default: return .flat   // 4 Flat, 0/other unknown
        }
    }

    /// Dexcom Share string trend (newer API).
    public static func dexcom(name: String) -> GlucoseTrend {
        switch name.lowercased() {
        case "doubleup": return .upUp
        case "singleup": return .up
        case "fortyfiveup": return .rising
        case "fortyfivedown": return .falling
        case "singledown": return .down
        case "doubledown": return .downDown
        default: return .flat
        }
    }

    /// LibreLinkUp `TrendArrow` (1…5).
    public static func libre(_ n: Int) -> GlucoseTrend {
        switch n {
        case 1: return .down; case 2: return .falling; case 4: return .rising; case 5: return .up
        default: return .flat   // 3 Flat
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
