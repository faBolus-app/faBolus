import Testing
import Foundation
import faBolusCore
import PumpX2Messages
import PumpX2BLE
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
}
