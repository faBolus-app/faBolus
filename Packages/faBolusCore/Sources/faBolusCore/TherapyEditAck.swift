import Foundation

/// §2.1(4) B1(e): copy for the point-of-editing THERAPY guidance + the first-use "this affects automated
/// delivery" acknowledgment. Pure and pump-neutral so the wording lives in one place and is testable; the
/// ack persistence is a single timestamp in `AppSettings` (durable, per-install), and it NEVER gates a
/// write — it is an acknowledgment shown once, not a lock (not a `DenialReason`, not the every-time
/// `UnverifiedFeatureGate`). Sibling of `ClinicianTierAck` (S8), which covers clinical ownership; this
/// covers the distinct fact that these values drive AUTOMATED delivery, not only manual boluses.
///
/// §13 STATUS: RE-BLESSED 2026-08-23 (owner Zev Granowitz, F5 approver of record) after an
/// owner-accepted independent AI-panel clinical-copy review (two models, converged). This supersedes
/// the prior 2026-08-09 verbatim sign-off: B1a now attributes around-the-clock automation to basal +
/// correction factor only (carb ratio/target size only manual boluses), and B1b adds an acute-danger
/// carve-out. The owner is the §13 approver of record and this satisfies the §13 copy-distribution gate
/// for these strings. Any further wording change re-opens the sign-off.
public enum TherapyEditAck {
    /// First-use disclosure: on a Control-IQ pump the BASAL rates + CORRECTION FACTOR drive AUTOMATED
    /// insulin delivery around the clock (carb ratio + target size only the boluses entered by hand) — not
    /// just the next manual bolus. Non-blocking; shown once at the first therapy edit. §13-cleared 2026-08-23.
    public static let firstUseDisclosure = """
        These settings don't only affect the boluses you enter by hand. On a pump running automated \
        insulin delivery (Control-IQ), your basal rates and correction factor continuously drive its \
        automatic basal and correction adjustments — so changing either can affect your insulin around \
        the clock, not just your next bolus. Carb ratios and targets size the doses you enter yourself. \
        Change any of these with care and confirm with your care team. This is not medical advice.
        """

    /// Point-of-editing titration guidance: one parameter at a time, evaluate over ≥7 days, small (10–20%)
    /// steps — with an acute-danger carve-out (repeated lows / severe highs / ketones need prompt action,
    /// don't wait). Shown passively in the segment editor while editing. §13-cleared 2026-08-23.
    public static let titrationGuidance = """
        Adjust one setting at a time, give it at least 7 days before judging the effect, and change in \
        small steps (about 10–20%). Changing several settings at once, or by a lot, makes it hard to \
        tell what actually helped. The 7 days is only for judging whether a change helped — repeated \
        lows, severe or persistent highs, or any ketones need prompt action now: treat them and \
        contact your care team right away.
        """
}
