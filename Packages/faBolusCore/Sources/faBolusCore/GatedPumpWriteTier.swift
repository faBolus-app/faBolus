import Foundation

/// P14 S8 (§2.1(2)): the clinical-editability TIER of each pump write — the pump-therapy counterpart of
/// the S1 `SettingDescriptor.tier`. The 44 app-preference keys are all `.user`; `.clinician` / `.fixed`
/// were reserved for exactly this — the pump-therapy descriptors. Tier is a DISTINCT axis from the
/// access `gate` (which decides IF a write is allowed) and from the mode axis: tier describes WHO
/// normally owns the value.
///
/// Clinician-tier writes redefine or select the parameters the pump doses from — the insulin profiles
/// (basal / carb-ratio / correction / target, via IDP CRUD + segment edits + active-profile switch),
/// the Control-IQ configuration, the delivery limits, and the CGM glucose thresholds. Everything else is
/// `.user`: delivery, cancel / dismiss, suspend / resume, temp basal, user modes, CGM-session and
/// cartridge operations, clock sync, alert reminders, and a cosmetic profile rename — the person
/// operates these day to day.
///
/// This tier drives the §2.1(2) one-time clinician acknowledgment + non-blocking labeling (S8). It is
/// deliberately NOT a `DenialReason` and NOT the every-time `UnverifiedFeatureGate`: it never blocks a
/// write; a user may take ownership of a clinician-tier setting (recorded as `SettingProvenance.selfSet`)
/// behind a single persisted acknowledgment. No reachable write is `.fixed` (a fixed value is
/// uneditable, so it has no write).
///
/// This lives in an extension (separate file) rather than on the enum so it composes cleanly with the
/// S6 gate reclassification without touching `GatedPumpWrite.swift`.
extension GatedPumpWrite {
    public var requiredTier: SettingTier {
        switch self {
        // Redefine/select the clinical dosing parameters → normally set with a clinician.
        case .setControlIQ, .setMaxBolus, .setMaxBasal,
             .createProfile, .setActiveProfile, .deleteProfile,
             .addProfileSegment, .modifyProfileSegment, .deleteProfileSegment,
             .setCgmHighLowAlert:
            return .clinician
        // Operational / cosmetic — the user owns these day to day (incl. the cosmetic `renameProfile`).
        default:
            return .user
        }
    }

    /// The clinician-tier writes (the §2.1 clinical-ownership set) — for UI labeling and the partition test.
    public static var clinicianTierWrites: [GatedPumpWrite] {
        allCases.filter { $0.requiredTier == .clinician }
    }
}
