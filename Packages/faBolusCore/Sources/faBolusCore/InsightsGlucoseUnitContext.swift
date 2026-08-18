import Foundation

/// The faBolus glucose-unit shim for the LoopInsights benign surfaces (D-15). Replaces the mirror
/// `LoopInsights_GlucoseUnitContext` (which imports LoopKit / LoopKitUI / HealthKit and wraps an
/// `HKUnit` / `DisplayGlucosePreference`, plus an `aiPromptUnitContext()` AI-prompt builder) with a
/// thin, dependency-free wrapper over faBolusCore's own [[GlucoseUnit]].
///
/// **D-14 (binding):** NO AI-prompt / advisor surface is ported. This type only formats a canonical
/// mg/dL `Int` into the user's display unit and produces the Time-in-Range range label — everything
/// the endo report needs, nothing that could feed a model or an advisor. All formatting routes
/// through `GlucoseUnit.format` / `GlucoseUnit.thresholdLabel` so the mg/dL↔mmol/L conversion factor
/// and the clinically-rounded threshold labels live in exactly one place (D-05/D-08).
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
    /// (D-08: "3.9", not a raw 70/18.0182 conversion).
    public var lowThresholdLabel: String {
        GlucoseUnit.thresholdLabel(GlucoseThresholds.low, unit: unit)
    }

    /// The upper TIR threshold (180 mg/dL) as a unit-appropriate label ("10.0" in mmol/L, D-08).
    public var highThresholdLabel: String {
        GlucoseUnit.thresholdLabel(GlucoseThresholds.high, unit: unit)
    }

    /// "Time in Range (70–180)" / "Time in Range (3.9–10.0)" — the endo report's TIR row label.
    public var tirRangeLabel: String {
        "Time in Range (\(lowThresholdLabel)–\(highThresholdLabel))"
    }
}
