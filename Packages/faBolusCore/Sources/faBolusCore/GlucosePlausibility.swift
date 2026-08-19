import Foundation

/// The shared physiologic plausibility gate for an independent CGM reading (D-05) — parallel to
/// `GlucoseFreshness`/`CalcInputFreshness`: one definition of "physiologically plausible", one place to
/// tune, one place to test. A value outside this range is decode/transport corruption or a garbage
/// upload, not real physiology, and must be REJECTED (fail-closed) — never clamped into range, because
/// clamping is fail-open: it silently substitutes a dose input.
///
/// The `[40, 400]` mg/dL range is the SAME one already vendored in `G7SensorKit.GlucoseLimits` and
/// `DexcomG6Kit.GlucoseLimits` — one source of truth, not a third invented value. Both ends inclusive,
/// matching those kits' convention. Enforced at `GlucoseSample`'s failable init (so every current and
/// future `GlucoseSource` inherits it at construction, before `latest`/`history` can hold a bad value)
/// and, independently, inside `BolusMath.estimate` as a dose-path backstop (D-04, defense-in-depth).
public enum GlucosePlausibility {
    /// Inclusive lower bound (mg/dL) — matches the vendored kit `GlucoseLimits.minimum`.
    public static let minimum = 40
    /// Inclusive upper bound (mg/dL) — matches the vendored kit `GlucoseLimits.maximum`.
    public static let maximum = 400
    /// True iff `mgdl` is within the shared physiologic range `[minimum, maximum]`, both ends inclusive.
    public static func isPlausible(mgdl: Int) -> Bool { mgdl >= minimum && mgdl <= maximum }
}
