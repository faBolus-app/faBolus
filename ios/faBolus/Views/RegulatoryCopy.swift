import Foundation

// P16 F5 (N20) — regulatory-status copy, single source of truth.
//
// §13 STATUS: SIGNED-OFF (owner Zev Granowitz, 2026-08-09). Per BRANCHES.md §13 the owner is the
// approver of record for this regulatory wording, and this sign-off ALONE satisfies the §13
// copy-distribution gate for these exact strings (independent of the standing NO-GO for real insulin,
// which is unchanged). It is centralised here so the first-run overlay (ModeOnboardingView) and the
// About section (AboutSettingsView) state the SAME thing, and a future copy edit can't silently drop
// the key regulatory terms — RegulatoryCopyTests asserts each string still carries `requiredKeywords`.
// This is copy only: no control flow, gating, dose logic, or delivery behaviour depends on these
// strings. Any change to the wording re-opens the §13 sign-off.

/// The app's regulatory-status copy. Two surfaces, one disposition.
enum RegulatoryCopy {
    /// First-run overlay footnote (`ModeOnboardingView`). Concise and non-alarming; keeps the
    /// experimental / not-FDA-cleared / check-every-value intent and adds the not-a-medical-device,
    /// experimental / demonstration-use, no-real-insulin framing.
    static let firstRun =
        "faBolus is experimental, in-development software — not a medical device and not FDA-cleared. It is for experimental and demonstration use, and is not for delivering real insulin or making real therapy decisions. Not medical advice — check every value against your pump and your clinician."

    /// About & help footer (`AboutSettingsView`), so the same status is findable after onboarding.
    /// Keeps the trademark and non-affiliation lines.
    static let about =
        "faBolus™ is an independent, open-source project in development for experimental use. It is not a medical device and is not FDA-cleared; it is for experimental and demonstration use, and is not for delivering real insulin or making real therapy decisions. Not affiliated with Tandem Diabetes Care or Dexcom. faBolus™ is a trademark of Zev Granowitz."

    /// Terms a guard test requires remain present (case-insensitively) in BOTH strings above, so the
    /// wording can be strengthened but not silently weakened. ("saline" was dropped from this set at the
    /// 2026-08-09 owner sign-off when the copy was softened from "saline-bench" to "experimental and
    /// demonstration use"; the NO-GO-for-real-insulin disposition is carried by the remaining terms.)
    static let requiredKeywords = ["not a medical device", "not fda-cleared", "demonstration", "real insulin"]
}
