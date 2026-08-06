import Foundation

/// Source-cited bounds for advanced pump-control writes, so the UI stops re-hardcoding magic numbers
/// (a bare `0...250` slider, ad-hoc duration lists) that could silently drift from what the pump firmware
/// actually accepts.
///
/// **§13 — every bound names its source.** These mirror the limits the pump firmware enforces, as encoded
/// canonically in PumpX2Kit's request types (`SetTempRateRequest`, `InitiateBolusRequest`). faBolusCore
/// stays free of the PumpX2 message layer, so — like `WidgetGlucoseThresholds` and `PumpFeatureBits` —
/// these are a **mirror**, and an app-target drift test (`PumpControlBoundsMirrorTests`, which links both
/// faBolusCore and PumpX2Messages) pins the mirror equal to the kit constants so the two can't diverge.
///
/// These are pump-firmware **limits**, not therapy parameters: they bound what a control write may
/// request, they don't recommend a value.
public enum PumpControlBounds {
    // MARK: Temp rate — mirrors `SetTempRateRequest` (the pump rejects out-of-range values).
    /// Minimum temp-rate duration the pump accepts (minutes). Kit: `SetTempRateRequest.minMinutes`.
    public static let tempRateMinMinutes = 15
    /// Maximum temp-rate duration the pump accepts (minutes = 72 h). Kit: `SetTempRateRequest.maxMinutes`.
    public static let tempRateMaxMinutes = 72 * 60
    /// Minimum temp-rate percent (% of scheduled basal). Kit: `SetTempRateRequest.minPercent`.
    public static let tempRateMinPercent = 0
    /// Maximum temp-rate percent (% of scheduled basal). Kit: `SetTempRateRequest.maxPercent`.
    public static let tempRateMaxPercent = 250

    // MARK: Extended (combo) bolus — mirrors `InitiateBolusRequest`.
    /// Minimum total dispensable extended-bolus dose, milliunits (0.40 U). Kit:
    /// `InitiateBolusRequest.minExtendedBolusMilliunits`. (The pump exposes no named *maximum* extended
    /// duration — that stays a UI/product choice, deliberately not asserted here as a firmware bound.)
    public static let extendedBolusMinMilliunits = 400

    /// Clamp a requested temp-rate percent into the pump-accepted range.
    public static func clampTempRatePercent(_ p: Int) -> Int {
        min(max(p, tempRateMinPercent), tempRateMaxPercent)
    }
    /// Clamp a requested temp-rate duration (minutes) into the pump-accepted range.
    public static func clampTempRateMinutes(_ m: Int) -> Int {
        min(max(m, tempRateMinMinutes), tempRateMaxMinutes)
    }
}
