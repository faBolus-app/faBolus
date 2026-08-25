import Foundation

/// **P16 — S7: the pump-disconnect escalation ladder (pure schedule).**
///
/// The P9 broker already posts ONE immediate "Pump disconnected" notification on the live→down edge
/// (`AppModel.refresh` → `postSafety(.pumpDisconnect …)`). That is fine for a user who is looking at
/// the phone, but a user who has **walked away** (app backgrounded/suspended) gets one banner and then
/// silence — even though the pump is still unreachable from faBolus and they must fall back to the
/// pump's own controls. S7 adds a small, **finite** ladder of *delayed re-notifications* with
/// intensified copy that keep telling them so, each carrying the explicit instruction to use the pump's
/// own buttons.
///
/// This type is the **single source of truth for the schedule**: which escalation steps exist, at what
/// elapsed time past the disconnect, and with what copy/severity. It is a pure value (no clock, no OS,
/// no `UNUserNotificationCenter`) so the ladder is unit-testable and cannot drift between the app wiring
/// and its tests. The app layer (`NotificationCoordinator`) turns each `Step` into an OS-scheduled
/// `UNNotificationRequest` (a `UNTimeIntervalNotificationTrigger`) so it fires even while the app is
/// suspended, in the never-suppressible `.pumpDisconnect` family, and cancels the pending ones the
/// moment the pump reconnects.
///
/// **Notification-only.** Nothing here blocks, delays, or affects a dose or any pump command; it only
/// informs. The steps are `.pumpDisconnect`, a never-suppressible P9 safety category — S7 is on,
/// Simple-mode, and NOT user-disableable.
public enum DisconnectEscalation {

    /// One delayed re-notification: fire `afterSeconds` past the disconnect, with this copy. `id` is a
    /// stable, per-step identifier used BOTH as the scheduled `UNNotificationRequest` identifier and as
    /// the broker `dedupeKey` — distinct ids mean the broker never coalesces one escalation step onto
    /// another (or onto the immediate T0 banner), so each step is a separate delivery/cancellation unit.
    public struct Step: Equatable, Sendable {
        public let id: String
        public let afterSeconds: TimeInterval
        public let title: String
        /// Copy for this step. Every step's body contains the explicit "use the pump's own buttons"
        /// instruction (pinned by tests) — the whole point of the ladder is to redirect a walked-away
        /// user to the pump's own controls.
        public let body: String
        public init(id: String, afterSeconds: TimeInterval, title: String, body: String) {
            self.id = id; self.afterSeconds = afterSeconds; self.title = title; self.body = body
        }
    }

    /// The instruction every escalation body carries: what the user should actually DO while faBolus
    /// can't reach the pump. Factored out so all steps (and the tests) share one string.
    public static let pumpButtonsInstruction =
        "Use the pump's own buttons to bolus or check status until it reconnects."

    /// The escalation ladder, ordered by ascending `afterSeconds`. **§13-adjacent timing defaults —
    /// owner-vetoable starting points, NOT clinical constants.** Two steps beyond the immediate T0
    /// banner: a "prolonged" nudge at 15 minutes and an "urgent" one at 30 minutes. The ladder is
    /// deliberately CAPPED (finite, two entries) — a safety re-notification that nagged forever would
    /// train the user to ignore it, which is itself a hazard. `AppModel`'s existing immediate post is
    /// T0 and is NOT in this list.
    public static let steps: [Step] = [
        Step(id: "safety.pumpDisconnect.escalation.15m",
             afterSeconds: 15 * 60,
             title: "Pump still disconnected",
             body: "faBolus still can't reach your pump (15 min). \(pumpButtonsInstruction)"),
        Step(id: "safety.pumpDisconnect.escalation.30m",
             afterSeconds: 30 * 60,
             title: "Pump disconnected — act on the pump",
             body: "faBolus has been unable to reach your pump for 30 minutes. \(pumpButtonsInstruction)"),
    ]

    /// Every scheduled-escalation identifier, for cancellation on reconnect (paired with the immediate
    /// T0 key in `AppModel`'s withdraw path).
    public static var stepIds: [String] { steps.map(\.id) }
}

/// **CX-F-02 — the pre-armed CGM-staleness background watchdog.**
///
/// Companion to `DisconnectEscalation` above, reusing the SAME `UNTimeIntervalNotificationTrigger` OS
/// mechanism (13-PATTERNS.md Pattern E) for a different purpose: instead of a fixed post-disconnect
/// schedule, `NotificationCoordinator` re-arms a SINGLE delayed notification carrying this copy every
/// time a fresh glucose datum lands (`StalenessWatchdogEdge`, `NotificationCoordinator.swift`), so it
/// fires `GlucoseFreshness.staleAfter` seconds past the LAST known-fresh reading unless a fresher one
/// re-arms it first — this is what catches the case the suspended 15s poll/20s arbiter timer otherwise
/// misses: a background suspension with no wake event before the staleness window elapses still gets
/// the pre-armed OS notification, because it was scheduled *before* the process ever stopped running.
/// Cancelled once the real staleness edge fires for real (`SafetyEdge.freshness` → `.cgmDataLoss`), so a
/// user who is actually looking at the phone never sees a redundant watchdog after the real alert.
public enum StalenessWatchdog {
    public static let dedupeKey = "safety.cgmStalenessWatchdog"
    public static let title = "CGM data may be stale"
    public static let body = "faBolus hasn't confirmed a fresh CGM reading recently. Check your sensor/transmitter, or open the app."
}
