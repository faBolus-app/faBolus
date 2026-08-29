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
    /// fires exactly once at the 5th — never at the 4th, and never again while the storm continues. Uses
    /// `setConnectionForTesting(.connected)` to re-arm "the link was live" before each drop (it does NOT
    /// reset the detector — only a genuine `markUsableAndStartPolling` reconnect does).
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
}
