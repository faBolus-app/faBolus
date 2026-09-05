import Foundation

/// The single glucose display-unit funnel. mg/dL `Int` is canonical everywhere in faBolusCore /
/// BolusMath / RemoteCommand — conversion happens only here, at `format` (mg/dL → display string)
/// and `parse` (entry string → mg/dL `Int`). Every glucose-, ISF-, and target-BG-displaying surface
/// must route through `format`; every glucose-entry surface must route through `parse`. Widget and
/// Garmin mirrors pin against this file (those targets cannot link faBolusCore).
///
/// mg/dL is the only display unit `main` offers today — mmol/L display was removed as dead code
/// (`AppSettings.glucoseDisplayUnit` force-sets `.mgdl` unconditionally on every launch); the
/// funnel itself stays so a future unit re-adds behind one switch, not scattered call sites.
public enum GlucoseUnit: String, Codable, Sendable, CaseIterable {
    case mgdl

    /// The stable, locale-independent wire token (never raw English on the wire). Identical to
    /// `rawValue` today; kept as a separate name so a future wire representation change does not
    /// require touching every call site, and so `RemoteCommand`'s wire field can stay typed `String?`
    /// rather than the enum itself.
    public var wireToken: String { rawValue }

    /// mg/dL → a display string in this unit (the plain integer).
    public func format(mgdl: Int) -> String { "\(mgdl)" }

    /// Entered text (typed in this unit) → mg/dL `Int`, or `nil` if unparseable/empty (a strict
    /// integer parse). Callers MUST treat `nil` as "no BG entered" and must never coerce it to `0` —
    /// a coerced `0` is a fabricated glucose reading entering correction math.
    public func parse(_ text: String) -> Int? { Int(text) }

    /// Threshold label for the four `GlucoseThresholds` TIR constants — the plain mg/dL integer.
    /// `GlucoseThresholds` itself is never touched.
    public static func thresholdLabel(_ mgdl: Int, unit: GlucoseUnit) -> String { "\(mgdl)" }
}
