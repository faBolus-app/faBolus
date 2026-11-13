import Foundation

/// The single glucose display-unit funnel. mg/dL `Int` is canonical everywhere in faBolusCore,
/// BolusMath and on the remote wire — conversion happens only here, at `format` (mg/dL → display string)
/// and `parse` (entry string → mg/dL `Int`). Every glucose-, ISF-, and target-BG-displaying surface
/// must route through `format`; every glucose-entry surface must route through `parse`. The widgets and
/// the Live Activity call it directly; the Garmin watch gets the unit's `wireToken`.
///
/// mg/dL is the only display unit this release offers; the funnel stays so a future unit is added behind
/// one switch, not scattered call sites.
public enum GlucoseUnit: String, Codable, Sendable, CaseIterable {
    case mgdl

    /// The stable, locale-independent wire token (never raw English on the wire). Identical to
    /// `rawValue` today; kept as a separate name so a future wire representation change does not
    /// require touching every call site (the watch preferences carry it as a string).
    public var wireToken: String { rawValue }

    /// mg/dL → a display string in this unit (the plain integer).
    public func format(mgdl: Int) -> String { "\(mgdl)" }

    /// Entered text (typed in this unit) → mg/dL `Int`, or `nil` if unparseable/empty (a strict
    /// integer parse). Callers MUST treat `nil` as "no BG entered" and must never coerce it to `0` —
    /// a coerced `0` is a fabricated glucose reading entering correction math.
    public func parse(_ text: String) -> Int? { Int(text) }

    /// Threshold label for the four `GlucoseThresholds` TIR constants — the plain mg/dL integer.
    /// `GlucoseThresholds` itself is never touched.
    public static func thresholdLabel(_ mgdl: Int) -> String { "\(mgdl)" }
}
