import Testing
import Foundation
@testable import faBolus

/// Pins that a background reconnect arms one background-execution window and releases it on recovery,
/// terminal state, or OS expiry — never in the foreground. Without that window the kit's reconnect tick never runs while suspended.
@Suite(.serialized) @MainActor
struct PumpBackgroundSessionTests {

    /// Records the injected-seam interactions so a test can assert the arm/disarm behaviour.
    @MainActor
    private final class Harness {
        var beginCount = 0
        var endedTokens: [Int] = []
        var foreground = false
        var lastExpire: (() -> Void)?
        private var nextToken = 1

        func wire(_ s: PumpBackgroundSession) {
            s.isForeground = { [unowned self] in self.foreground }
            s.beginTask = { [unowned self] _, onExpire in
                self.beginCount += 1
                self.lastExpire = onExpire
                defer { self.nextToken += 1 }
                return self.nextToken
            }
            s.endTask = { [unowned self] token in self.endedTokens.append(token) }
        }
    }

    // MARK: - Background reconnect window

    @Test func armsBackgroundWindowOnReconnectAttemptWhileBackgrounded() {
        let h = Harness()
        let s = PumpBackgroundSession()
        h.wire(s)
        h.foreground = false
        s.willAttemptReconnect(after: 5)
        #expect(h.beginCount == 1, "a backgrounded reconnect attempt must open a background-execution window (H1)")
        #expect(s.isTaskActiveForTesting)
    }

    @Test func doesNotArmWhileForegrounded() {
        let h = Harness()
        let s = PumpBackgroundSession()
        h.wire(s)
        h.foreground = true
        s.willAttemptReconnect(after: 5)
        #expect(h.beginCount == 0, "the foreground RunLoop is already alive — no background window is needed")
        #expect(!s.isTaskActiveForTesting)
    }

    @Test func doesNotDoubleArmAcrossLadderSteps() {
        let h = Harness()
        let s = PumpBackgroundSession()
        h.wire(s)
        h.foreground = false
        s.willAttemptReconnect(after: 5)
        s.willAttemptReconnect(after: 10)  // next throttled ladder step, still backgrounded
        #expect(h.beginCount == 1, "a single window must span the whole reconnect ladder, not churn per attempt")
        #expect(s.isTaskActiveForTesting)
    }

    @Test func releasesWindowWhenLinkBecomesReady() {
        let h = Harness()
        let s = PumpBackgroundSession()
        h.wire(s)
        h.foreground = false
        s.willAttemptReconnect(after: 5)
        s.linkDidBecomeReady()
        #expect(h.endedTokens == [1], "recovery must release the H1 window")
        #expect(!s.isTaskActiveForTesting)
    }

    @Test func releasesWindowWhenReconnectTerminates() {
        let h = Harness()
        let s = PumpBackgroundSession()
        h.wire(s)
        h.foreground = false
        s.willAttemptReconnect(after: 5)
        s.linkDidTerminate()  // user disconnect / radio off / reconnectExhausted
        #expect(h.endedTokens == [1], "a terminal link state must release the H1 window")
        #expect(!s.isTaskActiveForTesting)
    }

    @Test func failsSafeWhenTheOSExpiresTheWindow() {
        let h = Harness()
        let s = PumpBackgroundSession()
        h.wire(s)
        h.foreground = false
        s.willAttemptReconnect(after: 5)
        h.lastExpire?()  // iOS is about to suspend us
        #expect(h.endedTokens == [1], "the expiration handler must end the task so iOS does not kill the app")
        #expect(!s.isTaskActiveForTesting)
    }

    // MARK: - Foreground→background must re-evaluate a reconnect scheduled while still foreground

    @Test func enteredBackgroundArmsAWindowForAReconnectScheduledWhileStillForeground() {
        let h = Harness()
        let s = PumpBackgroundSession()
        h.wire(s)
        h.foreground = true
        s.willAttemptReconnect(after: 5)  // scheduled while STILL foreground — no window needed yet
        #expect(h.beginCount == 0, "no window is needed while the RunLoop is already alive")
        #expect(!s.isTaskActiveForTesting)

        h.foreground = false  // the scene backgrounds mid-delay, BEFORE the kit's Timer fires
        s.enteredBackground()
        #expect(
            h.beginCount == 1,
            "the fg->bg transition must re-evaluate the still-pending reconnect and open the window — not strand it")
        #expect(s.isTaskActiveForTesting)
    }

    @Test func enteredBackgroundIsANoOpWhenNoReconnectIsPending() {
        let h = Harness()
        let s = PumpBackgroundSession()
        h.wire(s)
        h.foreground = true
        s.enteredBackground()  // no willAttemptReconnect ever called
        h.foreground = false
        s.enteredBackground()
        #expect(h.beginCount == 0, "backgrounding with nothing pending must never open a window")
        #expect(!s.isTaskActiveForTesting)
    }

    @Test func enteredBackgroundDoesNotDoubleArmWhenAWindowIsAlreadyHeld() {
        let h = Harness()
        let s = PumpBackgroundSession()
        h.wire(s)
        h.foreground = false
        s.willAttemptReconnect(after: 5)  // scheduled already backgrounded — arms immediately
        #expect(h.beginCount == 1)
        s.enteredBackground()  // a later fg->bg-equivalent re-check while still held
        #expect(h.beginCount == 1, "an already-held window must not be re-armed/duplicated")
    }
}
