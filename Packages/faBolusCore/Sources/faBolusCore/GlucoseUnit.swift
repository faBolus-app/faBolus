import Foundation

/// The single glucose display-unit funnel (Phase 4 "mmol/L display-unit support", D-01). mg/dL
/// `Int` is canonical everywhere in faBolusCore/BolusMath/RemoteCommand (D-09) — conversion happens
/// ONLY here, at `format` (mg/dL → display string) and `parse` (entry string → mg/dL `Int`). Every
/// glucose-, ISF-, and target-BG-displaying surface must route through `format`; every glucose-ENTRY
/// surface must route through `parse`. Mirrored (mirror-plus-guard, exactly like `GlucoseThresholds`
/// → `WidgetGlucoseThresholds` → Garmin `AppState.GLUCOSE_*`) into `WidgetShared.swift` (widget/
/// complication targets, which don't link faBolusCore) and `faBolusGarmin/AppState.mc` (Monkey C
/// can't call Swift) in later plans of this phase — this file is the canonical source those mirrors
/// pin against.
///
/// **R3-J-style guard, same rationale as `formatUnits`.** Both members below take the CANONICAL
/// mg/dL `Int` and return either a display `String` or an `Int?`; neither ever accepts or returns a
/// unit-ambiguous `Double` that could be silently misread as the wrong scale.
public enum GlucoseUnit: String, Codable, Sendable, CaseIterable {
    case mgdl, mmol

    /// mg/dL per mmol/L (D-05, locked). This is the ONLY place this conversion factor may appear in
    /// the codebase — never inline the literal value anywhere else; a future correction to the
    /// factor or its rounding rule then updates one place instead of drifting silently across N
    /// call sites.
    public static let mgdlPerMmol = 18.0182

    /// The stable, locale-independent wire token (`CONVENTIONS.md:143` — never raw English on the
    /// wire). Identical to `rawValue` today; kept as a separate name (Pitfall 6) so a future wire
    /// representation change doesn't require touching every call site, and so `RemoteCommand`'s
    /// wire field can stay typed `String?` rather than the enum itself.
    public var wireToken: String { rawValue }

    /// mg/dL → a display string in this unit. `.mmol` is ALWAYS exactly 1 decimal (D-05); `.mgdl` is
    /// the plain integer — byte-identical to every pre-existing "\\(mgdl)" call site.
    public func format(mgdl: Int) -> String {
        switch self {
        case .mgdl: return "\(mgdl)"
        case .mmol: return String(format: "%.1f", Double(mgdl) / Self.mgdlPerMmol)
        }
    }

    /// Entered text (typed in THIS unit) → mg/dL `Int`, or `nil` if unparseable/empty. `.mgdl`: a
    /// strict integer parse — unchanged behavior from the pre-existing bare `Int(text)` call sites.
    /// `.mmol`: a decimal parse, rounded to the NEAREST mg/dL integer (D-07 — "round-trip lossless
    /// within display precision" means mg/dL stays canonical; a typed mmol value maps to the nearest
    /// mg/dL integer, never truncated). Callers MUST treat `nil` as "no BG entered" and must never
    /// coerce it to `0` — a coerced `0` is a fabricated glucose reading entering correction math
    /// (the exact hazard D-07/D-09 exist to prevent).
    public func parse(_ text: String) -> Int? {
        switch self {
        case .mgdl:
            return Int(text)
        case .mmol:
            // CR-04 gap closure: `.decimalPad` presents the device's locale decimal separator
            // (comma in most mainland-Europe mmol/L locales), but `Double(text)` only ever
            // accepts a period. Normalize comma → period before parsing so a correctly-typed
            // entry is never silently dropped to `nil`. This widens ONLY the string→number
            // acceptance; the reject-on-malformed contract (still `nil`, never a guessed `0`)
            // is unchanged for genuinely non-numeric input.
            let normalized = text.replacingOccurrences(of: ",", with: ".")
            guard let v = Double(normalized) else { return nil }
            return Int((v * Self.mgdlPerMmol).rounded())
        }
    }

    /// D-08 (owner decision) — clinically-conventional ROUNDED mmol/L labels for the four
    /// `GlucoseThresholds` TIR constants, NOT `format(mgdl:)` applied to the raw constant (70 mg/dL
    /// raw-converts to 3.885, not the 3.9 a clinician expects to see as a threshold label).
    /// `GlucoseThresholds` itself is never touched by this phase (D-06) — only the rendered LABEL for
    /// one of its four values converts, and only via this table. Still subject to the Phase 10 §13
    /// clinician review per D-08. Any mg/dL value outside the four canonical thresholds falls back to
    /// the plain 1-decimal conversion (non-standard value; not a clinical threshold label).
    public static func thresholdLabel(_ mgdl: Int, unit: GlucoseUnit) -> String {
        guard unit == .mmol else { return "\(mgdl)" }
        switch mgdl {
        case GlucoseThresholds.veryLow: return "3.0"
        case GlucoseThresholds.low: return "3.9"
        case GlucoseThresholds.high: return "10.0"
        case GlucoseThresholds.veryHigh: return "13.9"
        default: return String(format: "%.1f", Double(mgdl) / mgdlPerMmol)
        }
    }
}
