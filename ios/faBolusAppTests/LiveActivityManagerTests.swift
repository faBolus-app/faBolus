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

    // MARK: 05-04 (D-15) — the composed opt-in gate

    /// `gateEnabled` is true iff BOTH the app-level opt-in AND the system authorization are true —
    /// the property the 05-01 tracer deliberately deferred to this plan.
    @Test func gateEnabledIsTrueOnlyWhenBothOptInAndAuthorizedAreTrue() {
        #expect(GlucoseLiveActivityManager.gateEnabled(optIn: true, authorized: true) == true)
        #expect(GlucoseLiveActivityManager.gateEnabled(optIn: true, authorized: false) == false)
        #expect(GlucoseLiveActivityManager.gateEnabled(optIn: false, authorized: true) == false)
        #expect(GlucoseLiveActivityManager.gateEnabled(optIn: false, authorized: false) == false)
    }

    /// The opt-in being OFF resolves through `decideAction` to `.end` when something is running
    /// (D-15 — flipping the opt-in off must tear down any existing Activity) and `.none` when nothing
    /// is running, regardless of system authorization.
    @Test func optInOffResolvesThroughDecideActionToEndOrNone() {
        let gated = GlucoseLiveActivityManager.gateEnabled(optIn: false, authorized: true)
        #expect(gated == false)
        #expect(GlucoseLiveActivityManager.decideAction(
            enabled: gated, hasRunningActivity: true, runningIsStaleOrEnded: false) == .end)
        #expect(GlucoseLiveActivityManager.decideAction(
            enabled: gated, hasRunningActivity: false, runningIsStaleOrEnded: false) == .none)
    }

    /// The opt-in being ON but the system authorization OFF behaves identically — the composed gate
    /// collapses both reasons a Live Activity can't run into the SAME `decideAction` branch.
    @Test func systemAuthorizationOffResolvesThroughDecideActionToEndOrNone() {
        let gated = GlucoseLiveActivityManager.gateEnabled(optIn: true, authorized: false)
        #expect(gated == false)
        #expect(GlucoseLiveActivityManager.decideAction(
            enabled: gated, hasRunningActivity: true, runningIsStaleOrEnded: false) == .end)
    }
}
