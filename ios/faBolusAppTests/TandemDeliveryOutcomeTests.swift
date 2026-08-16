import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// Round-3 §4: the REAL `TandemBackend.perform` delivery flow, behind the deterministic `FakePumpTransport`
/// (no CoreBluetooth). Proves the state machine never fabricates a terminal result after the initiate is
/// written: only a matching authoritative pump status settles delivered; every other exit is indeterminate
/// (leaving the durable ledger unresolved) and a partial reports the authoritative amount — never the
/// requested units.
@Suite(.serialized) @MainActor
struct TandemDeliveryOutcomeTests {

    private let bolusId = 1234
    private let initiateOp = InitiateBolusResponse.props.opCode
    private let statusOp = CurrentBolusStatusResponse.props.opCode
    private let lastOp = LastBolusStatusV2Response.props.opCode

    /// A backend whose time-sync + permission already succeed; the caller scripts the initiate/poll phase.
    private func make(poll: TimeInterval = 1.2) -> (TandemBackend, FakePumpTransport) {
        let fake = FakePumpTransport()
        let backend = TandemBackend(testTransport: fake)
        backend.deliveryPollTimeoutOverride = poll
        fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        fake.script(BolusPermissionResponse.props.opCode, .frame(FakePumpTransport.permissionGranted(bolusId: bolusId)))
        return (backend, fake)
    }
    private func deliver(_ b: TandemBackend, _ u: Double = 2.0) async throws -> Double {
        try await b.deliverBolus(units: u, carbsGrams: nil, bgMgdl: nil, iobUnits: nil)
    }
    /// Like `make()` but leaves the permission response unscripted, so a test can script a specific
    /// permission nack (`make()` pre-scripts an auto-grant, which a later `.script(...)` call would only
    /// queue BEHIND — never replace).
    private func makeAwaitingPermission(poll: TimeInterval = 1.2) -> (TandemBackend, FakePumpTransport) {
        let fake = FakePumpTransport()
        let backend = TandemBackend(testTransport: fake)
        backend.deliveryPollTimeoutOverride = poll
        fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        return (backend, fake)
    }
    private func indeterminate(_ e: Error?) -> Bool { (e as? BolusError)?.isIndeterminate ?? false }
    private func capture(_ op: () async throws -> Double) async -> Error? {
        do { _ = try await op(); return nil } catch { return error }
    }

    // MARK: pre-write vs post-write

    @Test func preWriteInitiateFailureIsCleanAndWritesNothing() async {
        let (b, fake) = make()
        fake.preWriteError[InitiateBolusRequest.props.opCode] = BolusError.pumpRejected("blocked pre-write")
        let e = await capture { try await deliver(b) }
        #expect(e != nil && !indeterminate(e))            // clean, retryable — NOT indeterminate
        #expect(fake.initiateWriteCount == 0)             // nothing went out
        #expect(!b.deliveryOutcomeUnknown)                // no block
    }

    @Test func droppedInitiateResponseIsIndeterminate() async {
        let (b, fake) = make()
        fake.script(initiateOp, .tx(.timedOut(characteristic: .control, opCode: initiateOp)))
        let e = await capture { try await deliver(b) }
        #expect(indeterminate(e))
        #expect(fake.initiateWriteCount == 1)             // the write went out
        #expect(b.deliveryOutcomeUnknown)                 // globally blocked
    }

    @Test func malformedInitiateResponseIsIndeterminate() async {
        let (b, fake) = make()
        fake.script(initiateOp, .garbage)
        let e = await capture { try await deliver(b) }
        #expect(indeterminate(e))
        #expect(b.deliveryOutcomeUnknown)
    }

    @Test func explicitInitiateNackIsCleanFailureNotIndeterminate() async {
        let (b, fake) = make()
        fake.script(initiateOp, .frame(FakePumpTransport.initiateNack(bolusId: bolusId)))
        let e = await capture { try await deliver(b) }
        #expect(e != nil && !indeterminate(e))            // authoritative NACK → clean failed
        #expect(!b.deliveryOutcomeUnknown)                // not blocked
    }

    // MARK: accepted, but no authoritative terminal

    @Test func acceptedThenStatusDropsIsIndeterminateAtDeadline() async {
        let (b, fake) = make(poll: 1.0)
        fake.script(initiateOp, .frame(FakePumpTransport.initiateAccepted(bolusId: bolusId)))
        // currentBolusStatus never answers (default drop) → deadline → indeterminate.
        let e = await capture { try await deliver(b) }
        #expect(indeterminate(e))
        #expect(b.deliveryOutcomeUnknown)
    }

    @Test func acceptedThenStatusIdMismatchIsIndeterminate() async {
        let (b, fake) = make()
        fake.script(initiateOp, .frame(FakePumpTransport.initiateAccepted(bolusId: bolusId)))
        fake.script(statusOp, .frame(FakePumpTransport.currentBolusStatus(statusId: 1, bolusId: 9999)))
        let e = await capture { try await deliver(b) }
        #expect(indeterminate(e))
    }

    @Test func acceptedThenDisconnectMidDeliveryIsIndeterminate() async {
        let (b, fake) = make()
        fake.script(initiateOp, .frame(FakePumpTransport.initiateAccepted(bolusId: bolusId)))
        fake.script(statusOp, .frame(FakePumpTransport.currentBolusStatus(statusId: 1, bolusId: bolusId)),   // active
                              .frame(FakePumpTransport.currentBolusStatus(statusId: 1, bolusId: bolusId)))
        fake.willAwait = { [weak b] op in if op == self.statusOp { b?.setConnectionForTesting(.disconnected) } }
        let e = await capture { try await deliver(b) }
        #expect(indeterminate(e))
        #expect(b.deliveryOutcomeUnknown)
    }

    @Test func acceptedCompleteButFinalStatusDropsIsIndeterminate() async {
        let (b, fake) = make()
        fake.script(initiateOp, .frame(FakePumpTransport.initiateAccepted(bolusId: bolusId)))
        fake.script(statusOp, .frame(FakePumpTransport.currentBolusStatus(statusId: 0, bolusId: bolusId)))  // done
        // lastBolus (default) drops → no authoritative delivered → indeterminate.
        let e = await capture { try await deliver(b) }
        #expect(indeterminate(e))
    }

    // MARK: authoritative terminal — the ONLY paths that settle delivered

    @Test func matchingFullCompletionDeliversExactUnits() async throws {
        let (b, fake) = make()
        fake.script(initiateOp, .frame(FakePumpTransport.initiateAccepted(bolusId: bolusId)))
        fake.script(statusOp, .frame(FakePumpTransport.currentBolusStatus(statusId: 0, bolusId: bolusId)))
        fake.script(lastOp, .frame(FakePumpTransport.lastBolus(bolusId: bolusId, deliveredMilliunits: 2000)))
        let delivered = try await deliver(b, 2.0)
        #expect(delivered == 2.0)
        #expect(!b.deliveryOutcomeUnknown)
    }

    /// A partial completion reports the AUTHORITATIVE delivered amount (1.0), never the requested 2.0, and
    /// does NOT fabricate a cancellation flag (round-3 §4 — the exact old-code bug).
    @Test func matchingPartialCompletionReportsAuthoritativeAmountNotRequested() async throws {
        let (b, fake) = make()
        fake.script(initiateOp, .frame(FakePumpTransport.initiateAccepted(bolusId: bolusId)))
        fake.script(statusOp, .frame(FakePumpTransport.currentBolusStatus(statusId: 0, bolusId: bolusId)))
        fake.script(lastOp, .frame(FakePumpTransport.lastBolus(bolusId: bolusId, deliveredMilliunits: 1000)))
        let delivered = try await deliver(b, 2.0)
        #expect(delivered == 1.0)                 // authoritative, not the requested 2.0
        #expect(b.lastBolusCancelled == false)    // never invents a cancellation
    }

    @Test func finalStatusIdMismatchIsIndeterminate() async {
        let (b, fake) = make()
        fake.script(initiateOp, .frame(FakePumpTransport.initiateAccepted(bolusId: bolusId)))
        fake.script(statusOp, .frame(FakePumpTransport.currentBolusStatus(statusId: 0, bolusId: bolusId)))
        fake.script(lastOp, .frame(FakePumpTransport.lastBolus(bolusId: 9999, deliveredMilliunits: 2000)))
        let e = await capture { try await deliver(b) }
        #expect(indeterminate(e))
    }

    // MARK: R3-H — frozen metadata via the seam

    /// The InitiateBolus cargo actually WRITTEN to the wire encodes exactly the approved inputs — dose,
    /// carbs, BG, and the **frozen** calculator IOB — byte-for-byte. This proves reconciliation compares
    /// against what was truly sent, not a later recompute, and that the frozen IOB (not a live snapshot) is
    /// what reaches the pump. The transport seam (`FakePumpTransport.sent`) is the source of the sent bytes.
    @Test func sentInitiateCargoFreezesTheApprovedInputs() async throws {
        let (b, fake) = make()
        fake.script(initiateOp, .frame(FakePumpTransport.initiateAccepted(bolusId: bolusId)))
        fake.script(statusOp, .frame(FakePumpTransport.currentBolusStatus(statusId: 0, bolusId: bolusId)))
        fake.script(lastOp, .frame(FakePumpTransport.lastBolus(bolusId: bolusId, deliveredMilliunits: 2000)))
        let delivered = try await b.deliverBolus(units: 2.0, carbsGrams: 45, bgMgdl: 180, iobUnits: 0.5)
        #expect(delivered == 2.0)

        // The bytes that went out must equal what the approved inputs canonically encode to: whole 2.0 U in
        // foodVolume, FOOD1 (carbs present), frozen IOB 0.5 U → 500 mu, carbs 45, BG 180.
        let sent = try #require(fake.lastSent(InitiateBolusRequest.props.opCode))
        #expect(sent.allowDelivery)   // the initiate is the one delivery-authorized write
        let expected = try InitiateBolusRequest(
            validating: 2000, bolusID: bolusId, bolusTypeBitmask: InitiateBolusRequest.bitFood1,
            foodVolume: 2000, correctionVolume: 0, bolusCarbs: 45, bolusBG: 180, bolusIOB: 500)
        #expect(sent.cargo == expected.cargo)
    }

    // MARK: racing cancel — the four "required deterministic tests" cancel rows (round-3 handoff)

    /// Issue a cancel the first time the pump status is polled — i.e. while the bolus is genuinely in
    /// flight, exactly as a user tapping Cancel mid-delivery would. `willAwait` is synchronous, so the
    /// async `cancelBolus()` rides a Task that runs during the poll's inter-status sleep (the poll runs
    /// for ~1 s with 0.5 s gaps, so the cancel write lands before the outcome is read).
    private func cancelOnFirstPoll(_ b: TandemBackend, _ fake: FakePumpTransport) {
        fake.willAwait = { [weak b] op in
            if op == self.statusOp { Task { @MainActor in await b?.cancelBolus() } }
        }
    }
    private var cancelOp: UInt8 { CancelBolusRequest.props.opCode }

    /// These pin the deliberate round-3 design: the live path carries NO verified pump-cancellation
    /// semantics (a booked bench follow-up — `TandemKit/PINNED.md`), so `lastBolusCancelled` is never set
    /// true. A cancel racing completion must therefore NEVER fabricate a terminal and NEVER invent a
    /// "cancelled" label: the reported outcome is the pump's AUTHORITATIVE delivered amount, or indeterminate.

    /// Full dose completes despite a mid-delivery cancel → delivered (authoritative full), not cancelled.
    @Test func cancelRacingFullCompletionReportsDeliveredNotCancelled() async throws {
        let (b, fake) = make()
        fake.script(initiateOp, .frame(FakePumpTransport.initiateAccepted(bolusId: bolusId)))
        fake.script(statusOp, .frame(FakePumpTransport.currentBolusStatus(statusId: 1, bolusId: bolusId)),   // active — cancel fires here
                              .frame(FakePumpTransport.currentBolusStatus(statusId: 0, bolusId: bolusId)))   // done
        fake.script(lastOp, .frame(FakePumpTransport.lastBolus(bolusId: bolusId, deliveredMilliunits: 2000)))
        cancelOnFirstPoll(b, fake)
        let delivered = try await deliver(b, 2.0)
        #expect(delivered == 2.0)                               // authoritative full amount
        #expect(b.lastBolusCancelled == false)                 // never a fabricated cancellation label
        #expect(fake.lastSent(cancelOp) != nil)                // the cancel WAS written to the pump
        #expect(!b.deliveryOutcomeUnknown)
    }

    /// A partial completion after a cancel reports the AUTHORITATIVE delivered amount (1.0), never the
    /// requested 2.0, and does not invent a cancellation flag.
    @Test func cancelThenPartialCompletionReportsAuthoritativeAmount() async throws {
        let (b, fake) = make()
        fake.script(initiateOp, .frame(FakePumpTransport.initiateAccepted(bolusId: bolusId)))
        fake.script(statusOp, .frame(FakePumpTransport.currentBolusStatus(statusId: 1, bolusId: bolusId)),
                              .frame(FakePumpTransport.currentBolusStatus(statusId: 0, bolusId: bolusId)))
        fake.script(lastOp, .frame(FakePumpTransport.lastBolus(bolusId: bolusId, deliveredMilliunits: 1000)))  // partial
        cancelOnFirstPoll(b, fake)
        let delivered = try await deliver(b, 2.0)
        #expect(delivered == 1.0)                              // authoritative partial, not the requested 2.0
        #expect(b.lastBolusCancelled == false)                // no invented cancellation
        #expect(fake.lastSent(cancelOp) != nil)
    }

    /// Cancel issued, then the status poll drops until the deadline → indeterminate (never a guessed
    /// terminal): the outcome stays unresolved and globally blocked, awaiting pump reconciliation.
    @Test func cancelThenStatusDropsIsIndeterminate() async {
        let (b, fake) = make()
        fake.script(initiateOp, .frame(FakePumpTransport.initiateAccepted(bolusId: bolusId)))
        fake.script(statusOp, .frame(FakePumpTransport.currentBolusStatus(statusId: 1, bolusId: bolusId)))  // one active; then default drops
        cancelOnFirstPoll(b, fake)
        let e = await capture { try await deliver(b) }
        #expect(indeterminate(e))
        #expect(b.deliveryOutcomeUnknown)
    }

    /// The cancel WRITE itself fails (swallowed by the fire-and-forget path) → the dose proceeds to its
    /// authoritative outcome, still never labelled cancelled. A failed cancel does not stop the pump.
    @Test func cancelWriteFailureLeavesTheDoseToItsAuthoritativeOutcome() async throws {
        let (b, fake) = make()
        fake.preWriteError[cancelOp] = BolusError.pumpRejected("cancel write failed")
        fake.script(initiateOp, .frame(FakePumpTransport.initiateAccepted(bolusId: bolusId)))
        fake.script(statusOp, .frame(FakePumpTransport.currentBolusStatus(statusId: 1, bolusId: bolusId)),
                              .frame(FakePumpTransport.currentBolusStatus(statusId: 0, bolusId: bolusId)))
        fake.script(lastOp, .frame(FakePumpTransport.lastBolus(bolusId: bolusId, deliveredMilliunits: 2000)))
        cancelOnFirstPoll(b, fake)
        let delivered = try await deliver(b, 2.0)
        #expect(delivered == 2.0)                 // cancel write failed → dose proceeded → authoritative full
        #expect(b.lastBolusCancelled == false)
    }

    // MARK: - Phase 09.9 D-01 — no-cartridge hard block (fail-closed, never a signed frame)

    /// `validateDeliver` is the shared pre-flight choke point, called BEFORE permission/initiate are
    /// ever requested — so a no-cartridge refusal must write ZERO frames (not even the permission ask).
    @Test func noCartridgeRefusesBeforeAnySignedFrameIsWritten() async {
        let (b, fake) = make()
        b.setCartridgeLoadStateForTesting(0)   // CHANGE_CARTRIDGE — mid loading-state triad
        let e = await capture { try await deliver(b) }
        guard case .noCartridge? = e as? BolusError else {
            Issue.record("expected BolusError.noCartridge, got \(String(describing: e))")
            return
        }
        #expect(fake.sent.filter { $0.opCode == BolusPermissionRequest.props.opCode }.isEmpty,
                "no permission request may be sent for a refused no-cartridge attempt")
        #expect(fake.initiateWriteCount == 0, "no initiate request may be sent for a refused no-cartridge attempt")
        #expect(!b.deliveryOutcomeUnknown)     // a clean refusal, never an indeterminate block
    }

    /// Each of the three loading states in the {0,1,2} gate set refuses; the idle/unknown default (6)
    /// allows (proving the predicate, not just one literal value, drives the guard).
    @Test func noCartridgeGateSetMatchesAllThreeLoadingStatesAndAllowsIdle() async {
        for loadingState in [0, 1, 2] {
            let (b, fake) = make()
            b.setCartridgeLoadStateForTesting(loadingState)
            let e = await capture { try await deliver(b) }
            guard case .noCartridge? = e as? BolusError else {
                Issue.record("loadState \(loadingState) expected BolusError.noCartridge, got \(String(describing: e))")
                continue
            }
            #expect(fake.initiateWriteCount == 0)
        }
        // Idle/unknown default (6) — no fastRead has landed yet — must NOT block.
        let (b2, fake2) = make()
        b2.setCartridgeLoadStateForTesting(6)
        fake2.script(initiateOp, .frame(FakePumpTransport.initiateAccepted(bolusId: bolusId)))
        fake2.script(statusOp, .frame(FakePumpTransport.currentBolusStatus(statusId: 0, bolusId: bolusId)))
        fake2.script(lastOp, .frame(FakePumpTransport.lastBolus(bolusId: bolusId, deliveredMilliunits: 2000)))
        let delivered = try? await deliver(b2)
        #expect(delivered == 2.0)
    }

    /// D-01 (safety, C4 oracle): a refused no-cartridge attempt must not merely throw the right error —
    /// it must leave delivery state byte-unchanged (no delivered value ever recorded).
    @Test func noCartridgeRefusalRecordsNothingAsDelivered() async {
        let (b, fake) = make()
        b.setCartridgeLoadStateForTesting(1)   // LOAD_CARTRIDGE
        let before = (lastBolusUnits: b.snapshot.lastBolusUnits, iobUnits: b.snapshot.iobUnits)
        _ = await capture { try await deliver(b) }
        #expect(b.snapshot.lastBolusUnits == before.lastBolusUnits)
        #expect(b.snapshot.iobUnits == before.iobUnits)
        #expect(fake.initiateWriteCount == 0)
    }

    /// Freshness (RESEARCH Pitfall 1): `LoadStatusRequest` must be part of the routine fast-poll tier
    /// (`fastRead()`), not only the on-demand wizard refresh — proven behaviorally via the
    /// `onReadDispatchedForTesting` seam (mirrors `PumpPairingInstrumentationTests`' technique) so the
    /// gate reads a value the pump actually keeps current during normal operation.
    @Test func loadStatusRequestIsPartOfTheRoutineFastPollTier() {
        let (b, _) = make()
        var dispatchedTypeNames: [String] = []
        b.onReadDispatchedForTesting = { typeName, _ in dispatchedTypeNames.append(typeName) }
        b.simulateRecurringFastAndStaticReadTickForTesting()
        #expect(dispatchedTypeNames.contains("LoadStatusRequest"),
                "fastRead() must include LoadStatusRequest so cartridgeLoadState never goes permanently stale")
    }

    // MARK: - Phase 09.9 D-02 — out-of-insulin nack enrichment (honest inference, never over-claimed)

    /// BolusPermissionResponse nack site: a real INVALID_PUMPING_STATE nack (reasonId 1) while the
    /// app's last-known reservoir reading was below the requested total must surface the specific
    /// `.possiblyOutOfInsulin` case, never the generic `.pumpRejected` — and must not reach initiate.
    @Test func permissionNackWithLowReservoirIsPossiblyOutOfInsulin() async {
        let (b, fake) = makeAwaitingPermission()
        b.setReservoirUnitsForTesting(0.4)
        fake.script(BolusPermissionResponse.props.opCode, .frame(FakePumpTransport.permissionDenied(nack: 1)))
        let e = await capture { try await deliver(b, 2.0) }
        guard case .possiblyOutOfInsulin(let reservoirUnits, _)? = e as? BolusError else {
            Issue.record("expected BolusError.possiblyOutOfInsulin, got \(String(describing: e))")
            return
        }
        #expect(reservoirUnits == 0.4)
        #expect(fake.initiateWriteCount == 0, "a permission nack must never reach the initiate write")
        #expect(!indeterminate(e))          // clean pre-initiate failure, not FB-02 indeterminate
        #expect(!b.deliveryOutcomeUnknown)  // never blocked
    }

    /// InitiateBolusResponse non-accept site: the same low-reservoir inference applies to the
    /// initiate-nack path, not only the permission-nack path.
    @Test func initiateNackWithLowReservoirIsPossiblyOutOfInsulin() async {
        let (b, fake) = make()
        b.setReservoirUnitsForTesting(0.4)
        fake.script(initiateOp, .frame(FakePumpTransport.initiateNack(bolusId: bolusId)))
        let e = await capture { try await deliver(b, 2.0) }
        guard case .possiblyOutOfInsulin(let reservoirUnits, _)? = e as? BolusError else {
            Issue.record("expected BolusError.possiblyOutOfInsulin, got \(String(describing: e))")
            return
        }
        #expect(reservoirUnits == 0.4)
        #expect(!indeterminate(e))
        #expect(!b.deliveryOutcomeUnknown)
        #expect(fake.initiateWriteCount == 1)   // the initiate DID go out at this site — still a clean failure
    }

    /// Control (no over-claim): the SAME nack reason fires while the reservoir reading was ample — the
    /// inference must not fire when there's no evidence for it. Stays the generic `.pumpRejected`.
    @Test func permissionNackWithAmpleReservoirStaysGenericPumpRejected() async {
        let (b, fake) = makeAwaitingPermission()
        b.setReservoirUnitsForTesting(10.0)
        fake.script(BolusPermissionResponse.props.opCode, .frame(FakePumpTransport.permissionDenied(nack: 1)))
        let e = await capture { try await deliver(b, 2.0) }
        guard case .pumpRejected? = e as? BolusError else {
            Issue.record("expected generic BolusError.pumpRejected when reservoir is ample, got \(String(describing: e))")
            return
        }
        #expect(!indeterminate(e))
        #expect(fake.initiateWriteCount == 0)
    }
}
