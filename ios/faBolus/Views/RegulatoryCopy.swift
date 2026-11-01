import Foundation

// The regulatory-status copy, one source for the first-run screen and About. The owner approves the
// wording; RegulatoryCopyTests checks each string keeps the required terms, so changing it needs the
// owner's approval again.

/// The app's regulatory-status copy. Two surfaces, one disposition.
enum RegulatoryCopy {
    /// First-run footnote (`ConnectPumpOnboardingView`). Concise and non-alarming: experimental, not a
    /// medical device, not FDA-cleared, check every value.
    static let firstRun =
        "faBolus is experimental, in-development software — not a medical device and not FDA-cleared. It is for experimental and demonstration use. Not medical advice — check every value against your pump and your clinician."

    /// About footer (Settings → About), so the same status is findable after onboarding.
    /// Keeps the trademark and non-affiliation lines.
    static let about =
        "faBolus™ is an independent, open-source project in development for experimental use. It is not a medical device and is not FDA-cleared; it is for experimental and demonstration use. Not affiliated with Tandem Diabetes Care or Dexcom. faBolus™ is a trademark of Zev Granowitz."

    /// Terms a guard test requires in both strings above (case-insensitively), so the wording can be
    /// strengthened but not silently weakened.
    static let requiredKeywords = ["not a medical device", "not fda-cleared", "demonstration"]
}
