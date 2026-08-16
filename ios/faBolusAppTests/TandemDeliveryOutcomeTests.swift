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
    /// semantics (a booked bench follow-up — `PumpX2Kit/PINNED.md`), so `lastBolusCancelled` is never set
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
}
