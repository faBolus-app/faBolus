import Foundation

/// P14 S10 (§2.1(5)): TDD-relative therapy-edit SANITY bounds that **confirm, never block**.
///
/// Deliberately and strictly separate from `Interlocks` (the absolute HARD caps, e.g. the owner-locked
/// 25 U max-bolus ceiling): those clamp a value and can never be overridden; these only surface a
/// confirmation the user can always accept. §2.1(5)'s point is that today's therapy-edit bounds are
/// *only* absolute hard clamps, while the pump's own total daily insulin (TDD) is read into the snapshot
/// (`controlIQTotalDailyInsulin`) but never used as a bound. This introduces that use.
///
/// Each threshold here is a STARTING-POINT default with **no evidence base** — the same honesty the
/// SG / DS1 clinician defaults carry. It prompts a second look at an unusually large edit relative to
/// the user's own insulin use; it is not a clinical limit. A `nil` result means "no confirmation
/// needed", which INCLUDES the TDD-unknown case: a relative bound can't be computed without TDD, and
/// this is a sanity layer, not a safety gate — the hard cap (`Interlocks.clampMaxBolusLimit`) applies
/// regardless of what this returns.
public enum TherapyConfirmations {
    /// Fraction of TDD above which a max-bolus LIMIT edit warrants confirmation. A single-bolus ceiling
    /// above roughly half a day's insulin is unusual enough to re-confirm. Starting point, no evidence base.
    public static let maxBolusLimitTddFraction = 0.5

    /// A confirmation prompt for a proposed max-bolus **limit** that is large relative to the pump's TDD,
    /// or `nil` when it is within the sanity bound / TDD is unknown. Does NOT clamp — pair it with
    /// `Interlocks.clampMaxBolusLimit`, which still enforces the absolute 25 U hard cap independently.
    public static func maxBolusLimitConfirm(proposedUnits: Double, totalDailyInsulinUnits: Int) -> String? {
        guard totalDailyInsulinUnits > 0 else { return nil }
        let threshold = Double(totalDailyInsulinUnits) * maxBolusLimitTddFraction
        guard proposedUnits > threshold else { return nil }
        // `formatUnits` already appends " U" — do not double it.
        return "\(formatUnits(proposedUnits, fractionDigits: 1)) is a large max bolus for your total daily insulin of \(totalDailyInsulinUnits) U. Set it anyway?"
    }
}
