import Testing
import Foundation
@testable import faBolus

/// CX-F-07 (addresses codex HIGH — "jetsam/crash distinction is not implementable as described"):
/// `GlucoseSourceRecoveryPolicy.decide` replaces the old permanent-until-reselect crash guard. It never
/// asserts a termination CAUSE — only whether the previous run left its clean-shutdown marker
/// (`wasClean`) — and applies a BOUNDED policy: a single unclean start never disables failover; only
/// `maxUncleanStartsBeforeDisable` unclean starts within `uncleanStartWindow` do, and even that disable
/// auto-re-probes once `disableWindow` elapses. Pure (no `UserDefaults`, no clock read), so the
/// disable/re-probe boundary is a plain behavior test, not a grep for "jetsam"/"terminationReason".
@Suite struct GlucoseSourceRecoveryPolicyTests {
    private let base = Date(timeIntervalSince1970: 1_700_000_000)

    @Test func aSingleUncleanStartNeverDisablesFailover() {
        let (next, shouldStart) = GlucoseSourceRecoveryPolicy.decide(
            GlucoseSourceRecoveryState(), wasClean: false, now: base)
        #expect(
            shouldStart,
            "one unclean start (the overwhelmingly common jetsam/watchdog/OOM case) must never disable failover")
        #expect(next.uncleanStartCount == 1)
        #expect(next.disabledUntil == nil)
    }

    @Test func repeatedUncleanStartsWithinTheWindowDisableAfterTheThreshold() {
        var state = GlucoseSourceRecoveryState()
        var now = base
        var shouldStart = true
        for _ in 0..<(GlucoseSourceRecoveryPolicy.maxUncleanStartsBeforeDisable - 1) {
            (state, shouldStart) = GlucoseSourceRecoveryPolicy.decide(state, wasClean: false, now: now)
            #expect(shouldStart, "below the threshold, failover must stay enabled")
            now = now.addingTimeInterval(60)  // still well inside uncleanStartWindow
        }
        // The Nth unclean start within the window crosses the threshold.
        (state, shouldStart) = GlucoseSourceRecoveryPolicy.decide(state, wasClean: false, now: now)
        #expect(!shouldStart, "reaching the bounded threshold within the window must disable failover")
        #expect(state.disabledUntil != nil)
    }

    @Test func disableIsBoundedAndAutoReProbesOnceTheWindowElapses() {
        var state = GlucoseSourceRecoveryState()
        var now = base
        var shouldStart = true
        for _ in 0..<GlucoseSourceRecoveryPolicy.maxUncleanStartsBeforeDisable {
            (state, shouldStart) = GlucoseSourceRecoveryPolicy.decide(state, wasClean: false, now: now)
            now = now.addingTimeInterval(60)
        }
        #expect(!shouldStart)
        guard let disabledUntil = state.disabledUntil else {
            Issue.record("expected a disable window to be set")
            return
        }
        // Just before the window elapses: still disabled.
        (state, shouldStart) = GlucoseSourceRecoveryPolicy.decide(
            state, wasClean: false, now: disabledUntil.addingTimeInterval(-1))
        #expect(!shouldStart, "the disable must hold for its full bounded window")
        // Once the window elapses: AUTO re-probe — even a launch that is ITSELF unclean gets to try
        // again (only 1 of a fresh threshold), never permanently disabled.
        (state, shouldStart) = GlucoseSourceRecoveryPolicy.decide(
            state, wasClean: false, now: disabledUntil.addingTimeInterval(1))
        #expect(shouldStart, "the bounded window must auto-re-probe once it elapses")
        #expect(state.disabledUntil == nil)
        #expect(state.uncleanStartCount == 1, "the re-probe launch starts a genuinely fresh tally")
    }

    @Test func aCleanShutdownAlwaysResetsTheTally() {
        let state = GlucoseSourceRecoveryState(uncleanStartCount: 2, lastUncleanStartAt: base)
        let (next, shouldStart) = GlucoseSourceRecoveryPolicy.decide(
            state, wasClean: true, now: base.addingTimeInterval(10))
        #expect(shouldStart)
        #expect(next.uncleanStartCount == 0)
        #expect(next.lastUncleanStartAt == nil)
    }

    @Test func anUncleanStartOutsideTheWindowIsTreatedAsIsolatedNotALoop() {
        var state = GlucoseSourceRecoveryState()
        var shouldStart = true
        (state, shouldStart) = GlucoseSourceRecoveryPolicy.decide(state, wasClean: false, now: base)
        #expect(state.uncleanStartCount == 1)
        // A SECOND unclean start, but well OUTSIDE uncleanStartWindow — must not accumulate onto the
        // first (an isolated unclean exit weeks apart is not a crash loop).
        let farLater = base.addingTimeInterval(GlucoseSourceRecoveryPolicy.uncleanStartWindow + 3600)
        (state, shouldStart) = GlucoseSourceRecoveryPolicy.decide(state, wasClean: false, now: farLater)
        #expect(shouldStart)
        #expect(
            state.uncleanStartCount == 1,
            "an unclean start outside the window resets the tally rather than accumulating")
    }

    @Test func neverClaimsATerminationCauseInItsPersistedState() {
        // Behavior-level guard against re-introducing a "terminationReason"/"crashed" field: the state
        // this policy persists carries ONLY count/timestamp/disable-window bookkeeping.
        let mirror = Mirror(reflecting: GlucoseSourceRecoveryState())
        let labels = Set(mirror.children.compactMap(\.label))
        #expect(labels == ["uncleanStartCount", "lastUncleanStartAt", "disabledUntil"])
    }
}
