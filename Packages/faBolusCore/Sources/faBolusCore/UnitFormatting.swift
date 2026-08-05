import Foundation

/// Format an insulin amount for display, e.g. `formatUnits(1.5) == "1.50 U"`.
///
/// **R3-J — the `%.2f U` integer-argument diagnostic.** Route unit/dose displays through this rather than
/// an ad-hoc `String(format: "%.2f U", x)`: `String(format:)` is variadic over `CVarArg`, and `Int`
/// conforms to `CVarArg`, so `String(format: "%.2f U", someInt)` compiles silently and prints garbage.
/// This helper's parameter is a `Double`, and Swift does **not** implicitly convert `Int` → `Double`, so
/// passing an `Int` is a **compile error** — a static guard strictly stronger than any runtime check.
/// (No current call site is buggy — every one passes a `Double`/`Float`; this is the preventive funnel for
/// new code. Full migration of existing correct sites is mechanical follow-up.)
public func formatUnits(_ units: Double, fractionDigits: Int = 2) -> String {
    String(format: "%.\(fractionDigits)f U", units)
}
