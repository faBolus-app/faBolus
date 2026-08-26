import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// P12 (§5.4) — the host must push status to the remotes on every NEW glucose SAMPLE, not only when the
/// mg/dL VALUE changes. A CGM commonly reports the same number twice in a row; the old value-only
/// comparison let a fresh reading silently NOT reach the remotes, so their displayed age stalled.
///
/// Phase 16 GO-1 Step 2 (REMED-16): `shouldPushStatus` relocated from `AppModel` to
/// `FailoverBadgePresenter` (a pure, verbatim move — same signature, same body) — these assertions
/// are unchanged, only the callee's namespace moved.
struct StatusPushCadenceTests {
    private let t0 = Date(timeIntervalSince1970: 1_000_000)

    /// The §5.4 fix: same mg/dL but a NEWER source timestamp = a new sample = push.
    @Test func newSampleAtTheSameValuePushes() {
        #expect(FailoverBadgePresenter.shouldPushStatus(
            newGlucose: 120, newGlucoseDate: t0.addingTimeInterval(300),
            lastGlucose: 120, lastGlucoseDate: t0,
            newConnection: .connected, lastConnection: .connected,
            secondsSinceLastPush: 1))
    }

    /// Truly identical sample (same value AND timestamp), connection unchanged, inside the throttle → no push.
    @Test func identicalSampleWithinThrottleDoesNotPush() {
        #expect(!FailoverBadgePresenter.shouldPushStatus(
            newGlucose: 120, newGlucoseDate: t0,
            lastGlucose: 120, lastGlucoseDate: t0,
            newConnection: .connected, lastConnection: .connected,
            secondsSinceLastPush: 1))
    }

    @Test func throttleWindowStillForcesAPush() {
        #expect(FailoverBadgePresenter.shouldPushStatus(
            newGlucose: 120, newGlucoseDate: t0,
            lastGlucose: 120, lastGlucoseDate: t0,
            newConnection: .connected, lastConnection: .connected,
            secondsSinceLastPush: 16))
    }

    @Test func connectionChangeOrBolusingAlwaysPushes() {
        #expect(FailoverBadgePresenter.shouldPushStatus(
            newGlucose: 120, newGlucoseDate: t0, lastGlucose: 120, lastGlucoseDate: t0,
            newConnection: .disconnected, lastConnection: .connected, secondsSinceLastPush: 1))
        #expect(FailoverBadgePresenter.shouldPushStatus(
            newGlucose: 120, newGlucoseDate: t0, lastGlucose: 120, lastGlucoseDate: t0,
            newConnection: .bolusing, lastConnection: .bolusing, secondsSinceLastPush: 1))
    }
}
