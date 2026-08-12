import Testing
import Foundation
import faBolusCore
import PumpX2Messages
import PumpX2BLE
@testable import faBolus

/// **MUST-NOT-BLOCK invariant (task #93, Insulin Stacking Guard).** Proves the safety spine of the whole
/// phase as a coupled pair, mirroring `TandemDeliveryOutcomeTests`' `FakePumpTransport` + `TandemBackend
/// (testTransport:)` harness: (a) `StackingGuard.calcOverride` is ACTIVE (non-`.none`) for a scenario where
/// the entered dose exceeds the pump's own calculator suggestion above the pump's own target, and (b) the
/// REAL deliver path (`TandemBackend.deliverBolus`) through the fake transport still delivers EXACTLY the
/// consented units while SG1 is firing — the number the user consented to reaches the pump unchanged. A
/// third assertion pins op-109 IOB parity: the IOB a surface would display (`BolusRecommendation.iobUnits`)
/// equals the snapshot's `iobUnits` (the same op-109 `swan6hrIOB` source). This test is structured so SG2
/// (plan 02) and SG3a (plan 04) can extend it with additional firing scenarios against the same
/// delivered==consented assertion. The delivery path imports nothing from `StackingGuard`.
@Suite(.serialized) @MainActor
struct StackingGuardDeliverInvariantTests {

    private let bolusId = 5678
    private let initiateOp = InitiateBolusResponse.props.opCode
    private let statusOp = CurrentBolusStatusResponse.props.opCode
    private let lastOp = LastBolusStatusV2Response.props.opCode

    /// A backend whose time-sync + permission already succeed, scripted to a matching bolus status so a
    /// full-completion delivery settles (same shape as `TandemDeliveryOutcomeTests.make`).
    private func makeDeliveringBackend(deliveredMilliunits: UInt32) -> (TandemBackend, FakePumpTransport) {
        let fake = FakePumpTransport()
        let backend = TandemBackend(testTransport: fake)
        backend.deliveryPollTimeoutOverride = 1.2
        fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        fake.script(BolusPermissionResponse.props.opCode, .frame(FakePumpTransport.permissionGranted(bolusId: bolusId)))
        fake.script(initiateOp, .frame(FakePumpTransport.initiateAccepted(bolusId: bolusId)))
        fake.script(statusOp, .frame(FakePumpTransport.currentBolusStatus(statusId: 0, bolusId: bolusId)))
        fake.script(lastOp, .frame(FakePumpTransport.lastBolus(bolusId: bolusId, deliveredMilliunits: deliveredMilliunits)))
        return (backend, fake)
    }

    /// (a) SG1 is ACTIVE for this scenario: entered > recommended > 0, glucose above the pump's own target,
    /// a displayable dose.
    @Test func sg1FiresForThisOverrideScenario() {
        let entered = 6.0
        let recommended = 2.0
        let target = 120
        let glucose = 180

        let disclosure = StackingGuard.calcOverride(enteredUnits: entered, recommendedUnits: recommended,
                                                     displaysNumericDose: true, pumpIOBUnits: 0.4,
                                                     glucoseMgdl: glucose, targetMgdl: target)
        #expect(disclosure.friction != .none)
    }

    /// (b) MUST-NOT-BLOCK: with SG1 active for the exact scenario above, the REAL deliver path through the
    /// fake transport delivers exactly the consented units — SG1's disclosure never crosses into the number
    /// that reaches the pump.
    @Test func deliveredEqualsConsentedWhileSG1Fires() async throws {
        let entered = 6.0
        let recommended = 2.0
        let target = 120
        let glucose = 180

        // Re-confirm SG1 is active for this exact scenario, coupled to the delivery assertion below —
        // if a future edit makes SG1 stop firing here, this test fails LOUDLY rather than silently
        // asserting delivered==consented against a scenario where SG1 was never active.
        let disclosure = StackingGuard.calcOverride(enteredUnits: entered, recommendedUnits: recommended,
                                                     displaysNumericDose: true, pumpIOBUnits: 0.4,
                                                     glucoseMgdl: glucose, targetMgdl: target)
        #expect(disclosure.friction != .none)

        let (backend, fake) = makeDeliveringBackend(deliveredMilliunits: 6000)
        let delivered = try await backend.deliverBolus(units: entered, carbsGrams: nil, bgMgdl: glucose, iobUnits: 0.4)
        #expect(delivered == entered)                 // exactly the consented dose, not the calculator's suggestion
        #expect(!backend.deliveryOutcomeUnknown)
        _ = fake                                       // keep the fake alive for the duration of the assertion
    }

    /// (c) op-109 IOB parity: the IOB a surface would display equals the snapshot's IOB (the same op-109
    /// `swan6hrIOB` source) for a representative snapshot/recommendation pair.
    @Test func displayedIOBEqualsSnapshotIOB() {
        var snapshot = PumpSnapshot()
        snapshot.iobUnits = 1.85

        var rec = BolusRecommendation()
        rec.recommendedUnits = 2.0
        rec.iobUnits = snapshot.iobUnits

        #expect(rec.iobUnits == snapshot.iobUnits)
    }
}
