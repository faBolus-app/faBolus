import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// The extended-bolus delivery path still delivers the consented units with no UI — the entry surface
/// and its Settings toggle have been removed entirely.
@Suite(.serialized) @MainActor
struct ExtendedBolusHiddenBoundaryTests {

    private let bolusId = 9101
    private let initiateOp = InitiateBolusResponse.props.opCode
    private let statusOp = CurrentBolusStatusResponse.props.opCode
    private let lastOp = LastBolusStatusV2Response.props.opCode

    /// Same shape as `StackingGuardDeliverInvariantTests.makeDeliveringBackend` — a backend whose
    /// time-sync + permission already succeed, scripted to a matching bolus status so a full-completion
    /// delivery settles.
    private func makeDeliveringBackend(deliveredMilliunits: UInt32) -> (TandemBackend, FakePumpTransport) {
        let fake = FakePumpTransport()
        let backend = TandemBackend(testTransport: fake)
        backend.deliveryPollTimeoutOverride = 1.2
        fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        fake.script(BolusPermissionResponse.props.opCode, .frame(FakePumpTransport.permissionGranted(bolusId: bolusId)))
        fake.script(initiateOp, .frame(FakePumpTransport.initiateAccepted(bolusId: bolusId)))
        fake.script(statusOp, .frame(FakePumpTransport.currentBolusStatus(statusId: 0, bolusId: bolusId)))
        fake.script(
            lastOp, .frame(FakePumpTransport.lastBolus(bolusId: bolusId, deliveredMilliunits: deliveredMilliunits)))
        return (backend, fake)
    }

    /// The REAL extended-bolus deliver path through the fake transport still delivers exactly the
    /// consented total — split now/later — with zero UI constructed anywhere in this test.
    @Test func deliverExtendedBolusStillDeliversTheConsentedTotalWithNoUIPresent() async throws {
        let (backend, fake) = makeDeliveringBackend(deliveredMilliunits: 3000)
        let delivered = try await backend.deliverExtendedBolus(
            totalUnits: 3.0, nowUnits: 1.0, durationMinutes: 60,
            carbsGrams: nil, bgMgdl: nil, iobUnits: nil)
        #expect(delivered == 3.0)  // exactly the consented total, not the now/later split
        #expect(!backend.deliveryOutcomeUnknown)
        _ = fake  // keep the fake alive for the duration of the assertion
    }
}
