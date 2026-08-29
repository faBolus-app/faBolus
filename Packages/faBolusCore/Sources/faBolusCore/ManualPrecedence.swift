import Foundation

/// P16 S3 — manual precedence for scheduled activity/sleep mode automation.
///
/// Scheduled Sleep/Exercise automation (Apple Shortcuts → `ModeAutomation.request`) should PROMPT rather
/// than silently apply when the user just did something by hand. This is the pure, clock-injected decision
/// the app layer consumes; it never applies a mode, changes a dose, or blocks a user action — the ONLY
/// thing it can do is answer "should the automation defer (queue + notify) instead of applying now?".
///
/// Conservative by construction: a `nil` timestamp (no known manual action), one older than the window, or
/// a future timestamp (clock skew) all say "do not defer" → the automation behaves exactly as before.
public enum ManualPrecedence {
    /// Default look-back window: a manual therapy action inside the last 60 minutes takes precedence over a
    /// scheduled mode switch. (Handoff S3, §13-adjacent.)
    public static let defaultWindowSeconds: TimeInterval = 3600  // 60 min

    /// True when a manual therapy action happened within `window` before `now` → scheduled mode
    /// automation should DEFER (queue + notify), not silently apply. Clock-injected for tests.
    /// A nil timestamp, or one older than the window, or a future timestamp → do not defer.
    public static func shouldDeferAutomation(
        lastManualActionAt: Date?, now: Date,
        window: TimeInterval = defaultWindowSeconds
    ) -> Bool {
        guard let t = lastManualActionAt else { return false }
        let dt = now.timeIntervalSince(t)
        return dt >= 0 && dt < window
    }
}
