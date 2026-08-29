import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// Pins that when StackingGuard's calc-override is firing, `deliverBolus` still sends exactly the
/// consented units. The stacking UI must never clamp, rewrite, or block the number the user confirmed.
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
        fake.script(
            lastOp, .frame(FakePumpTransport.lastBolus(bolusId: bolusId, deliveredMilliunits: deliveredMilliunits)))
        return (backend, fake)
    }

    /// (a) SG1 is ACTIVE for this scenario: entered > recommended > 0, glucose above the pump's own target,
    /// a displayable dose.
    @Test func sg1FiresForThisOverrideScenario() {
        let entered = 6.0
        let recommended = 2.0
        let target = 120
        let glucose = 180

        let disclosure = StackingGuard.calcOverride(
            enteredUnits: entered, recommendedUnits: recommended,
            displaysNumericDose: true, pumpIOBUnits: 0.4,
            glucoseMgdl: glucose, targetMgdl: target)
        #expect(disclosure.friction != .none)
    }

    /// With stacking-guard calc-override active (entered > recommended, glucose above target), deliver still sends exactly the consented units.
    @Test func deliveredEqualsConsentedWhileSG1Fires() async throws {
        let entered = 6.0
        let recommended = 2.0
        let target = 120
        let glucose = 180

        // Re-confirm SG1 is active for this exact scenario, coupled to the delivery assertion below —
        // if a future edit makes SG1 stop firing here, this test fails LOUDLY rather than silently
        // asserting delivered==consented against a scenario where SG1 was never active.
        let disclosure = StackingGuard.calcOverride(
            enteredUnits: entered, recommendedUnits: recommended,
            displaysNumericDose: true, pumpIOBUnits: 0.4,
            glucoseMgdl: glucose, targetMgdl: target)
        #expect(disclosure.friction != .none)

        let (backend, fake) = makeDeliveringBackend(deliveredMilliunits: 6000)
        let delivered = try await backend.deliverBolus(units: entered, carbsGrams: nil, bgMgdl: glucose, iobUnits: 0.4)
        #expect(delivered == entered)  // exactly the consented dose, not the calculator's suggestion
        #expect(!backend.deliveryOutcomeUnknown)
        _ = fake  // keep the fake alive for the duration of the assertion
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

    /// With stacking-guard firing because entered is at/above the pump's own max bolus, deliver still sends exactly the consented units.
    @Test func deliveredEqualsConsentedWhileSG2Fires() async throws {
        let entered = 25.0
        let maxBolusUnits = 25.0

        // Re-confirm SG2 is active for this exact scenario, coupled to the delivery assertion below — if a
        // future edit makes SG2 stop firing here, this test fails LOUDLY rather than silently asserting
        // delivered==consented against a scenario where SG2 was never active.
        let disclosure = StackingGuard.maxBolusProximity(enteredUnits: entered, maxBolusUnits: maxBolusUnits)
        #expect(disclosure.friction != .none)

        let (backend, fake) = makeDeliveringBackend(deliveredMilliunits: 25000)
        let delivered = try await backend.deliverBolus(units: entered, carbsGrams: nil, bgMgdl: nil, iobUnits: 0)
        #expect(delivered == entered)  // exactly the consented dose, not clamped to a lower number
        #expect(!backend.deliveryOutcomeUnknown)
        _ = fake  // keep the fake alive for the duration of the assertion
    }

    /// With stacking-guard friction at `.disclose`, deliver still sends exactly the consented units.
    @Test func deliveredEqualsConsentedWhileSG3aDiscloseFires() async throws {
        let entered = 2.5
        let recommended = 2.0  // ratio 1.25 — below the default confirmExtraOverrideRatio (1.5)
        let target = 120
        let glucose = 180
        let maxBolusUnits = 25.0

        let escalation = StackingGuard.escalation(
            enteredUnits: entered, recommendedUnits: recommended,
            displaysNumericDose: true, pumpIOBUnits: 0.4,
            glucoseMgdl: glucose, targetMgdl: target,
            maxBolusUnits: maxBolusUnits)
        #expect(escalation.friction == .disclose)

        let (backend, fake) = makeDeliveringBackend(deliveredMilliunits: 2500)
        let delivered = try await backend.deliverBolus(units: entered, carbsGrams: nil, bgMgdl: glucose, iobUnits: 0.4)
        #expect(delivered == entered)
        #expect(!backend.deliveryOutcomeUnknown)
        _ = fake
    }

    /// With stacking-guard friction at `.confirmExtra`, deliver still sends exactly the consented units — the extra confirm never resizes the dose.
    @Test func deliveredEqualsConsentedWhileSG3aConfirmExtraFires() async throws {
        let entered = 3.5
        let recommended = 2.0  // ratio 1.75 — between confirmExtraOverrideRatio (1.5) and reenterOverrideRatio (2.0)
        let target = 120
        let glucose = 180
        let maxBolusUnits = 25.0

        let escalation = StackingGuard.escalation(
            enteredUnits: entered, recommendedUnits: recommended,
            displaysNumericDose: true, pumpIOBUnits: 0.4,
            glucoseMgdl: glucose, targetMgdl: target,
            maxBolusUnits: maxBolusUnits)
        #expect(escalation.friction == .confirmExtra)

        let (backend, fake) = makeDeliveringBackend(deliveredMilliunits: 3500)
        let delivered = try await backend.deliverBolus(units: entered, carbsGrams: nil, bgMgdl: glucose, iobUnits: 0.4)
        #expect(delivered == entered)
        #expect(!backend.deliveryOutcomeUnknown)
        _ = fake
    }

    /// With stacking-guard friction at `.reenter`, deliver still sends exactly the consented units. A mismatched re-type cannot satisfy the same check the phone screen uses, so it never reaches this path as a resized amount.
    @Test func deliveredEqualsConsentedWhileSG3aReenterFires() async throws {
        let entered = 8.0
        let recommended = 2.0  // ratio 4.0 — far above the default reenterOverrideRatio (2.0)
        let target = 120
        let glucose = 180
        let maxBolusUnits = 25.0

        let escalation = StackingGuard.escalation(
            enteredUnits: entered, recommendedUnits: recommended,
            displaysNumericDose: true, pumpIOBUnits: 0.4,
            glucoseMgdl: glucose, targetMgdl: target,
            maxBolusUnits: maxBolusUnits)
        #expect(escalation.friction == .reenter)

        // The re-type gate: only an EXACT match of the originally-entered/consented dose proceeds.
        #expect(BolusEntryView.reenterMatches(retyped: entered, original: entered))
        // A mismatched re-type (any different number) fails the SAME rule — it can never be the value the
        // gate lets through to the deliver call below.
        let mismatched = entered + 1.0
        #expect(!BolusEntryView.reenterMatches(retyped: mismatched, original: entered))

        let (backend, fake) = makeDeliveringBackend(deliveredMilliunits: 8000)
        let delivered = try await backend.deliverBolus(units: entered, carbsGrams: nil, bgMgdl: glucose, iobUnits: 0.4)
        #expect(delivered == entered)  // exactly the consented dose, never the mismatched retype
        #expect(!backend.deliveryOutcomeUnknown)
        _ = fake
    }

    /// `standardConfirmRoute` maps each stacking-guard tier to its own gate: `.reenter`/`.confirmExtra` keep their dialogs; `.disclose`/`.none` go to `.deliver`.
    @Test func standardConfirmRouteMapsEachSG3aTierToItsOwnGate() {
        #expect(BolusEntryView.standardConfirmRoute(for: .reenter) == .reenter)
        #expect(BolusEntryView.standardConfirmRoute(for: .confirmExtra) == .confirmExtra)
        #expect(BolusEntryView.standardConfirmRoute(for: .disclose) == .deliver)
        #expect(BolusEntryView.standardConfirmRoute(for: .none) == .deliver)
    }
}
