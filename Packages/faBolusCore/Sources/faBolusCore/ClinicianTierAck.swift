import Foundation

/// P14 S8 (§2.1(2)): copy for the one-time clinician-tier acknowledgment + labeling. Pure and
/// pump-neutral so the wording lives in one place and is testable; the actual persistence is a single
/// timestamp in `AppSettings` (durable, per-install), and it NEVER gates a write — it is an
/// acknowledgment, not a lock (not a `DenialReason`, not the every-time `UnverifiedFeatureGate`).
///
/// §13 STATUS: SIGNED-OFF (owner Zev Granowitz, 2026-08-09) — approved verbatim. The owner is the §13
/// approver of record and this sign-off satisfies the §13 copy-distribution gate for these strings.
/// Any wording change re-opens the sign-off.
public enum ClinicianTierAck {
    /// The first-use disclosure body. References the §13 provenance vocabulary (`SettingProvenance`):
    /// these values are normally `.clinicianSet`; a change made here is recorded as `.selfSet`, distinct
    /// from the `.consensusDefault`.
    public static let disclosure = """
        Delivery limits, Control-IQ, and insulin profiles — basal rates, insulin-to-carb ratios, and \
        correction factors — are normally set with your clinician. faBolus lets you view and change them \
        here without a clinician; a change you make is recorded as "set by you", distinct from a value set \
        with your clinician or a consensus default. This is not medical advice — confirm changes with your \
        care team.
        """

    /// A short, non-blocking label for a clinician-tier settings section.
    public static let sectionLabel = "Clinician-tier — normally set with your clinician."

    /// Human label for a recorded provenance (for where a setting's origin is surfaced).
    public static func label(for provenance: SettingProvenance) -> String {
        switch provenance {
        case .consensusDefault: return "Consensus default"
        case .clinicianSet: return "Set with clinician"
        case .selfSet: return "Set by you"
        }
    }
}
