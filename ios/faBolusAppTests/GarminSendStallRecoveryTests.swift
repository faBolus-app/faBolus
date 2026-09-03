import Testing
import Foundation
@testable import faBolus

/// Behavior pins for the phone→watch send path's SELF-RECOVERY, added for the `watch-cgm-status-lag`
/// (bug 2.2) hard stall: the owner's watch CGM reading refreshed exactly once per tap of
/// "Set up Garmin remote" and never on its own. The device diagnostics export
/// (`Queue depth: 2`, `Last send: timed out`, `Watchdog fires: 10`, `Device: connected`) showed sends
/// being attempted and their ConnectIQ completions never arriving, on a link the SDK reported as
/// connected.
///
/// Root cause was an AND-gate: a transport condition where `sendMessage` completions do not arrive
/// within the bridge's deadline, met by a send path with NO automatic recovery from it — the only code
/// edge that rebuilt the `IQApp`/registration or re-armed readiness was `registerApp()`, reachable in
/// practice only via that user tap. These are the ConnectIQ-free seams that make the recovery
/// decisions unit-testable in the default (non-GARMIN) target, exactly like
/// `garminSendDisposition` / `garminClassifyAppInstallState` / `GarminMessageReadiness`.
struct GarminSendStallRecoveryTests {

    // MARK: - Watchdog verdict: no-PROGRESS stall, not "not finished yet"
    //
    // The vendored SDK (ConnectIQ.h, `sendMessage:toApp:progress:completion:isTransient:`) guarantees
    // the PROGRESS block fires "at least once"; the COMPLETION block carries no such guarantee. The
    // bridge passed `progress: nil` and armed a flat 8 s deadline against "operation complete", so a
    // legitimately slow multi-KB status transfer (144 history + 144 epoch points) was re-sent ON TOP of
    // the still-live transfer — the SDK serialises sends per app, so each retry queued behind the
    // original and pushed the real completion further out, which the stale-generation guard then
    // discarded. The watchdog could manufacture the very timeouts it existed to recover from.

    /// The load-bearing pin: a transfer that is still MOVING must never be declared stalled, no matter
    /// how long it has been running (below the hard ceiling).
    @Test func aProgressingTransferIsNotStalled() {
        let v = garminSendWatchdogVerdict(
            sinceLastProgress: 1, sinceStart: 20, noProgressTimeout: 8, hardCeiling: 60)
        #expect(v == .progressing, "bytes are still moving — re-sending on top of it is what wedged the queue")
    }

    /// No bytes for longer than the timeout is a genuine stall — this is the case the watchdog is for.
    @Test func noProgressForTheTimeoutIsStalled() {
        let v = garminSendWatchdogVerdict(
            sinceLastProgress: 8, sinceStart: 8, noProgressTimeout: 8, hardCeiling: 60)
        #expect(v == .stalled)
    }

    /// A slow-loris transfer that keeps trickling progress must still be cut off, or `sendInFlight`
    /// would hold the single in-flight slot forever — the exact wedge the watchdog was added to prevent.
    @Test func hardCeilingStallsEvenWhileProgressing() {
        let v = garminSendWatchdogVerdict(
            sinceLastProgress: 0, sinceStart: 60, noProgressTimeout: 8, hardCeiling: 60)
        #expect(v == .stalled, "an unbounded 'progressing' send must never own the in-flight slot forever")
    }

    // MARK: - Stall escalation → automatic re-registration (what the user's tap did by hand)

    /// A single stall is not enough to justify tearing down and rebuilding the registration.
    @Test func oneStallKeepsRetryingWithoutReregistering() {
        var t = GarminSendStallTracker()
        #expect(t.recordStall(now: Date()) == .keepRetrying)
        #expect(t.consecutiveStalls == 1)
    }

    /// The core self-healing pin: once a payload's attempt budget is exhausted with no completion, the
    /// bridge must rebuild the `IQApp` + registration ITSELF — the same thing tapping
    /// "Set up Garmin remote" does — instead of waiting for a user action that may never come.
    @Test func exhaustedAttemptsEscalateToReregister() {
        var t = GarminSendStallTracker()
        let now = Date()
        #expect(t.recordStall(now: now) == .keepRetrying)
        #expect(t.recordStall(now: now.addingTimeInterval(8)) == .keepRetrying)
        #expect(
            t.recordStall(now: now.addingTimeInterval(16)) == .reregister,
            "three stalls == one exhausted payload (maxSendAttempts) — rebuild the channel automatically")
    }

    /// A completion that ARRIVES — success or an explicit SDK failure result — proves the channel is
    /// alive, so the streak resets and no re-registration is warranted. An explicit
    /// `IQSendMessageResult` failure is a very different signal from silence.
    @Test func anArrivingCompletionResetsTheStallStreak() {
        var t = GarminSendStallTracker()
        let now = Date()
        _ = t.recordStall(now: now)
        _ = t.recordStall(now: now.addingTimeInterval(8))
        t.recordCompletion()
        #expect(t.consecutiveStalls == 0)
        #expect(
            t.recordStall(now: now.addingTimeInterval(16)) == .keepRetrying,
            "the streak restarted — a live channel must not be torn down on one fresh stall")
    }

    /// Re-registration must be rate-limited: unregister/register churn every 24 s on a genuinely dead
    /// link would be its own battery and BLE-congestion problem.
    @Test func reregistrationIsRateLimited() {
        var t = GarminSendStallTracker()
        let t0 = Date()
        _ = t.recordStall(now: t0)
        _ = t.recordStall(now: t0)
        #expect(t.recordStall(now: t0) == .reregister)
        // Immediately stall three more times, still inside the minimum interval.
        _ = t.recordStall(now: t0.addingTimeInterval(1))
        _ = t.recordStall(now: t0.addingTimeInterval(2))
        #expect(
            t.recordStall(now: t0.addingTimeInterval(3)) == .keepRetrying,
            "a second rebuild inside the minimum interval must be suppressed")
    }

    /// …but once the interval has elapsed, a still-dead channel must be rebuilt again — recovery has to
    /// keep trying indefinitely, or a stall that outlives one rebuild becomes permanent again.
    @Test func reregistrationResumesAfterTheMinimumInterval() {
        var t = GarminSendStallTracker()
        let t0 = Date()
        _ = t.recordStall(now: t0)
        _ = t.recordStall(now: t0)
        #expect(t.recordStall(now: t0) == .reregister)
        let later = t0.addingTimeInterval(GarminSendStallTracker.minReregisterInterval + 1)
        _ = t.recordStall(now: later)
        _ = t.recordStall(now: later)
        #expect(t.recordStall(now: later) == .reregister, "self-healing must not give up after one attempt")
    }

    // MARK: - Status starvation valve (the echo head-of-line livelock)
    //
    // `pump()` drains `echoQueue` STRICTLY before `pendingStatus`, and a watchdog-exhausted echo is
    // re-parked at `echoQueue` index 0 — where the next `pump()` re-pulls it with `attempts` RESET to
    // 0. So `maxSendAttempts` was not a global bound: one undeliverable echo (e.g. a terminal
    // bolus-status echo) retried forever and starved every status push AND every watch-poll reply.
    // `Queue depth: 2` pinned forever is exactly that shape.
    //
    // The valve must NOT weaken the safety rule: a terminal bolus echo is never dropped, never
    // coalesced, and echo-vs-echo ORDER is never changed. It only lets a pending status take ONE slot
    // ahead of an echo that has ALREADY exhausted its attempts.

    /// Normal priority is unchanged: a healthy echo still goes before a pending status, so a bolus
    /// outcome never waits behind a CGM snapshot.
    @Test func aHealthyEchoStillOutranksAPendingStatus() {
        #expect(
            garminNextPumpSlot(hasEcho: true, headEchoExhausted: false, hasPendingStatus: true) == .echo,
            "terminal echoes keep priority — this is the rule the valve must not break")
    }

    /// The core anti-starvation pin: an echo that has already burned its attempt budget yields ONE slot
    /// to the pending status, so CGM cannot be blocked forever by a wedged echo.
    @Test func anExhaustedEchoYieldsOneSlotToAPendingStatus() {
        #expect(
            garminNextPumpSlot(hasEcho: true, headEchoExhausted: true, hasPendingStatus: true) == .status,
            "a wedged echo must not starve the CGM/pump status the watch is waiting for")
    }

    /// Yielding is not dropping: with nothing else to send, the exhausted echo is retried, not discarded.
    @Test func anExhaustedEchoIsStillRetriedWhenNoStatusIsPending() {
        #expect(
            garminNextPumpSlot(hasEcho: true, headEchoExhausted: true, hasPendingStatus: false) == .echo,
            "the echo is deprioritised, never abandoned")
    }

    @Test func statusIsServedWhenNoEchoIsQueued() {
        #expect(garminNextPumpSlot(hasEcho: false, headEchoExhausted: false, hasPendingStatus: true) == .status)
    }

    @Test func nothingQueuedIsIdle() {
        #expect(garminNextPumpSlot(hasEcho: false, headEchoExhausted: false, hasPendingStatus: false) == .idle)
        #expect(
            garminNextPumpSlot(hasEcho: false, headEchoExhausted: true, hasPendingStatus: false) == .idle,
            "an exhaustion flag with an empty echo queue must not fabricate work")
    }

    // MARK: - Boundary neighbours around the fixed defect's equivalence class

    /// Just under the escalation threshold must NOT rebuild — pins the off-by-one on the attempt budget.
    @Test func stallCountJustBelowThresholdDoesNotReregister() {
        var t = GarminSendStallTracker()
        let now = Date()
        for i in 0..<(GarminSendStallTracker.stallsBeforeReregister - 1) {
            #expect(t.recordStall(now: now.addingTimeInterval(Double(i))) == .keepRetrying)
        }
        #expect(t.consecutiveStalls == GarminSendStallTracker.stallsBeforeReregister - 1)
    }

    /// Exactly at the no-progress timeout is stalled (inclusive boundary), a hair under is not.
    @Test func noProgressTimeoutBoundaryIsInclusive() {
        #expect(
            garminSendWatchdogVerdict(
                sinceLastProgress: 7.999, sinceStart: 7.999, noProgressTimeout: 8, hardCeiling: 60)
                == .progressing)
        #expect(
            garminSendWatchdogVerdict(
                sinceLastProgress: 8.0, sinceStart: 8.0, noProgressTimeout: 8, hardCeiling: 60) == .stalled)
    }

    /// A fresh tracker has nothing to report and must not claim a rebuild is due.
    @Test func freshTrackerHasNoStallsAndNoPriorReregistration() {
        let t = GarminSendStallTracker()
        #expect(t.consecutiveStalls == 0)
        #expect(t.lastReregister == nil)
    }

    // MARK: - Arming-probe retry (the last hole in the recovery path)
    //
    // Re-arming on the `.connected` transition only helps if a further device event actually arrives,
    // and an arming probe that resolves `.unknown` leaves readiness false with nothing scheduled to try
    // again. The blocked send itself therefore drives a rate-limited re-probe: the phone pushes status
    // on every new CGM value plus a ~20 s quiet-link backstop, so the component that wants to transmit
    // is the one that repairs the gate, and no permanent latch can survive.

    /// Never probed before ⇒ probe now. Without this, a bridge that came up unarmed stays unarmed.
    @Test func firstArmingProbeIsAlwaysAllowed() {
        #expect(garminShouldRetryArmingProbe(lastProbe: nil, now: Date(), minInterval: 20) == true)
    }

    /// The load-bearing pin: recovery must keep retrying forever, not give up after one attempt.
    @Test func armingProbeRetriesOnceTheIntervalElapses() {
        let t0 = Date()
        #expect(
            garminShouldRetryArmingProbe(lastProbe: t0, now: t0.addingTimeInterval(20), minInterval: 20) == true,
            "a stranded gate must be re-probed indefinitely — this is the no-permanent-latch guarantee")
    }

    /// …but not on every single queued status push, or a wedged bridge would probe several times a second.
    @Test func armingProbeIsRateLimitedWithinTheInterval() {
        let t0 = Date()
        #expect(
            garminShouldRetryArmingProbe(lastProbe: t0, now: t0.addingTimeInterval(19.9), minInterval: 20) == false)
    }
}
