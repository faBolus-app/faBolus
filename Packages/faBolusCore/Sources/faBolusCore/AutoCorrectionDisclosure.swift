import Foundation

/// **S1 + O3 — pure disclosure of the pump controller's *documented* automatic-correction behavior.**
///
/// Phase 23 (23-01, D-09): the two display entry points this type once exposed — the **S1** lockout-caution
/// disclosure ("bolusing now pauses automatic correction") and the **O3** ambient "automatic correction is
/// active" indicator — were REMOVED (owner-directed phone/Garmin display-copy declutter). This type SLIMS
/// to its surviving fraction primitive below, which documents the still-frozen `lockoutUntilEpochSec` wire
/// contract (D-01) and is consumed by wire-fixture/test code only.
///
/// **This is a DISCLOSURE fact, not therapy — and it NEVER affects delivery.** Nothing here blocks,
/// disables, clamps, delays, or resizes a dose; the deliver button is unchanged. The surviving function only
/// ever returns a *time fraction* or `nil`. It reads the controller descriptor (P13c "controller as data")
/// so the value is derived from `ControllerDescriptor`'s own lockout number — never a hardcoded clinical
/// constant (C10, §2.4).
public enum AutoCorrectionDisclosure {
    /// **T1-5** — the 60-min auto-correction lockout's elapsed-time FRACTION, or `nil` when there is no
    /// active lockout to show. Sourced (c) Tandem verbatim: the automatic correction is blocked for
    /// `descriptor.automaticCorrection.blockedByRecentBolusMinutes` minutes after ANY bolus (manual or
    /// automatic) — a bolus-agnostic, documented pump behavior, not a faBolus-invented cooldown.
    ///
    /// **This is a fraction, NEVER a dose/units value (D-06 guardrail #1).** The return type is `Double?` in
    /// `[0.0, 1.0]` — a TIME FILL of `elapsed / windowMinutes`, clamped, that fills UP toward `1.0` as the
    /// lockout expires and automatic correction becomes available again. It is not a percent-of-ceiling and
    /// not a draining battery; a consuming bar should grow, not shrink, as time passes.
    ///
    /// Returns `nil` when the controller can't auto-correct (`descriptor.automaticCorrection.enabled ==
    /// false`, e.g. `.noController`) or is turned off at runtime (`controllerEnabled == false`), PLUS `nil`
    /// when `lockoutStartDate` is absent (no lockout known) or the window has already elapsed (`elapsed >=
    /// windowMinutes` — lockout expired, so there is no active lockout left to disclose; D-06 guardrail #5
    /// fail-closed). The window length is read from the descriptor — never restated as a literal here.
    public static func lockoutRemainingFraction(
        descriptor: ControllerDescriptor,
        controllerEnabled: Bool,
        lockoutStartDate: Date?,
        now: Date
    ) -> Double? {
        guard descriptor.automaticCorrection.enabled,
            controllerEnabled,
            let windowMinutes = descriptor.automaticCorrection.blockedByRecentBolusMinutes,
            let startDate = lockoutStartDate
        else { return nil }
        let elapsedMinutes = now.timeIntervalSince(startDate) / 60
        guard elapsedMinutes < Double(windowMinutes) else { return nil }  // expired: no active lockout
        let fraction = elapsedMinutes / Double(windowMinutes)
        return min(max(fraction, 0.0), 1.0)
    }
}
