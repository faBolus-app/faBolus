import Foundation

/// Pure disclosure of the pump controller's *documented* automatic-correction behavior.
///
/// Phone/Garmin display entry points (lockout-caution copy and the ambient "automatic correction is
/// active" indicator) were removed. This type keeps the fraction primitive that documents the frozen
/// `lockoutUntilEpochSec` wire contract and is consumed by wire-fixture/test code.
///
/// This is a disclosure fact, not therapy — and it NEVER affects delivery. Nothing here blocks,
/// disables, clamps, delays, or resizes a dose. The surviving function only ever returns a *time
/// fraction* or `nil`. It reads `ControllerDescriptor`'s own lockout number — never a hardcoded
/// clinical constant.
public enum AutoCorrectionDisclosure {
    /// The auto-correction lockout's elapsed-time FRACTION, or `nil` when there is no active lockout
    /// to show. The automatic correction is blocked for
    /// `descriptor.automaticCorrection.blockedByRecentBolusMinutes` minutes after ANY bolus (manual or
    /// automatic) — documented pump behavior, not a faBolus-invented cooldown.
    ///
    /// This is a fraction, NEVER a dose/units value. The return type is `Double?` in `[0.0, 1.0]` — a
    /// time fill of `elapsed / windowMinutes`, clamped, that fills UP toward `1.0` as the lockout
    /// expires. It is not a percent-of-ceiling and not a draining battery; a consuming bar should
    /// grow, not shrink, as time passes.
    ///
    /// Returns `nil` when the controller can't auto-correct (`descriptor.automaticCorrection.enabled
    /// == false`) or is turned off at runtime (`controllerEnabled == false`), PLUS `nil` when
    /// `lockoutStartDate` is absent or the window has already elapsed (`elapsed >= windowMinutes` —
    /// fail-closed: no active lockout left to disclose). The window length is read from the
    /// descriptor — never restated as a literal here.
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
