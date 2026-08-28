import Foundation

/// Shared physiologic plausibility gate for an independent CGM reading — parallel to
/// `GlucoseFreshness` / `CalcInputFreshness`: one definition of "physiologically plausible". A value
/// outside this range is decode/transport corruption or a garbage upload, not real physiology, and
/// must be REJECTED (fail-closed) — never clamped into range. Clamping is fail-open: it silently
/// substitutes a dose input.
///
/// The `[40, 400]` mg/dL range matches the vendored `G7SensorKit.GlucoseLimits` and
/// `DexcomG6Kit.GlucoseLimits` — one source of truth, both ends inclusive. Enforced at
/// `GlucoseSample`'s failable init (every `GlucoseSource` inherits it at construction, before
/// `latest` / `history` can hold a bad value) and, independently, inside `BolusMath.estimate` as a
/// dose-path backstop.
public enum GlucosePlausibility {
    /// Inclusive lower bound (mg/dL) — matches the vendored kit `GlucoseLimits.minimum`.
    public static let minimum = 40
    /// Inclusive upper bound (mg/dL) — matches the vendored kit `GlucoseLimits.maximum`.
    public static let maximum = 400
    /// True iff `mgdl` is within the shared physiologic range `[minimum, maximum]`, both ends inclusive.
    public static func isPlausible(mgdl: Int) -> Bool { mgdl >= minimum && mgdl <= maximum }
}
