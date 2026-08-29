import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// A dropped BLE link must tear down timers, coordinators, and the auth key so a stale poll or
/// signed read cannot fire into a dead or pre-auth link (fail-closed on reconnect).
@Suite(.serialized) @MainActor
struct LinkDropTeardownTests {
    private func backend() -> TandemBackend { TandemBackend(testTransport: FakePumpTransport()) }

    private let bolusId = 1234

    /// op-35 `CurrentEGVGuiDataResponse` (V1, 8 bytes) with an explicit `pumpSec`
    /// (`bgReadingTimestampSeconds`, uint32@0) so an ADVANCING timestamp schedules the predictive burst —
    /// `FakePumpTransport.currentEgvV1` always leaves this zero. Mirrors the private builder in
    /// `ReadCascadeChainingGuardTests` exactly.
    private static func egvV1Frame(pumpSec: UInt32, mgdl: Int) -> [UInt8] {
        var c = [UInt8](repeating: 0, count: 8)
        let ts = Bytes.toUint32(pumpSec)
        for i in 0..<4 { c[i] = ts[i] }
        let bg = Bytes.firstTwoBytesLittleEndian(mgdl)
        c[4] = bg[0]
        c[5] = bg[1]
        c[6] = 1  // egvStatusId = 1 → hasValidReading
        return FakePumpTransport.frame(opCode: CurrentEGVGuiDataResponse.props.opCode, cargo: c, signed: false)
    }

    private func capture(_ op: () async throws -> Double) async -> Error? {
        do {
            _ = try await op()
            return nil
        } catch { return error }
    }
    private func isIndeterminate(_ e: Error?) -> Bool { (e as? BolusError)?.isIndeterminate ?? false }

    // MARK: - `.connecting` from a live link runs the shared teardown

    /// The unintended-drop-as-`.connecting` path: a link that WAS live (`.connected`) with a running poll
    /// timer and a live auth key must, on `applyClientState(.connecting)`, publish `.connecting` AND run
    /// the full `linkDroppedCleanup()` — so the recurring poll timer, the poll-cycle generation, and the
    /// auth key are all torn down before the reconnect gap. Pre-fix, `.connecting` skipped
    /// `linkDroppedCleanup()` entirely, leaving all of them alive across the gap.
    @Test func dropToConnectingFromLiveRunsTheSharedTeardown() {
        let b = backend()
        // Precondition: a live, paired link with the recurring poll timer running (a real post-pair state).
        // The test-transport init defaults to `.connected` + a non-empty auth key; make the live state
        // explicit and arm a genuine `pollTimer` (the seam runs the REAL `startPolling()` and leaves the
        // timer live so this test — not the seam's own cleanup — is what tears it down).
        b.setConnectionForTesting(.connected)
        b.startPollingLeavingPollTimerRunningForTesting()
        #expect(b.pollTimerIsActiveForTesting, "precondition: the recurring poll timer is armed on a live link")
        #expect(b.isPairedForTesting, "precondition: the link is paired (auth key present)")
        let generationBefore = b.pollCycleGenerationForTesting

        // An unintended BLE drop that surfaces as `.connecting` must run the shared teardown
        // because the link was live.
        b.applyClientState(.connecting)

        // Publishes the reconnect-window state as `.connecting`, never `.disconnected` (preserves the
        // reconnect-window semantics `TandemConnectionStateTests` pins).
        #expect(b.snapshot.connection == .connecting)
        // stopAllTimers(): the recurring poll timer is invalidated so it can no longer tick
        // `recurringPollTick()` and inject stale reads across the reconnect gap.
        #expect(b.pollTimerIsActiveForTesting == false, "stopAllTimers() must tear down the recurring poll timer")
        // notePollCycleEnded(): the generation advances so an already-armed `scheduleAlertRead()` from the
        // cycle that just ended recognizes it is stale and no-ops instead of firing a rogue alert read.
        #expect(
            b.pollCycleGenerationForTesting > generationBefore,
            "notePollCycleEnded() must advance the poll-cycle generation")
        // Auth key cleared → `isPaired` fails closed, so a signed read can't land in the pre-auth window
        // before `onPaired` rebuilds the key on the next connect (and `validateDeliver` fails closed too).
        #expect(b.isPairedForTesting == false, "the auth key must be cleared so a signed read can't land pre-auth")
    }

    /// The counterpart: a normal first-connect climb (`.scanning`/`.disconnected` → `.connecting`) is NOT
    /// `wasLive`, so `applyClientState(.connecting)` must publish `.connecting` WITHOUT running
    /// `linkDroppedCleanup()` — no generation bump and no spurious auth-key clear. This is exactly the
    /// wasLive-vs-not discriminator: the same call that tears everything down above is inert here.
    @Test func notLiveClimbToConnectingDoesNotTearDown() {
        for priorState: PumpConnectionState in [.scanning, .disconnected] {
            let b = backend()
            b.setConnectionForTesting(priorState)  // NOT live (.connected/.bolusing)
            #expect(b.isPairedForTesting, "precondition: the test double carries an auth key")
            let generationBefore = b.pollCycleGenerationForTesting

            b.applyClientState(.connecting)

            #expect(b.snapshot.connection == .connecting, "prior \(priorState): climb still publishes .connecting")
            // No teardown side effects — these would flip only if `linkDroppedCleanup()` had run (the
            // wasLive path). They stay put here, distinguishing the not-live climb from a real drop.
            #expect(
                b.pollCycleGenerationForTesting == generationBefore,
                "prior \(priorState): a not-live climb must NOT advance the poll-cycle generation")
            #expect(
                b.isPairedForTesting,
                "prior \(priorState): a not-live climb must NOT clear the auth key")
        }
    }

    // MARK: - a dead link is never re-armed for polling

    /// Drive the REAL `perform` delivery flow (behind `FakePumpTransport`, no CoreBluetooth) to its
    /// "connection lost during delivery" INDETERMINATE throw by flipping the link off `.bolusing` mid-poll
    /// (mirrors `TandemDeliveryOutcomeTests.acceptedThenDisconnectMidDeliveryIsIndeterminate`, but via a
    /// REAL drop transition so the same teardown a live drop runs is exercised). The `perform` `defer` must
    /// then NOT re-arm routine polling: `pollTimerIsActiveForTesting == false` afterward. Pre-fix, the
    /// defer called `startPolling()` unconditionally, arming a fresh `pollTimer` on the dead link.
    @Test func connectionLostDuringDeliveryDoesNotReArmPolling() async {
        let fake = FakePumpTransport()
        let b = TandemBackend(testTransport: fake)
        b.deliveryPollTimeoutOverride = 1.2  // keep the poll window short for the test
        // Time-sync + permission succeed; the initiate is accepted; the first status poll reports active.
        fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        fake.script(BolusPermissionResponse.props.opCode, .frame(FakePumpTransport.permissionGranted(bolusId: bolusId)))
        fake.script(InitiateBolusResponse.props.opCode, .frame(FakePumpTransport.initiateAccepted(bolusId: bolusId)))
        fake.script(
            CurrentBolusStatusResponse.props.opCode,
            .frame(FakePumpTransport.currentBolusStatus(statusId: 1, bolusId: bolusId)))  // active
        // The mid-delivery drop: when the first status poll is awaited, run the REAL `.disconnected`
        // transition (→ `linkDroppedCleanup()` → `stopAllTimers()`), so the poll loop's next
        // `guard connection == .bolusing` fails and throws "connection lost during delivery".
        fake.willAwait = { [weak b] op in
            if op == CurrentBolusStatusResponse.props.opCode { b?.applyClientState(.disconnected) }
        }

        let e = await capture { try await b.deliverBolus(units: 2.0, carbsGrams: nil, bgMgdl: nil, iobUnits: nil) }

        #expect(isIndeterminate(e), "a mid-delivery link drop is an indeterminate outcome")
        #expect(b.deliveryOutcomeUnknown, "the indeterminate delivery holds the global block")
        // WR-04: the exit defer re-arms polling ONLY on a live link. The link is down, so nothing re-arms.
        #expect(
            b.pollTimerIsActiveForTesting == false,
            "WR-04: the perform defer must NOT re-arm a fresh poll timer on a dead link")
    }

    // MARK: - WR-04 part 2 / CR-01: shared teardown stops the predictive machinery on a drop

    /// The predictive-burst path is the highest-risk timer to leak past a drop because it REPEATS. Arm it
    /// the real way (an advancing EGV reading schedules the burst deadline AND the repeating predictive
    /// timer), confirm it dispatches while connected, then drop the link. `linkDroppedCleanup()`'s
    /// `stopAllTimers()` must tear down BOTH timers, and the predictive path must be inert afterward: a
    /// post-drop kick dispatches NO read into the dead link (its `isConnected()` stop-condition). The
    /// `predictiveBurstDeadline` MARKER is intentionally left set by `stopAllTimers()` (only the timer that
    /// reads it is invalidated), so this pins the behavior, not the marker.
    @Test func linkDropStopsPredictivePollingSoItCannotFireIntoADeadLink() {
        let b = backend()
        b.setConnectionForTesting(.connected)
        // Arm a live recurring poll timer too, so the drop has both timers to tear down.
        b.startPollingLeavingPollTimerRunningForTesting()
        #expect(b.pollTimerIsActiveForTesting, "precondition: the recurring poll timer is armed")
        // Arm the predictive burst the real way: an EGV reading whose pump timestamp advances (0 → 1000)
        // runs `schedulePredictiveBurst`, setting the deadline and arming the repeating predictive timer.
        b.injectStatusFrameForTesting(Self.egvV1Frame(pumpSec: 1000, mgdl: 120))
        #expect(b.predictiveBurstDeadlineForTesting != nil, "an advancing EGV reading must arm the predictive burst")

        // Sanity: while connected, the predictive kick dispatches its EGV read (the path is live).
        var dispatched: [UInt8] = []
        b.onReadDispatchedForTesting = { _, opcode in dispatched.append(opcode) }
        b.simulatePredictiveBurstForTesting()
        #expect(dispatched.contains(34), "while connected the predictive burst dispatches its V1 EGV read (op34)")

        // The drop: `.disconnected` runs `linkDroppedCleanup()` → `stopAllTimers()`, invalidating BOTH
        // the recurring pollTimer AND the predictive timer (WR-04 part 2).
        b.applyClientState(.disconnected)
        #expect(b.snapshot.connection == .disconnected)
        #expect(
            b.pollTimerIsActiveForTesting == false, "stopAllTimers() must tear down the recurring poll timer on a drop")

        // The predictive path is now inert: a kick after the drop dispatches nothing into the dead link.
        dispatched.removeAll()
        b.simulatePredictiveBurstForTesting()
        #expect(dispatched.isEmpty, "after a drop the predictive burst must not dispatch reads into a dead link")
    }
}
