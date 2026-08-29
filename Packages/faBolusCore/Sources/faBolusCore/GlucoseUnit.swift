import Foundation

/// The single glucose display-unit funnel. mg/dL `Int` is canonical everywhere in faBolusCore /
/// BolusMath / RemoteCommand — conversion happens only here, at `format` (mg/dL → display string)
/// and `parse` (entry string → mg/dL `Int`). Every glucose-, ISF-, and target-BG-displaying surface
/// must route through `format`; every glucose-entry surface must route through `parse`. Widget and
/// Garmin mirrors pin against this file (those targets cannot link faBolusCore).
///
/// Both members take the canonical mg/dL `Int` and return a display `String` or an `Int?`; neither
/// ever accepts or returns a unit-ambiguous `Double` that could be silently misread as the wrong
/// scale.
public enum GlucoseUnit: String, Codable, Sendable, CaseIterable {
    case mgdl, mmol

    /// mg/dL per mmol/L. The only place this conversion factor may appear — never inline the literal
    /// elsewhere; a correction to the factor or its rounding then updates one place.
    public static let mgdlPerMmol = 18.0182

    /// The stable, locale-independent wire token (never raw English on the wire). Identical to
    /// `rawValue` today; kept as a separate name so a future wire representation change does not
    /// require touching every call site, and so `RemoteCommand`'s wire field can stay typed `String?`
    /// rather than the enum itself.
    public var wireToken: String { rawValue }

    /// mg/dL → a display string in this unit. `.mmol` is always exactly 1 decimal; `.mgdl` is the
    /// plain integer.
    public func format(mgdl: Int) -> String {
        switch self {
        case .mgdl: return "\(mgdl)"
        case .mmol: return String(format: "%.1f", Double(mgdl) / Self.mgdlPerMmol)
        }
    }

    /// Entered text (typed in this unit) → mg/dL `Int`, or `nil` if unparseable/empty. `.mgdl`: a
    /// strict integer parse. `.mmol`: a decimal parse, rounded to the nearest mg/dL integer (mg/dL
    /// stays canonical; a typed mmol value maps to the nearest mg/dL integer, never truncated).
    /// Callers MUST treat `nil` as "no BG entered" and must never coerce it to `0` — a coerced `0`
    /// is a fabricated glucose reading entering correction math.
    public func parse(_ text: String) -> Int? {
        switch self {
        case .mgdl:
            return Int(text)
        case .mmol:
            // `.decimalPad` presents the device's locale decimal separator (comma in most
            // mainland-Europe mmol/L locales), but `Double(text)` only ever accepts a period.
            // Normalize comma → period before parsing so a correctly-typed entry is never silently
            // dropped to `nil`. This widens only the string→number acceptance; the
            // reject-on-malformed contract (still `nil`, never a guessed `0`) is unchanged for
            // genuinely non-numeric input.
            let normalized = text.replacingOccurrences(of: ",", with: ".")
            guard let v = Double(normalized) else { return nil }
            return Int((v * Self.mgdlPerMmol).rounded())
        }
    }

    /// Clinically-conventional rounded mmol/L labels for the four `GlucoseThresholds` TIR constants,
    /// NOT `format(mgdl:)` applied to the raw constant (70 mg/dL raw-converts to 3.885, not the 3.9
    /// a clinician expects as a threshold label). `GlucoseThresholds` itself is never touched — only
    /// the rendered label for one of its four values converts, and only via this table. Any mg/dL
    /// value outside the four canonical thresholds falls back to the plain 1-decimal conversion.
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
