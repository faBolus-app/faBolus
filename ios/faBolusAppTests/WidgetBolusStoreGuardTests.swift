import Testing
import Foundation
@testable import faBolus

/// Guards two Quick-Bolus widget hardening fixes on the `WidgetBolusStore` App-Group surface:
///
/// **WR-05 / VA-28 (commit 1682298)** — cancel authentication. A `widgetBolusCancel` Darwin post is
/// system-wide and unauthenticated, so the receiver now requires a single-use, `confirmTTL`-bounded
/// App-Group token the legitimate cancel intent writes before posting. A co-resident app cannot write the
/// App-Group container, so a bare/replayed post finds no token and is dropped.
///
/// **WR-04 / VA-26 (commit 9b6fbba)** — `takePending()` still hard-drops a completed request older than
/// `pendingTTL` (120 s), so a stale widget confirm can't be auto-consumed. (The prompt-vs-restage decision
/// keyed off `promptTTL` lives in `WidgetBolusReceiver` and isn't unit-testable here.)
///
/// `.serialized` because every test mutates the one shared App-Group `UserDefaults(suiteName:)`; each test
/// also clears ONLY its own keys (never `removePersistentDomain`, which would clobber other parallel suites
/// that share the container).
@Suite(.serialized)
struct WidgetBolusStoreGuardTests {

    private static var suite: UserDefaults { UserDefaults(suiteName: WidgetStore.appGroup)! }
    private static func clearKeys() {
        let d = suite
        for k in ["wbPending", "wbCancelReq", "wbCancelAt"] { d.removeObject(forKey: k) }
    }

    // MARK: - WR-05 / VA-28: cancel-intent token

    /// A bare Darwin post (nothing written) is rejected — the core anti-nuisance property.
    @Test func takeCancelIntentIsFalseWithNoToken() {
        Self.clearKeys()
        defer { Self.clearKeys() }
        #expect(WidgetBolusStore.takeCancelIntent() == false)
    }

    /// The legit cancel writes a token, so the receiver's first read succeeds — and it is single-use, so an
    /// immediate replay of the same post is rejected (read-and-clear).
    @Test func takeCancelIntentIsTrueOnceThenConsumed() {
        Self.clearKeys()
        defer { Self.clearKeys() }
        WidgetBolusStore.setCancelIntent(requestId: "wr05-req")
        #expect(WidgetBolusStore.takeCancelIntent() == true)  // legit cancel honored
        #expect(WidgetBolusStore.takeCancelIntent() == false)  // single-use: replay dropped
    }

    /// A token older than `confirmTTL` is rejected — a captured/late post can't cancel a fresh bolus.
    @Test func expiredCancelTokenIsRejected() {
        Self.clearKeys()
        defer { Self.clearKeys() }
        // Seed an expired token directly (can't sleep confirmTTL seconds in a unit test).
        Self.suite.set("wr05-stale", forKey: "wbCancelReq")
        Self.suite.set(Date().timeIntervalSince1970 - (WidgetBolusStore.confirmTTL + 5), forKey: "wbCancelAt")
        #expect(WidgetBolusStore.takeCancelIntent() == false)
    }

    // MARK: - WR-04 / VA-26: pending freshness

    /// A fresh completed request is returned and then consumed (removed) so it can't be delivered twice.
    @Test func freshPendingIsReturnedThenConsumed() {
        Self.clearKeys()
        defer { Self.clearKeys() }
        let req = WidgetBolusRequest(amount: 2.5, mode: "units", requestId: "wr04-fresh", createdAt: Date())
        WidgetBolusStore.setPending(req)
        let taken = WidgetBolusStore.takePending()
        #expect(taken?.requestId == "wr04-fresh")
        #expect(taken?.amount == 2.5)
        #expect(WidgetBolusStore.takePending() == nil)  // consumed — never delivered twice
    }

    /// A completed request older than `pendingTTL` (120 s) is dropped (nil) rather than auto-consumed, and
    /// the stale entry is still cleared.
    @Test func stalePendingBeyondTTLIsDropped() {
        Self.clearKeys()
        defer { Self.clearKeys() }
        let stale = WidgetBolusRequest(
            amount: 2.5, mode: "units", requestId: "wr04-stale",
            createdAt: Date().addingTimeInterval(-(WidgetBolusStore.pendingTTL + 1)))
        WidgetBolusStore.setPending(stale)
        #expect(WidgetBolusStore.takePending() == nil)
        #expect(WidgetBolusStore.takePending() == nil)  // and it was consumed, not left to linger
    }
}
