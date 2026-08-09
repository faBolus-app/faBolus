import Foundation

/// §2.1(4) B1(e): copy for the point-of-editing THERAPY guidance + the first-use "this affects automated
/// delivery" acknowledgment. Pure and pump-neutral so the wording lives in one place and is testable; the
/// ack persistence is a single timestamp in `AppSettings` (durable, per-install), and it NEVER gates a
/// write — it is an acknowledgment shown once, not a lock (not a `DenialReason`, not the every-time
/// `UnverifiedFeatureGate`). Sibling of `ClinicianTierAck` (S8), which covers clinical ownership; this
/// covers the distinct fact that these values drive AUTOMATED delivery, not only manual boluses.
///
/// DRAFT copy — §13 clinical review gates it before any `experimental` distribution.
public enum TherapyEditAck {
    /// First-use disclosure: editing basal / carb-ratio / ISF / target changes AUTOMATED insulin delivery
    /// (the Control-IQ closed loop runs on these continuously), not just the boluses entered by hand — so a
    /// change here affects insulin around the clock. Non-blocking; shown once at the first therapy edit.
    public static let firstUseDisclosure = """
    Basal rates, carb ratios, correction factors, and targets don't only affect the boluses you enter by \
    hand. On a pump running automated insulin delivery (Control-IQ), these values continuously drive its \
    automatic basal and correction adjustments — so a change here can affect your insulin around the \
    clock, not just your next bolus. Change with care and confirm with your care team. This is not \
    medical advice.
    """

    /// Point-of-editing titration guidance: one parameter at a time, evaluate over ≥7 days, small (10–20%)
    /// steps. Shown passively in the segment editor while editing.
    public static let titrationGuidance = """
    Adjust one setting at a time, give it at least 7 days before judging the effect, and change in small \
    steps (about 10–20%). Changing several settings at once, or by a lot, makes it hard to tell what \
    actually helped.
    """
}
