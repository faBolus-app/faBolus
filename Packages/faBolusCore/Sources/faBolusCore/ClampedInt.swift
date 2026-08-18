import Foundation

/// Safely convert an untrusted `Double` to an `Int`, guarding the `Int(_:)` trap.
///
/// `Int(Double)` **traps** ("Double value cannot be converted to Int because it is either infinite or
/// NaN" / overflow) when the value is non-finite (`.infinity` / `.nan`) or outside `Int`'s representable
/// range (e.g. `1e19`, above `Int.max ≈ 9.2e18`). This crash-class has now reached a shipping input path
/// twice — the 09.18c FoodFinder carb-estimate card and the 09.18d LoopInsights caffeine tracker log —
/// each time from a free-text / paste-able `Double` flowing into an `Int(...)`. Rather than re-derive the
/// guard at every site, untrusted `Double`→`Int` conversions route through this single funnel.
///
/// Behavior mirrors the proven `FoodFinderCarbEstimate.grams` pattern: a non-finite value maps to
/// `min` (the floor), and a finite value is clamped in **Double** space to `min...max` BEFORE the
/// conversion. Both bounds are `Int`s chosen to round-trip exactly through `Double` for the ranges used
/// here, so `Int(clamped)` can never trap.
///
/// - Parameters:
///   - value: the untrusted `Double` (may be `.infinity`, `.nan`, or wildly out of range).
///   - min: the inclusive lower bound (default `0`) — also the value returned for a non-finite input.
///   - max: the inclusive upper bound (a sane domain ceiling, e.g. a mg or mg/dL cap).
/// - Returns: an `Int` in `min...max`, never a trap.
public func clampedInt(_ value: Double, min minValue: Int = 0, max maxValue: Int) -> Int {
    precondition(minValue <= maxValue, "clampedInt: min (\(minValue)) must be <= max (\(maxValue))")
    guard value.isFinite else { return minValue }
    let clamped = Swift.min(Swift.max(value.rounded(), Double(minValue)), Double(maxValue))
    return Int(clamped)
}
