import Testing
import Foundation
@testable import faBolus

/// An unauthenticated `widgetBolusCancel` Darwin post is dropped unless a single-use, TTL-bounded
/// App-Group token is present. `takePending()` hard-drops a completed request older than `pendingTTL`
/// so a stale widget confirm cannot be auto-consumed.
///
/// `.serialized` because every test here mutates the ONE real shared App-Group
/// `UserDefaults(suiteName:)`. Each test clears ONLY its own keys — never
/// `removePersistentDomain`, which would wipe the container other suites bind to.
@Suite(.serialized)
struct WidgetBolusStoreGuardTests {

    private static var suite: UserDefaults { UserDefaults(suiteName: WidgetStore.appGroup)! }
    private static func clearKeys() {
        let d = suite
        for k in ["wbPending", "wbCancelReq", "wbCancelAt"] { d.removeObject(forKey: k) }
    }

    // MARK: - Cancel-intent token

    /// A bare Darwin post (nothing written) is rejected — the core anti-nuisance property.
    @Test func takeCancelIntentIsFalseWithNoToken() {
        Self.clearKeys(); defer { Self.clearKeys() }
        #expect(WidgetBolusStore.takeCancelIntent() == false)
    }

    /// The legit cancel writes a token, so the receiver's first read succeeds — and it is single-use, so an
    /// immediate replay of the same post is rejected (read-and-clear).
    @Test func takeCancelIntentIsTrueOnceThenConsumed() {
        Self.clearKeys(); defer { Self.clearKeys() }
        WidgetBolusStore.setCancelIntent(requestId: "wr05-req")
        #expect(WidgetBolusStore.takeCancelIntent() == true)   // legit cancel honored
        #expect(WidgetBolusStore.takeCancelIntent() == false)  // single-use: replay dropped
    }

    /// A token older than `confirmTTL` is rejected — a captured/late post can't cancel a fresh bolus.
    @Test func expiredCancelTokenIsRejected() {
        Self.clearKeys(); defer { Self.clearKeys() }
        // Seed an expired token directly (can't sleep confirmTTL seconds in a unit test).
        Self.suite.set("wr05-stale", forKey: "wbCancelReq")
        Self.suite.set(Date().timeIntervalSince1970 - (WidgetBolusStore.confirmTTL + 5), forKey: "wbCancelAt")
        #expect(WidgetBolusStore.takeCancelIntent() == false)
    }

    // MARK: - Pending freshness

    /// A fresh completed request is returned and then consumed (removed) so it can't be delivered twice.
    @Test func freshPendingIsReturnedThenConsumed() {
        Self.clearKeys(); defer { Self.clearKeys() }
        let req = WidgetBolusRequest(amount: 2.5, mode: "units", requestId: "wr04-fresh", createdAt: Date())
        WidgetBolusStore.setPending(req)
        let taken = WidgetBolusStore.takePending()
        #expect(taken?.requestId == "wr04-fresh")
        #expect(taken?.amount == 2.5)
        #expect(WidgetBolusStore.takePending() == nil)   // consumed — never delivered twice
    }

    /// A completed request older than `pendingTTL` (120 s) is dropped (nil) rather than auto-consumed, and
    /// the stale entry is still cleared.
    @Test func stalePendingBeyondTTLIsDropped() {
        Self.clearKeys(); defer { Self.clearKeys() }
        let stale = WidgetBolusRequest(amount: 2.5, mode: "units", requestId: "wr04-stale",
                                       createdAt: Date().addingTimeInterval(-(WidgetBolusStore.pendingTTL + 1)))
        WidgetBolusStore.setPending(stale)
        #expect(WidgetBolusStore.takePending() == nil)
        #expect(WidgetBolusStore.takePending() == nil)   // and it was consumed, not left to linger
    }
}
