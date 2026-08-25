import Testing
import Foundation
import TandemBLE
@testable import faBolus

/// `.planning/debug/pump-pairing-loop.md` instrumentation cycle: the app-side os.Logger channel
/// itself isn't interceptable from a unit test (unified logging is process/OS-owned), so this pins
/// the underlying, testable fact the log line reports — that beginning a V1 (16-char code) pairing
/// flow sends exactly one first message, and that message is `CentralChallengeRequest` (op 16) —
/// via `TandemBackend.onPairingSendForTesting`, the DEBUG-only test seam that fires with the same
/// non-PHI facts (type name / opcode / cargo byte count) the log call emits.
@Suite(.serialized) @MainActor
struct PumpPairingInstrumentationTests {
    private func backend() -> TandemBackend { TandemBackend(testTransport: FakePumpTransport()) }

    @Test func beginningV1PairingSendsCentralChallengeRequestFirst() {
        let b = backend()
        var sends: [(typeName: String, opcode: UInt8, cargoBytes: Int)] = []
        b.onPairingSendForTesting = { typeName, opcode, cargoBytes in
            sends.append((typeName, opcode, cargoBytes))
        }
        b.beginPairingForTesting(code: "abcd1234ijkl5678")   // valid 16-char → legacy V1
        #expect(sends.count == 1)
        #expect(sends.first?.typeName == "CentralChallengeRequest")
        #expect(sends.first?.opcode == 16)
        // Never asserts on payload bytes (PHI: `centralChallenge`) — only the non-sensitive count.
        #expect((sends.first?.cargoBytes ?? -1) > 0)
    }

    @Test func beginningJpakePairingSendsJpake1aFirst() {
        let b = backend()
        var sends: [(typeName: String, opcode: UInt8, cargoBytes: Int)] = []
        b.onPairingSendForTesting = { typeName, opcode, cargoBytes in
            sends.append((typeName, opcode, cargoBytes))
        }
        b.beginPairingForTesting(code: "123456")   // valid 6-digit → JPAKE
        #expect(sends.count == 1)
        #expect(sends.first?.typeName == "Jpake1aRequest")
    }
}

/// `.planning/debug/pump-pairing-loop.md` THIRD fix cycle — a THIRD on-device capture showed the pump
/// drop the link ~315ms after the very FIRST post-settle READ (`ControlIQIOBRequest`, op108 —
/// `fastRead()`'s first message), refuting settle-TIMING as a sufficient fix on its own. Grounded
/// directly in the vendored jwoglom/pumpX2 reference (`TandemPump.java#onPumpConnected`, the base class
/// every known Android consumer of the library relies on unmodified — see the "MARK: - Post-pair
/// bootstrap order" comment in TandemBackend.swift for the full citation trail): the reference ALWAYS
/// sends `ApiVersionRequest` → `PumpVersionRequest` → `TimeSinceResetRequest`, in that exact order, as the
/// FIRST GATT traffic issued the instant authentication succeeds — before any other current-status
/// polling. These tests assert `startPolling()` now reproduces that exact order. Reads are sent directly
/// (no app-level queue/pacing — see `sendStatusRead`'s doc comment in `TandemBackend.swift`), so the
/// dispatch order and count are observable synchronously with no wall-clock wait.
@Suite(.serialized) @MainActor
struct PumpPairingPostPairBootstrapOrderTests {
    private func backend() -> TandemBackend { TandemBackend(testTransport: FakePumpTransport()) }

    /// The core regression this cycle fixes: the FIRST three reads dispatched by `startPolling()` must
    /// be the reference's bootstrap trio, in the reference's exact order — not `fastRead()`'s
    /// `ControlIQIOBRequest` (op108), which is what capture #3 showed being sent (and immediately
    /// preceding the drop) instead.
    @Test func startPollingSendsTheReferenceRequiredBootstrapTrioBeforeAnyOtherRead() {
        let b = backend()
        var dispatched: [(typeName: String, opcode: UInt8)] = []
        b.onReadDispatchedForTesting = { typeName, opcode in dispatched.append((typeName, opcode)) }
        b.startPollingForTesting()
        // api25 static-registry hardening: op20 LoadStatusRequest is IDENTITY-GATED — deferred out of the
        // pre-version burst (dispatched only after the op33/op85 version responses identify the pump), so the
        // synchronous burst is 16 (trio 3 + fastRead's 6 non-gated + staticRead 7), not 17.
        #expect(dispatched.count == 16)
        #expect(dispatched.prefix(3).map(\.typeName) == ["ApiVersionRequest", "PumpVersionRequest", "TimeSinceResetRequest"],
                "the reference-required bootstrap trio must be dispatched first, in this exact order")
        #expect(dispatched.prefix(3).map(\.opcode) == [32, 84, 54])
        #expect(dispatched[3].typeName == "ControlIQIOBRequest",
                "fastRead()'s CURRENT_STATUS reads must follow the bootstrap trio, not precede it — capture #3's exact failure mode")
        #expect(!dispatched.contains { $0.typeName == "LoadStatusRequest" },
                "op20 LoadStatusRequest is identity-gated — it must NOT be in the pre-version burst")
    }

    /// The recurring `pollTimer` tick (`fastRead()`/`staticRead()` called directly, bypassing
    /// `startPolling()`) must NOT re-send the bootstrap trio — the reference sends it exactly once, the
    /// instant `onPumpConnected` fires, never again on a recurring poll.
    @Test func recurringPollTickDoesNotResendTheBootstrapTrio() {
        let b = backend()
        var dispatched: [(typeName: String, opcode: UInt8)] = []
        b.onReadDispatchedForTesting = { typeName, opcode in dispatched.append((typeName, opcode)) }
        b.simulateRecurringFastAndStaticReadTickForTesting()
        #expect(dispatched.count == 14)   // api25 refinement: op20 LoadStatusRequest RESTORED to fastRead() (back to 14)
        #expect(dispatched.first?.typeName == "ControlIQIOBRequest",
                "a recurring tick starts directly with fastRead()'s own first message — no bootstrap prepend")
    }
}

/// `.planning/debug/pump-pairing-loop.md` FIFTH fix cycle — direct analysis of an on-device capture's
/// raw app log (not just its summarized Evidence text) found the FOURTH cycle's "bootstrap trio is
/// always first" invariant was silently violated in roughly half of the captured post-pair cycles:
/// `AlertStatusRequest`/`AlarmStatusRequest`/`CGMAlertStatusRequest` (`alertRead()`'s messages) were
/// dispatched BEFORE `ApiVersionRequest`, even though `startPolling()` itself unconditionally calls
/// `sendPostPairBootstrapReads()` first. Root cause, confirmed against the captured timestamps (see
/// `TandemBackend.scheduleAlertRead()`'s doc comment for the full citation): `pollTimer` (armed by
/// `startPolling()`, 15s repeating) was never invalidated on disconnect, so a cycle that dropped in
/// well under 15s left its `pollTimer` ticking through the ENTIRE reconnect gap; its first tick landed
/// inside a LATER cycle's post-pair window and called `scheduleAlertRead()` again — which had no
/// staleness guard at all — injecting `alertRead()`'s 5 messages onto the queue ahead of the new
/// cycle's own bootstrap trio. Two-part fix: `scheduleAlertRead()` now captures+rechecks
/// `pollCycleGeneration` (bumped once per `startPolling()` call), and `linkDroppedCleanup()` now
/// invalidates `pollTimer` the instant the link is confirmed down. This does NOT change any default
/// timing constant — `alertReadDelaySecForTesting`/`startPollingLeavingPollTimerRunningForTesting` are
/// pure test seams so these two mechanisms are directly, deterministically testable without a live BLE
/// connection or waiting out the real 15s pollTimer / 1.5s alert-read delay.
@Suite(.serialized) @MainActor
struct PumpPairingStaleTimerGuardTests {
    private func backend() -> TandemBackend { TandemBackend(testTransport: FakePumpTransport()) }

    /// The core regression this cycle fixes: a `scheduleAlertRead()` call armed under an OLDER
    /// `pollCycleGeneration` (simulating a stale `pollTimer` tick surviving into a later cycle) must
    /// never enqueue `alertRead()`'s messages once a NEWER `startPolling()` has restarted the cycle —
    /// it must stay silently stale.
    @Test func staleScheduledAlertReadFromASupersededCycleNeverFiresIntoTheNewerCycle() async {
        let b = backend()
        b.alertReadDelaySecForTesting = 0.05
        var dispatched: [(typeName: String, opcode: UInt8)] = []
        b.onReadDispatchedForTesting = { typeName, opcode in dispatched.append((typeName, opcode)) }
        b.startPollingForTesting()   // cycle 1: pollCycleGeneration = G1; dispatches its own 16 reads
                                      // synchronously; schedules alertRead() @ +0.05s under G1
        dispatched.removeAll()       // only care about what's dispatched from cycle 2 on
        b.startPollingForTesting()   // cycle 2 (reconnect + re-pair): bumps pollCycleGeneration to G2
                                      // BEFORE cycle 1's still-pending +0.05s alertRead call can fire;
                                      // dispatches its own 16 reads synchronously right here
        // ≫ cycle 1's stale 0.05s deadline (must no-op) + cycle 2's own LEGITIMATE scheduleAlertRead
        // (armed at cycle 2's startPolling(), firing +0.05s later) + its own 5-message dispatch.
        try? await Task.sleep(nanoseconds: 200_000_000)
        // Exactly cycle 2's own 16 (bootstrap trio + fastRead's 6 non-gated [op20 identity-gated, api25
        // static-registry hardening — deferred out of the pre-version burst] + staticRead, all synchronous) +
        // 7 (its own legitimate alertRead — CC-10 grew this tier 5->7 with the 2 AAM requests) = 23. A
        // missing/broken guard would add cycle 1's stale extra 7 → 30.
        #expect(dispatched.count == 23,
                "cycle 2's own 23 reads only — a missing guard would let cycle 1's stale alertRead add 7 more (30)")
        #expect(dispatched.prefix(3).map(\.typeName) == ["ApiVersionRequest", "PumpVersionRequest", "TimeSinceResetRequest"],
                "cycle 2's bootstrap trio must still be dispatched FIRST — a stale cycle-1 alertRead landing before cycle 2's own startPolling() runs would corrupt this order, exactly matching the AlertStatusRequest-before-ApiVersionRequest corruption observed in on-device capture #4")
    }

    /// The other half of the fix: `pollTimer` (the ultimate SOURCE of repeated stale `scheduleAlertRead`
    /// calls once it starts ticking) must be invalidated the instant the link is confirmed down — not
    /// left running to fire a tick into a future, unrelated connection cycle.
    @Test func linkDroppedCleanupInvalidatesAStillRunningPollTimer() {
        let b = backend()
        b.startPollingLeavingPollTimerRunningForTesting()
        #expect(b.pollTimerIsActiveForTesting, "startPolling() should have armed a live pollTimer")
        b.applyClientState(.disconnected)
        #expect(!b.pollTimerIsActiveForTesting,
                "linkDroppedCleanup() must invalidate pollTimer the instant the link is confirmed down, so a stale tick can never fire into a later, unrelated connection cycle")
    }
}

/// `.planning/debug/pump-pairing-loop.md` SEVENTH fix cycle — the DEFINITIVE root cause. On-device
/// capture #6 caught the pump answering every post-pair status read correctly and then rejecting
/// exactly one:
///
///     op32 ApiVersion → recv op33 ✓ | op84 PumpVersion → recv op85 ✓ | op54 TimeSinceReset → recv op55 ✓
///     | op108 ControlIQIOB → recv op109 ✓ | op192 CurrentEgvGuiDataV2Request → recv op77 → disconnect code=7
///
/// op77 is `ErrorResponse` (BAD_OPCODE): the pump (`Software: 2.5`, an older t:slim X2) does not support
/// the V2 EGV GUI-data request, and tears the whole link down ~70ms after rejecting it. `fastRead()` sent
/// op192 unconditionally on every post-pair poll, so this re-fired on every reconnect — the loop.
///
/// The fix: the app now sends ONLY `CurrentEGVGuiDataRequest` (V1, op34) for every EGV read — never the
/// V2 request (op192) — see `fastRead()`'s doc comment in `TandemBackend.swift` for the full reference
/// evidence (`CurrentEgvGuiDataV2Request`/`Response` both declare `minApi=KnownApiVersion.API_FUTURE`,
/// higher than every cataloged real firmware version; the reference never sends V2 anywhere itself; its
/// own automatic qualifying-event re-fetch uses V1 exclusively) plus the owner's on-device confirmation
/// that V1 holds the link on the affected pump. An EARLIER version of this fix instead gated V2-vs-V1 by
/// a `>= 3` major-API-version guess; that guess was never reference- or on-device-confirmed (no known
/// pump has ever been shown to accept op192), so it was replaced by always using V1 — simpler, and the
/// only behavior actually verified safe. The opcode-agnostic `badOpcodes` BACKSTOP (populated from any
/// inbound `ErrorResponse`) stays regardless, as a safety net for any OTHER read the pump ever rejects.
@Suite(.serialized) @MainActor
struct PumpEgvPollTests {
    private func backend() -> TandemBackend { TandemBackend(testTransport: FakePumpTransport()) }

    /// Reads are dispatched via `client.send` (the real `PumpBLEClient`), which always throws in a unit
    /// test — there is no live `CBCentralManager` — so the injected `FakePumpTransport` never sees them.
    /// The `onReadDispatchedForTesting` seam is the observation point. Sends are synchronous (no
    /// queue/pacing), so no wall-clock wait is needed.
    private func dispatchedOpcodes(_ b: TandemBackend) -> [UInt8] {
        var dispatched: [UInt8] = []
        b.onReadDispatchedForTesting = { _, opcode in dispatched.append(opcode) }
        b.startPollingForTesting()
        return dispatched
    }

    /// The core regression: the post-pair poll must NEVER put op192 on the wire — only V1's op34 — on
    /// any pump (there is no more version branching; see the type doc above).
    @Test func pollingNeverSendsTheV2EgvRequestAndAlwaysSendsV1() {
        let b = backend()
        let ops = dispatchedOpcodes(b)
        #expect(!ops.isEmpty, "the poll must actually have run")
        #expect(!ops.contains(192), "op192 must never be sent — it answers BAD_OPCODE and drops the link")
        #expect(ops.contains(34), "the V1 CurrentEGVGuiDataRequest must be sent in its place")
    }

    // MARK: - The opcode-agnostic backstop

    /// An inbound `ErrorResponse` records the rejected opcode, and that opcode is then never sent again
    /// — converting "pump rejects X → link torn down → reconnect → send X again" into a single logged,
    /// never-repeated exchange, for ANY opcode, not just op192.
    @Test func aRejectedOpcodeIsNeverSentAgain() {
        let b = backend()
        b.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 34))
        #expect(b.badOpcodesForTesting.contains(34))
        var skipped: [UInt8] = []
        b.onReadSkippedForTesting = { _, opcode in skipped.append(opcode) }
        let ops = dispatchedOpcodes(b)
        #expect(!ops.contains(34), "...an explicit pump rejection must be honoured")
        #expect(skipped.contains(34))
    }

    /// The backstop must be surgical: rejecting one opcode must not suppress any other read.
    @Test func rejectingOneOpcodeDoesNotSuppressOthers() {
        let b = backend()
        b.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 34))
        let ops = dispatchedOpcodes(b)
        #expect(ops.contains(32), "ApiVersionRequest must still be sent")
        #expect(ops.contains(84), "PumpVersionRequest must still be sent")
        #expect(ops.contains(54), "TimeSinceResetRequest must still be sent")
        #expect(ops.contains(108), "ControlIQIOBRequest must still be sent")
    }

    /// A proven-bad opcode must SURVIVE a reconnect to the same pump — re-learning it every cycle would
    /// reproduce one link-dropping exchange on every single reconnect, which is the loop itself.
    @Test func aRejectedOpcodeSurvivesAReconnect() {
        let b = backend()
        b.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 34))
        b.applyClientState(.disconnected)
        #expect(b.badOpcodesForTesting.contains(34),
                "an opcode already proven unsupported by this pump stays proven across a reconnect")
    }

    // MARK: - The three direct (non-polling-burst) EGV send sites

    /// GAP found on resume: `refreshGlucoseNow()` used to send its EGV read directly, bypassing whatever
    /// protection the poll path had. It now goes through the same `sendStatusRead` path (V1, never V2)
    /// as the ordinary poll.
    @Test func manualGlucoseRefreshUsesV1() async {
        let b = TandemBackend(testTransport: FakePumpTransport())
        b.setConnectionForTesting(.connected)
        var dispatched: [UInt8] = []
        b.onReadDispatchedForTesting = { _, opcode in dispatched.append(opcode) }
        await b.refreshGlucoseNow()
        #expect(!dispatched.contains(192), "a manual glucose refresh must never send op192")
        #expect(dispatched.contains(34), "it must send the V1 request")
    }

    /// The same for the predictive-burst kick — the highest-risk of the three direct sites because it
    /// REPEATS on a timer, so a regression here would re-trigger the teardown on every tick.
    @Test func predictiveBurstUsesV1() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        b.setConnectionForTesting(.connected)
        var dispatched: [UInt8] = []
        b.onReadDispatchedForTesting = { _, opcode in dispatched.append(opcode) }
        b.simulatePredictiveBurstForTesting()
        #expect(!dispatched.contains(192))
        #expect(dispatched.contains(34))
    }

    /// The direct sites honour the `badOpcodes` backstop too, not just the ordinary poll path.
    @Test func directSendsAlsoHonourTheRejectedOpcodeBackstop() async {
        let b = TandemBackend(testTransport: FakePumpTransport())
        b.setConnectionForTesting(.connected)
        b.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 34))
        var dispatched: [UInt8] = []
        var skipped: [UInt8] = []
        b.onReadDispatchedForTesting = { _, opcode in dispatched.append(opcode) }
        b.onReadSkippedForTesting = { _, opcode in skipped.append(opcode) }
        await b.refreshGlucoseNow()
        b.simulatePredictiveBurstForTesting()
        #expect(!dispatched.contains(34))
        #expect(skipped.filter { $0 == 34 }.count == 2, "both direct sites must consult the backstop")
    }

    /// When the EGV read cannot go out at all, `refreshGlucoseNow()` must release its coalesced waiters
    /// immediately rather than stalling every caller for the full 2.5s safety timeout.
    @Test func manualRefreshDoesNotStallWhenTheReadCannotBeSent() async {
        let b = TandemBackend(testTransport: FakePumpTransport())
        b.setConnectionForTesting(.connected)
        b.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 34))
        let start = Date()
        await b.refreshGlucoseNow()
        #expect(Date().timeIntervalSince(start) < 1.0, "must not wait out the 2.5s timeout")
    }
}

/// `.planning/debug/pump-pairing-loop.md` SEVENTH fix cycle, second half — now that the app always
/// sends the V1 EGV request (`fastRead()`'s doc comment in `TandemBackend.swift`), the V1 RESPONSE has
/// to actually be consumed.
///
/// GAP found on resume: `CurrentEGVGuiDataResponse` (op35) is registered in the kit's `ResponseParser`,
/// so it decodes and reaches `TandemBackend`'s response switch — which had no case for it, so it fell
/// through to `default: break`. Shipping the V1 switch without this would have traded the connection
/// loop for a SILENT one: the link holds, but CGM data never appears.
///
/// Trend-arrow correctness for the V1 decode (which read `trendRate` UNSIGNED, so every FALLING trend
/// would have rendered as RAPIDLY RISING) is pinned at the message level in TandemKit's
/// `TrendProvenanceTests.v1TrendRateIsSigned` / `.v1MatchesV2ForEveryBandAndSentinel`; the app-level
/// derived-arrow fallback is gated behind `snapshot.trend.isEmpty`, which a cold-start snapshot
/// (defaulting to `GlucoseTrend.flat`) never satisfies, so it is not assertable from here.
@Suite(.serialized) @MainActor
struct PumpV1EgvResponseTests {
    private func backend() -> TandemBackend { TandemBackend(testTransport: FakePumpTransport()) }

    /// The V1 response must populate the same snapshot fields the V2 one does — before this case
    /// existed it hit `default: break` and every reading was silently dropped.
    @Test func v1EgvResponseUpdatesTheGlucoseSnapshot() {
        let b = backend()
        #expect(b.snapshot.glucose == nil)
        b.injectStatusFrameForTesting(FakePumpTransport.currentEgvV1(mgdl: 137, trendRate: 0))
        #expect(b.snapshot.glucose == 137)       // the value still lands on the snapshot
        #expect(b.snapshot.cgmActive)
        // VA-01: this fixture carries NO reading timestamp (pumpSec == 0) and no pump↔phone clock anchor was
        // established, so the reading time is untrustworthy. It must FAIL CLOSED — `glucoseDate` stays nil
        // (never stamped as `now`, which the shared GlucoseFreshness policy would read as fresh) and the
        // value is NOT promoted into the plot history (an untrusted time must not seed a point that later
        // gets promoted to the live snapshot). A trusted-timestamp reading is covered by
        // ReadCascadeChainingGuardTests.trustedReadingTimeSetsGlucoseDateAndPromotesToHistory.
        #expect(b.snapshot.glucoseDate == nil)
        #expect(b.glucoseHistory.last == nil, "a timestamp-less reading must not reach the plot history")
    }

    /// V1 and V2 must be indistinguishable downstream — the pump's firmware generation must not change
    /// what the user sees for the same reading.
    @Test func v1AndV2ProduceTheSameSnapshot() {
        for rate in [-30, -15, 0, 15, 30] {
            let v1 = backend()
            v1.injectStatusFrameForTesting(FakePumpTransport.currentEgvV1(mgdl: 92, trendRate: rate))
            let v2 = backend()
            v2.injectStatusFrameForTesting(FakePumpTransport.currentEgvV2(mgdl: 92, trendRate: rate))
            #expect(v1.snapshot.glucose == v2.snapshot.glucose, "rate \(rate)")
            #expect(v1.snapshot.cgmActive == v2.snapshot.cgmActive, "rate \(rate)")
            #expect(v1.snapshot.trend == v2.snapshot.trend, "rate \(rate)")
            #expect(v1.glucoseHistory.last?.mgdl == v2.glucoseHistory.last?.mgdl, "rate \(rate)")
        }
    }

    /// An INVALID V1 frame must not be treated as a reading, exactly as for V2.
    @Test func v1InvalidFrameDoesNotProduceAReading() {
        let b = backend()
        var cargo = [UInt8](repeating: 0, count: 8)
        cargo[4] = 120; cargo[6] = 0    // egvStatusId 0 = INVALID
        b.injectStatusFrameForTesting(
            FakePumpTransport.frame(opCode: 35, cargo: cargo, signed: false))
        #expect(!b.snapshot.cgmActive)
        #expect(b.snapshot.glucose == nil)
    }
}
