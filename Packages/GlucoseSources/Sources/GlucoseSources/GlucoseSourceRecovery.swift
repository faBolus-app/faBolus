import Foundation

/// Pure, persisted state for the bounded crash-loop recovery policy below. Codable so
/// `GlucoseSourceRegistry` can round-trip it through `UserDefaults` (JSON) across launches.
public struct GlucoseSourceRecoveryState: Equatable, Codable, Sendable {
    /// Consecutive unclean-start count observed within `GlucoseSourceRecoveryPolicy.uncleanStartWindow`.
    public var uncleanStartCount: Int
    public var lastUncleanStartAt: Date?
    /// Non-nil while failover is disabled; auto-re-probes once `now >= disabledUntil`.
    public var disabledUntil: Date?
    public init(uncleanStartCount: Int = 0, lastUncleanStartAt: Date? = nil, disabledUntil: Date? = nil) {
        self.uncleanStartCount = uncleanStartCount
        self.lastUncleanStartAt = lastUncleanStartAt
        self.disabledUntil = disabledUntil
    }
}

/// **Bounded crash-loop recovery — not a permanent-until-reselect crash guard.**
///
/// iOS cannot reliably tell a benign jetsam/watchdog/OOM background termination apart from a genuine
/// CGM-source crash, so this policy NEVER classifies a termination reason.
/// `GlucoseSourceRegistry.shouldStartSelected` tracks only whether the PREVIOUS run left its clean-shutdown marker (`wasClean` — set on an orderly teardown of
/// the CGM source, cleared at the start of every run; its ABSENCE at the next launch means "ended
/// without cleanup", cause UNKNOWN) and feeds that, plus the persisted `GlucoseSourceRecoveryState`,
/// through this PURE decision function — no `UserDefaults`, no clock read — so the disable/re-probe
/// boundary is unit-testable directly. A SINGLE unclean start (the overwhelmingly common real-world
/// case: the app was simply suspended, then jetsam'd, in the background) NEVER disables failover; only
/// `maxUncleanStartsBeforeDisable` unclean starts within `uncleanStartWindow` do, and even that disable
/// is itself BOUNDED (`disableWindow`) — it auto-re-probes once the window elapses rather than requiring
/// the user to manually re-select the source in Settings forever.
public enum GlucoseSourceRecoveryPolicy {
    /// §13-adjacent starting points — owner-vetoable, NOT clinical constants (mirrors
    /// `DisconnectEscalation`'s own disclaimer for its ladder timings).
    public static let maxUncleanStartsBeforeDisable = 3
    public static let uncleanStartWindow: TimeInterval = 60 * 60
    public static let disableWindow: TimeInterval = 60 * 60

    /// Called at launch, BEFORE starting the source. Returns the next persisted state AND whether the
    /// source should start THIS launch.
    public static func decide(_ state: GlucoseSourceRecoveryState, wasClean: Bool, now: Date = Date())
        -> (next: GlucoseSourceRecoveryState, shouldStart: Bool)
    {
        var s = state
        if let until = s.disabledUntil, now >= until {
            // The bounded disable window elapsed — auto re-probe: clear the disable AND the tally so the
            // source gets a genuinely fresh bounded window, not one poisoned by the run that tripped it.
            s.disabledUntil = nil
            s.uncleanStartCount = 0
            s.lastUncleanStartAt = nil
        }
        if wasClean {
            // A clean prior shutdown always resets the unclean-run tally — an intermittent, benign
            // termination (a user-initiated quit, a source reselect) must never accumulate toward the
            // disable threshold alongside genuinely-back-to-back crashes.
            s.uncleanStartCount = 0
            s.lastUncleanStartAt = nil
            return (s, s.disabledUntil == nil)
        }
        // Unclean prior run (absence of the clean-shutdown marker) — cause UNKNOWN (jetsam / watchdog /
        // OOM / crash are all indistinguishable here), so this ONLY ever increments a bounded, windowed
        // tally; it never itself asserts that a crash occurred.
        if let last = s.lastUncleanStartAt, now.timeIntervalSince(last) > uncleanStartWindow {
            s.uncleanStartCount = 0  // an isolated unclean exit outside the window, not a loop
        }
        s.uncleanStartCount += 1
        s.lastUncleanStartAt = now
        if s.uncleanStartCount >= maxUncleanStartsBeforeDisable, s.disabledUntil == nil {
            s.disabledUntil = now.addingTimeInterval(disableWindow)
        }
        return (s, s.disabledUntil == nil)
    }
}
