import Foundation

/// Display-unit helper for LoopInsights report surfaces. Formats a canonical mg/dL `Int` into the
/// user's unit and the Time-in-Range range label. No AI-prompt / advisor surface is ported — this
/// only formats numbers a clinician report needs. All formatting routes through `GlucoseUnit.format`
/// / `GlucoseUnit.thresholdLabel` so the mg/dL↔mmol/L factor and clinically-rounded threshold labels
/// live in one place.
public struct InsightsGlucoseUnitContext: Sendable, Equatable {
    public let unit: GlucoseUnit

    public init(unit: GlucoseUnit) { self.unit = unit }

    /// Display unit caption — "mg/dL" or "mmol/L".
    public var unitString: String {
        switch unit {
        case .mgdl: return "mg/dL"
        case .mmol: return "mmol/L"
        }
    }

    /// Format a canonical mg/dL `Int` into the user's display unit via `GlucoseUnit.format` (mmol/L is
    /// always 1-decimal; mg/dL is the plain integer). Never re-derives the conversion.
    public func formatMgdl(_ mgdl: Int) -> String { unit.format(mgdl: mgdl) }

    /// Convenience for `Double` mg/dL values (e.g. an average) — rounded to the nearest mg/dL `Int`
    /// before routing through the single `GlucoseUnit.format` funnel. L-01: the `Double`→`Int` step goes
    /// through the shared `clampedInt` guard so a non-finite / out-of-range value (latent today, since
    /// callers pass bounded means of stored `Int` mg/dL) can never trap `Int(_:)` if this shim is ever
    /// reused for a free-entered value. Clamped to a physiologically-absurd-but-safe mg/dL ceiling.
    public func formatMgdl(_ mgdl: Double) -> String {
        unit.format(mgdl: clampedInt(mgdl, max: 10_000))
    }

    /// The lower TIR threshold (70 mg/dL) as a unit-appropriate label — clinically-rounded in mmol/L
    /// ("3.9", not a raw 70/18.0182 conversion).
    public var lowThresholdLabel: String {
        GlucoseUnit.thresholdLabel(GlucoseThresholds.low, unit: unit)
    }

    /// The upper TIR threshold (180 mg/dL) as a unit-appropriate label ("10.0" in mmol/L).
    public var highThresholdLabel: String {
        GlucoseUnit.thresholdLabel(GlucoseThresholds.high, unit: unit)
    }

    /// "Time in Range (70–180)" / "Time in Range (3.9–10.0)" — the endo report's TIR row label.
    public var tirRangeLabel: String {
        "Time in Range (\(lowThresholdLabel)–\(highThresholdLabel))"
    }
}
