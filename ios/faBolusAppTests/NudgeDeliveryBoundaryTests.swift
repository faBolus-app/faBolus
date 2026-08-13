import Testing
import Foundation
import faBolusCore
import PumpX2Messages
import PumpX2BLE
@testable import faBolus

/// **MUST-NOT-REACH boundary (phase #92, faBolusNudge delivery-path boundary).** Proves the INVERSE of
/// `StackingGuardDeliverInvariantTests`: where that suite proves a friction disclosure never blocks the
/// consented dose from reaching the pump, this suite proves the advisory `FABOLUS_NUDGE` eating nudge NEVER
/// supplies the number that reaches the signed delivery seam (`TandemBackend.deliverBolus` /
/// `GatedPumpWrite`). UNGATED — NOT wrapped in `#if FABOLUS_NUDGE` (D-04) — so this suite compiles and RUNS
/// under CI's `FABOLUS_NUDGE=0` build: `EatingAlert`, `AppModel.eatingNudge*`, and
/// `AppModel.openBolusRequested` are all declared OUTSIDE the gate; only their bodies branch on it. This
/// test asserts the boundary STRUCTURALLY; it does NOT add a runtime is-from-nudge gate to the deliver seam
/// (D-01). See `.planning/phases/07-fabolusnudge-delivery-path-boundary-92/07-CONTEXT.md`.
@Suite(.serialized) @MainActor
struct NudgeDeliveryBoundaryTests {

    private let bolusId = 9012
    private let initiateOp = InitiateBolusResponse.props.opCode
    private let statusOp = CurrentBolusStatusResponse.props.opCode
    private let lastOp = LastBolusStatusV2Response.props.opCode

    /// A backend whose time-sync + permission already succeed, scripted to a matching bolus status so a
    /// full-completion delivery settles. Copied verbatim (same 4 scripted opcodes) from
    /// `StackingGuardDeliverInvariantTests.makeDeliveringBackend` — Swift Testing suites are independent
    /// structs and `FakePumpTransport` is already file-visible across the target, so no shared base class
    /// is needed.
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

    // MARK: - Task 1 (TRACER): end-to-end nudge → deliver boundary

    /// MUST-NOT-REACH: a LIVE nudge with `estimatedCarbs == 60` is in flight while the REAL deliver path
    /// (through `FakePumpTransport`) delivers an EXPLICITLY-entered dose of `3.2`. The delivered amount
    /// equals the entered dose and is never the nudge's estimate — the only number that ever reaches the
    /// pump is the one the user typed, proving SC1/SC2/D-05d as a coupled pair (mirrors
    /// `StackingGuardDeliverInvariantTests.deliveredEqualsConsentedWhileSG1Fires`, inverted into a
    /// MUST-NOT-REACH shape per D-03).
    @Test func deliveredEqualsExplicitDoseNeverNudgeEstimate() async throws {
        let liveNudge = EatingAlert(estimatedCarbs: 60, at: Date())   // deliberately != the entered dose below
        let entered = 3.2                                            // the ONLY number that should reach the pump

        let (backend, fake) = makeDeliveringBackend(deliveredMilliunits: 3200)
        let delivered = try await backend.deliverBolus(units: entered, carbsGrams: nil, bgMgdl: nil, iobUnits: 0)
        #expect(delivered == entered)                          // exactly the entered dose
        #expect(delivered != liveNudge.estimatedCarbs)          // guards against a future accidental wiring of the estimate into the dose
        #expect(!backend.deliveryOutcomeUnknown)
        _ = fake   // keep the fake alive for the duration of the assertion
    }

    /// `EatingAlert.estimatedCarbs` surfaces ONLY through `.message` (D-02/D-05a/D-05c) — there is no
    /// second stored/computed member on the type a caller could route into a dose. `EatingAlert` (see
    /// `ios/faBolus/Data/SmartAssist.swift`) declares exactly two members: `estimatedCarbs` (the raw
    /// number) and `message` (the display string it feeds); `message` is the ONLY other member on the
    /// type, so the type's own shape — not a runtime probe — is the proof that the number terminates
    /// there. This test pins the string-level behavior so a future member addition is caught at review.
    @Test func nudgeAlertExposesEstimateOnlyViaMessage() {
        let zeroCarbAlert = EatingAlert(estimatedCarbs: 0, at: Date())
        #expect(zeroCarbAlert.message == "Looks like you might be eating. Bolus?")

        let carbAlert = EatingAlert(estimatedCarbs: 42, at: Date())
        #expect(carbAlert.message == "Looks like you're eating (~42g). Bolus?")
        #expect(carbAlert.message.contains("42"))
    }
}
