import Foundation

// P16 F5 (N20) — regulatory-status copy, single source of truth.
//
// §13 NOTICE: this wording is a STRONG DRAFT and is experimental-distribution surface. The EXACT
// wording must pass owner + §13 clinical review (endocrinologist / CDCES) before any `experimental`
// build is distributed to a person other than the developer (BRANCHES.md §13). It is centralised here
// so the first-run overlay (ModeOnboardingView) and the About section (AboutSettingsView) state the
// SAME thing, and a future copy edit can't silently drop the key regulatory terms — RegulatoryCopyTests
// asserts each string still carries `requiredKeywords`. This is copy only: no control flow, gating,
// dose logic, or delivery behaviour depends on these strings.

/// The app's regulatory-status copy. Two surfaces, one disposition.
enum RegulatoryCopy {
    /// First-run overlay footnote (`ModeOnboardingView`). Concise and non-alarming; keeps the
    /// experimental / not-FDA-cleared / check-every-value intent and adds the not-a-medical-device,
    /// saline-bench / demonstration-only, no-real-insulin framing.
    static let firstRun = "faBolus is experimental, in-development software — not a medical device and not FDA-cleared. It is for saline-bench and demonstration use only, and must not be used to deliver real insulin or make real therapy decisions. Not medical advice — check every value against your pump and your clinician."

    /// About & help footer (`AboutSettingsView`), so the same status is findable after onboarding.
    /// Keeps the trademark and non-affiliation lines.
    static let about = "faBolus™ is an independent, open-source project in development for experimental use. It is not a medical device and is not FDA-cleared; it is for saline-bench and demonstration use only, and must not be used to deliver real insulin or make real therapy decisions. Not affiliated with Tandem Diabetes Care or Dexcom. faBolus™ is a trademark of Tia Geri."

    /// Terms a guard test requires remain present (case-insensitively) in BOTH strings above, so the
    /// wording can be strengthened but not silently weakened.
    static let requiredKeywords = ["not a medical device", "not fda-cleared", "saline", "demonstration", "real insulin"]
}
