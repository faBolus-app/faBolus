import Testing
import Foundation
@testable import faBolus

/// Phase 5 tracer (05-01-PLAN.md, Task 3) — the PURE `decideAction(enabled:hasRunningActivity:
/// runningIsStaleOrEnded:)` branch (SC-4's re-arm decision map). `decideAction` was extracted in
/// Task 2 as part of building a working `update(from:)` (the manager needed the decision logic to
/// do anything at all); this suite is its dedicated, exhaustive coverage — no ActivityKit
/// request/update/end call is made here (device/simulator-only, 05-RESEARCH.md § Environment
/// Availability). 05-04 extends this suite for the composed `liveActivityEnabled &&
/// areActivitiesEnabled` gate (D-15) — in this tracer `enabled` == `areActivitiesEnabled` alone.
struct LiveActivityManagerTests {

    /// No activity running + a new snapshot ⇒ request a new one.
    @Test func noRunningActivityStarts() {
        let action = GlucoseLiveActivityManager.decideAction(
            enabled: true, hasRunningActivity: false, runningIsStaleOrEnded: false)
        #expect(action == .start)
    }

    /// One running + fresh ⇒ update it, never a second request.
    @Test func runningFreshActivityUpdates() {
        let action = GlucoseLiveActivityManager.decideAction(
            enabled: true, hasRunningActivity: true, runningIsStaleOrEnded: false)
        #expect(action == .update)
    }

    /// D-05 re-arm: a running activity in `.ended`/`.dismissed`/`.stale` ⇒ re-arm (request fresh)
    /// on the next reading, not a plain update.
    @Test func runningStaleOrEndedActivityReArms() {
        let action = GlucoseLiveActivityManager.decideAction(
            enabled: true, hasRunningActivity: true, runningIsStaleOrEnded: true)
        #expect(action == .start)
    }

    /// The opt-in/authorization gate: disabled + something running ⇒ end it; disabled + nothing
    /// running ⇒ no-op.
    @Test func disabledEndsARunningActivityAndIsANoOpOtherwise() {
        #expect(GlucoseLiveActivityManager.decideAction(
            enabled: false, hasRunningActivity: true, runningIsStaleOrEnded: false) == .end)
        #expect(GlucoseLiveActivityManager.decideAction(
            enabled: false, hasRunningActivity: false, runningIsStaleOrEnded: false) == .none)
        // The stale/ended flag is irrelevant once disabled — always .end when something is running.
        #expect(GlucoseLiveActivityManager.decideAction(
            enabled: false, hasRunningActivity: true, runningIsStaleOrEnded: true) == .end)
    }
}
