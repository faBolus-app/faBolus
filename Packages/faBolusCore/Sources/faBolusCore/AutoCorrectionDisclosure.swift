import Foundation

/// **S1 + O3 — pure disclosure of the pump controller's *documented* automatic-correction behavior.**
///
/// Two factual, mechanism-gated strings the bolus screen renders unconditionally when applicable:
///   - **S1** (`lockoutMessage`): when the user is about to bolus at high/rising glucose, disclose that a
///     manual bolus now pauses the controller's automatic correction for the controller's own documented
///     lockout window (`AutomaticCorrection.blockedByRecentBolusMinutes`).
///   - **O3** (`ambientIndicator`): a persistent, non-alarming line stating the controller's automatic
///     correction is active.
///
/// **These are DISCLOSURE facts, not therapy — and they NEVER affect delivery.** Nothing here blocks,
/// disables, clamps, delays, or resizes a dose; the deliver button is unchanged. Both functions only ever
/// return a *string to show* or `nil`. They read the controller descriptor (P13c "controller as data") so
/// the copy is derived from `ControllerDescriptor.displayName` and the descriptor's own lockout number —
/// never a hardcoded brand or clinical constant (C10, §2.4).
///
/// **C8 / C3 compliance (adversarially verified):** the high/rising trigger reads the pump's OWN reported
/// trend arrow (`GlucoseTrend`) — it does NOT compute a glucose rate, synthesize an arrow, or predict
/// glucose. The rate is never derived and never displayed. faBolus stays a manual remote-bolus + status
/// viewer that models neither the controller's state nor future glucose (C3); this discloses what the
/// *pump's* controller documents it will do, which is a fact about the device, not advice or a prediction.
///
/// **§13 — the two glucose thresholds below are clinical-disclosure parameters from the handoff's S1 rule
/// and are subject to the clinical-review distribution gate.** The lockout window itself is NOT restated
/// here: it comes from the §13-gated `ControllerDescriptor` value so there is one source of truth.
public enum AutoCorrectionDisclosure {
    // §13 clinical-disclosure thresholds — from the handoff S1 rule (subject to the clinical-review gate).
    // Disclose the auto-correction lockout when the user is about to bolus at high, or rising-and-elevated,
    // glucose — the situations where losing the next automatic correction to the lockout most matters.
    /// Always disclose the lockout at/above this glucose (mg/dL), regardless of trend.
    static let discloseAtOrAbove = 180
    /// Disclose the lockout at/above this glucose (mg/dL) ONLY when the pump's trend arrow is rising.
    static let discloseRisingAtOrAbove = 150

    /// The pump's own rising-ish trend arrows (C8: read, never synthesized). Elevated-and-rising uses these.
    private static let risingTrends: Set<GlucoseTrend> = [.rising, .up, .upUp]

    /// **S1** — the high-glucose auto-correction lockout disclosure text, or `nil` when it should not show.
    ///
    /// Returns `nil` when: the controller can't auto-correct (`descriptor.automaticCorrection.enabled ==
    /// false`, e.g. `.noController`), the controller is turned off at runtime (`controllerEnabled == false`),
    /// glucose is absent, the documented lockout window is unknown, or the high/rising trigger isn't met.
    ///
    /// Trigger: `glucose >= discloseAtOrAbove`, OR `glucose >= discloseRisingAtOrAbove` AND the pump's own
    /// trend arrow is rising. Mechanism-gated: the copy is built from `descriptor.displayName` and the
    /// descriptor's own lockout minutes — no brand or number is hardcoded. **NEVER affects delivery.**
    public static func lockoutMessage(descriptor: ControllerDescriptor,
                                      controllerEnabled: Bool,
                                      glucoseMgdl: Int?,
                                      trend: GlucoseTrend?) -> String? {
        guard descriptor.automaticCorrection.enabled,
              controllerEnabled,
              let g = glucoseMgdl,
              let lockoutMinutes = descriptor.automaticCorrection.blockedByRecentBolusMinutes
        else { return nil }
        let rising = trend.map(risingTrends.contains) ?? false
        guard g >= discloseAtOrAbove || (g >= discloseRisingAtOrAbove && rising) else { return nil }
        return "Bolusing now pauses \(descriptor.displayName)'s automatic correction for about \(lockoutMinutes) min."
    }

    /// **O3** — the persistent, ambient "automatic correction is active" indicator text, or `nil` when the
    /// controller can't auto-correct (`.noController` / not enabled) or is turned off at runtime
    /// (`controllerEnabled == false`). Non-alarming and factual; brand comes from `descriptor.displayName`.
    /// **NEVER affects delivery.**
    public static func ambientIndicator(descriptor: ControllerDescriptor,
                                        controllerEnabled: Bool) -> String? {
        guard descriptor.automaticCorrection.enabled, controllerEnabled else { return nil }
        return "\(descriptor.displayName) automatic correction is active."
    }
}
