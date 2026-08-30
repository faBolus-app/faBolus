import Testing
import Foundation
import faBolusCore
import TandemBLE
@testable import faBolus

/// Rapid live→connecting flaps must escalate once past five cycles in two minutes so a silent reconnect
/// storm is not invisible.
@Suite(.serialized) @MainActor
struct ConnectionFlapEscalationTests {

    // MARK: - Pure detector: threshold, window, latch, reset

    @Test func thresholdAndWindowConstants() {
        #expect(ConnectionFlapDetector.threshold == 5, "5 flap cycles")
        #expect(ConnectionFlapDetector.window == 120, "within 2 minutes")
    }

    // NOTE: `recordFlap`/`reset` are `mutating`, and swift-testing's `#expect` macro captures its argument
    // expression in a non-escaping autoclosure where `self`/locals are immutable — so a mutating call may
    // not appear INSIDE `#expect(...)`. Every mutating call below is made on its own line and its result
    // bound to a `let` first, then asserted.

    @Test func escalatesExactlyOnceAtTheThresholdWithinTheWindow() {
        var d = ConnectionFlapDetector()
        let t0 = Date()
        for i in 0..<4 {
            let escalated = d.recordFlap(at: t0.addingTimeInterval(Double(i)))
            #expect(!escalated, "flap \(i + 1) is below threshold")
        }
        let fifth = d.recordFlap(at: t0.addingTimeInterval(4))
        #expect(fifth, "the 5th flap within the window escalates")
        #expect(d.escalated)
        // Latched: further flaps in the same storm do NOT re-escalate.
        let sixth = d.recordFlap(at: t0.addingTimeInterval(5))
        let seventh = d.recordFlap(at: t0.addingTimeInterval(6))
        #expect(!sixth && !seventh, "further flaps must not re-escalate (latched)")
    }

    @Test func flapsThatFallOutsideTheWindowAreNotCounted() {
        var d = ConnectionFlapDetector()
        let t0 = Date()
        // 4 flaps early in the window…
        for i in 0..<4 {
            let escalated = d.recordFlap(at: t0.addingTimeInterval(Double(i * 10)))
            #expect(!escalated)
        }
        // …then a 5th more than `window` after the FIRST: the first flap (t0) is pruned, so only 4 remain
        // in the window and the threshold is NOT reached.
        let outside = d.recordFlap(at: t0.addingTimeInterval(ConnectionFlapDetector.window + 1))
        #expect(!outside, "a flap that pushes the oldest out of the rolling window must not escalate")
        #expect(!d.escalated)
    }

    @Test func resetClearsTheLatchAndWindowSoAFreshStormReEscalates() {
        var d = ConnectionFlapDetector()
        let t0 = Date()
        for i in 0..<5 { _ = d.recordFlap(at: t0.addingTimeInterval(Double(i))) }
        #expect(d.escalated)
        let hadEscalated = d.reset()
        #expect(hadEscalated, "reset returns whether it HAD escalated (so the caller can withdraw)")
        #expect(!d.escalated && d.flapTimes.isEmpty, "reset clears both the latch and the window")
        let secondReset = d.reset()
        #expect(!secondReset, "a second reset with nothing escalated returns false")
        // A fresh storm escalates again.
        for i in 0..<4 {
            let escalated = d.recordFlap(at: t0.addingTimeInterval(Double(200 + i)))
            #expect(!escalated)
        }
        let reEscalate = d.recordFlap(at: t0.addingTimeInterval(204))
        #expect(reEscalate, "a fresh storm after reset re-escalates")
    }

    // MARK: - Wiring: a real flap storm through the backend emits the typed edge

    /// Drives `TandemBackend.applyClientState` (which delegates to `PumpConnectionLifecycle`) through five
    /// live→`.connecting` re-pair/re-drop cycles and asserts the `.connectionUnstable` reliability edge
    /// fires exactly once at the 5th — never at the 4th, and never again while the storm continues.
    ///
    /// ⚠️ THIS TEST WAS A FALSE GATE, kept only for its threshold/latch coverage. It re-arms "the link was
    /// live" with `setConnectionForTesting(.connected)`, which BYPASSES `markUsableAndStartPolling()` — the
    /// one production non-live→`.connected` path, whose `flapDetector.reset()` call cleared the window on
    /// the recovery half of every flap cycle and made escalation unreachable. This test passed for the
    /// entire time the feature was completely inert. A test double that skips the defective path is not a
    /// gate. `fiveRecoverThenReflapCyclesThroughTheRealRecoveryPathEscalateExactlyOnce` below is the real
    /// one; do not delete it in favour of this.
    @Test func fiveLiveToConnectingCyclesEmitConnectionUnstableExactlyOnce() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        var events: [ReliabilityEvent] = []
        b.onReliabilityEvent = { events.append($0) }

        func flap() {
            b.setConnectionForTesting(.connected)  // link is live…
            b.applyClientState(.connecting)  // …then drops to reconnecting = one flap cycle
        }

        for _ in 0..<4 { flap() }
        #expect(!events.contains(.connectionUnstable), "four flap cycles within the window must stay silent")

        flap()  // the 5th
        #expect(
            events.filter { $0 == .connectionUnstable }.count == 1,
            "the 5th flap cycle crosses the threshold → emit .connectionUnstable exactly once")

        flap()
        flap()  // storm continues
        #expect(
            events.filter { $0 == .connectionUnstable }.count == 1,
            "the edge is latched — a continuing storm does not re-emit it")
    }

    /// A NON-live transition (e.g. `.scanning → .connecting` on a cold first connect) is NOT a flap and must
    /// not be counted — otherwise a normal first-connect climb would spuriously escalate.
    @Test func nonLiveTransitionsAreNotCountedAsFlaps() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        var events: [ReliabilityEvent] = []
        b.onReliabilityEvent = { events.append($0) }
        for _ in 0..<10 {
            b.setConnectionForTesting(.scanning)  // NOT a live link
            b.applyClientState(.connecting)
        }
        #expect(
            !events.contains(.connectionUnstable),
            "a .scanning → .connecting climb is a normal connect, never a flap — must not escalate")
    }

    // MARK: - D4: escalation must be REACHABLE through the REAL recovery path
    //
    // `markUsableAndStartPolling()` is the only production path from a non-live state to `.connected`, so
    // it is the recovery half of EVERY flap cycle. While it called `flapDetector.reset()`, exactly one
    // clear sat between any two `recordFlap` calls, `flapTimes.count` was pinned at 1 against a
    // `threshold` of 5, and `pumpConnectionUnstable` could never fire. These tests drive that real path.

    /// The reads-only terminal fallback in `pumpClientDidBecomeReady` is a REAL
    /// `markUsableAndStartPolling()` site (`""` pairing code + cleared store), so it reproduces the
    /// production recovery half without any test seam. Pattern borrowed from `PairingWatchdogTests`.
    private func recoverForReal(_ b: TandemBackend) {
        PairingStore.clear()
        b.beginPairingForTesting(code: "")
    }

    /// D4 REGRESSION — five recover-then-reflap cycles inside the window must escalate EXACTLY ONCE, with
    /// every recovery a genuine `markUsableAndStartPolling()`. Pre-fix this observed ZERO escalations.
    @Test func fiveRecoverThenReflapCyclesThroughTheRealRecoveryPathEscalateExactlyOnce() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        var events: [ReliabilityEvent] = []
        b.onReliabilityEvent = { events.append($0) }

        for cycle in 1...5 {
            recoverForReal(b)  // REAL recovery: publishes the usable `.connected`
            #expect(
                b.snapshot.connection == .connected,
                "cycle \(cycle): the recovery half must publish the usable link")
            b.applyClientState(.connecting)  // the drop → one live→`.connecting` flap cycle
        }

        #expect(
            events.filter { $0 == .connectionUnstable }.count == 1,
            "5 flap cycles whose recoveries run the REAL markUsableAndStartPolling must escalate once")

        b.applyClientState(.disconnected)  // cleanup: release any poll timer this test armed
    }

    /// ANTI-CRYING-WOLF — one genuine drop-and-reconnect is a normal silent background reconnect and must
    /// stay silent. An over-firing instability alert on a healthy link would be worse than the old silence.
    @Test func aSingleGenuineReconnectNeverEscalates() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        var events: [ReliabilityEvent] = []
        b.onReliabilityEvent = { events.append($0) }

        recoverForReal(b)
        b.applyClientState(.connecting)  // one flap…
        recoverForReal(b)  // …and the link comes back

        #expect(
            !events.contains(.connectionUnstable),
            "a single background reconnect is not a storm — it must never escalate")

        b.applyClientState(.disconnected)
    }

    /// ANTI-CRYING-WOLF at the boundary: four flaps in the window is one short of the threshold.
    @Test func fourFlapsInTheWindowNeverEscalate() {
        var d = ConnectionFlapDetector()
        let t0 = Date()
        for i in 0..<4 {
            let escalated = d.recordFlap(at: t0.addingTimeInterval(Double(i)))
            #expect(!escalated, "flap \(i + 1) of 4 is below the threshold")
        }
        #expect(!d.escalated, "four flaps must not escalate")
    }

    /// ANTI-CRYING-WOLF over time: a link that reconnects once a minute for ten minutes is NOT a storm — at
    /// 60 s spacing at most three flaps ever share a 120 s window, so it must never escalate.
    @Test func wellSpacedHealthyReconnectsNeverEscalate() {
        var d = ConnectionFlapDetector()
        let t0 = Date()
        for i in 0..<10 {
            let escalated = d.recordFlap(at: t0.addingTimeInterval(Double(i) * 60))
            #expect(!escalated, "a reconnect every 60 s is not a storm (flap \(i + 1))")
        }
        #expect(!d.escalated, "well-spaced healthy reconnects must not escalate")
    }

    /// The latch is released by the PASSAGE OF TIME, not by the owner: a full quiet `window` with no flaps
    /// must decay a previous escalation so a FRESH storm escalates again — exactly once. Pins the
    /// prune-before-append + re-arm half of the fix (on HEAD the latch was permanent once set).
    @Test func aFullQuietWindowDecaysTheLatchSoAFreshStormReEscalatesExactlyOnce() {
        var d = ConnectionFlapDetector()
        let t0 = Date()
        for i in 0..<5 { _ = d.recordFlap(at: t0.addingTimeInterval(Double(i))) }
        #expect(d.escalated, "the first storm escalated")

        // A full quiet window measured from the LAST flap (t0+4): the next flap prunes everything.
        let quiet = t0.addingTimeInterval(4 + ConnectionFlapDetector.window + 1)
        let first = d.recordFlap(at: quiet)
        #expect(!first, "the first flap of a fresh storm does not itself escalate")
        #expect(!d.escalated, "a full quiet window must decay the latch")

        for i in 1..<4 {
            let escalated = d.recordFlap(at: quiet.addingTimeInterval(Double(i)))
            #expect(!escalated, "flap \(i + 1) of the fresh storm is below the threshold")
        }
        let fifth = d.recordFlap(at: quiet.addingTimeInterval(4))
        #expect(fifth, "a fresh storm after a full quiet window re-escalates exactly once")
    }
}
