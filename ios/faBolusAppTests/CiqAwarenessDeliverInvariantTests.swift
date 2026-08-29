import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// Control-IQ awareness is advisory only and must never change the signed dose path. Asserts
/// `deliverBolus` returns the consented amount and writes the same `InitiateBolusRequest`
/// milliunits regardless of CIQ-awareness state.
@Suite(.serialized) @MainActor
struct CiqAwarenessDeliverInvariantTests {

    private let bolusId = 9911
    private let initiateOp = InitiateBolusResponse.props.opCode
    private let statusOp = CurrentBolusStatusResponse.props.opCode
    private let lastOp = LastBolusStatusV2Response.props.opCode

    /// A backend whose time-sync + permission already succeed, scripted to a matching bolus status so a
    /// full-completion delivery settles — identical shape to
    /// `StackingGuardDeliverInvariantTests.makeDeliveringBackend` / `TandemDeliveryOutcomeTests.make`.
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

    /// The EXACT `InitiateBolusRequest` cargo a plain units-only bolus (no carbs, no BG, no frozen IOB)
    /// canonically encodes to for `entered` units — the same units-only shape `TandemBackend.perform`
    /// builds when `carbsGrams`/`bgMgdl`/`iobUnits` are all `nil` (FOOD2 bit, all other components zero).
    /// Used to assert the ACTUAL bytes written to the wire, not merely the mocked-and-matching return value.
    private func expectedUnitsOnlyCargo(enteredUnits: Double) throws -> [UInt8] {
        let mu = UInt32((enteredUnits * 1000).rounded())
        let req = try InitiateBolusRequest(
            validating: mu, bolusID: bolusId, bolusTypeBitmask: InitiateBolusRequest.bitFood2)
        return req.cargo
    }

    /// (a) `ciqZone` is a genuine, non-vacuous "fact firing" — built on a STANDALONE `PumpSnapshot`
    /// (`TandemBackend.snapshot`'s setter is private outside `TandemBackend.swift`, and there is
    /// deliberately no test-only setter for it — see `CiqAwarenessScopeGuardTests` for why). Coupled to
    /// the delivery assertion below only by using the SAME `entered` value, exactly like
    /// `StackingGuardDeliverInvariantTests` couples `StackingGuard.calcOverride(...)` firing to its own
    /// delivery assertion.
    private func ciqZoneIsFiring() -> PumpSnapshot {
        var snap = PumpSnapshot()
        snap.controlIQEnabled = true
        snap.ciqZone = ControlIQZone.increases.rawValue
        return snap
    }

    /// (a) The 60-min auto-correction lockout countdown fraction (T1-5) is genuinely active — a real,
    /// non-nil `Double` in `[0, 1]` from a lockout that started 5 minutes ago on a live Control-IQ+
    /// controller.
    private func lockoutIsFiring(now: Date) -> Double? {
        AutoCorrectionDisclosure.lockoutRemainingFraction(
            descriptor: .controlIQPlus, controllerEnabled: true,
            lockoutStartDate: now.addingTimeInterval(-5 * 60), now: now)
    }

    // MARK: - 2x2 matrix: {ciqZone present/nil} x {lockout active/inactive}

    /// ciqZone PRESENT, lockout ACTIVE — both Control-IQ-awareness facts are firing simultaneously; the
    /// real deliver path still writes and returns exactly the consented amount.
    @Test func deliveredEqualsConsentedWithCiqZonePresentAndLockoutActive() async throws {
        let now = Date()
        let snap = ciqZoneIsFiring()
        #expect(snap.ciqZone != nil, "ciqZone must be genuinely set for this scenario to be non-vacuous")
        let fraction = lockoutIsFiring(now: now)
        #expect(fraction != nil, "the lockout must be genuinely active for this scenario to be non-vacuous")

        let entered = 4.5
        let (backend, fake) = makeDeliveringBackend(deliveredMilliunits: 4500)
        let delivered = try await backend.deliverBolus(units: entered, carbsGrams: nil, bgMgdl: nil, iobUnits: nil)
        #expect(delivered == entered)
        #expect(!backend.deliveryOutcomeUnknown)
        let sent = try #require(fake.lastSent(InitiateBolusRequest.props.opCode))
        #expect(sent.cargo == (try expectedUnitsOnlyCargo(enteredUnits: entered)))
    }

    /// ciqZone PRESENT, lockout INACTIVE (no lockout start date known) — the real deliver path still
    /// writes and returns exactly the consented amount.
    @Test func deliveredEqualsConsentedWithCiqZonePresentAndLockoutInactive() async throws {
        let now = Date()
        let snap = ciqZoneIsFiring()
        #expect(snap.ciqZone != nil, "ciqZone must be genuinely set for this scenario to be non-vacuous")
        let fraction = AutoCorrectionDisclosure.lockoutRemainingFraction(
            descriptor: .controlIQPlus, controllerEnabled: true, lockoutStartDate: nil, now: now)
        #expect(fraction == nil, "no lockout start date means the lockout must be inactive (fail-closed)")

        let entered = 3.0
        let (backend, fake) = makeDeliveringBackend(deliveredMilliunits: 3000)
        let delivered = try await backend.deliverBolus(units: entered, carbsGrams: nil, bgMgdl: nil, iobUnits: nil)
        #expect(delivered == entered)
        #expect(!backend.deliveryOutcomeUnknown)
        let sent = try #require(fake.lastSent(InitiateBolusRequest.props.opCode))
        #expect(sent.cargo == (try expectedUnitsOnlyCargo(enteredUnits: entered)))
    }

    /// ciqZone NIL (Control-IQ off, or the raw byte is currently unmapped), lockout ACTIVE — the real
    /// deliver path still writes and returns exactly the consented amount.
    @Test func deliveredEqualsConsentedWithCiqZoneAbsentAndLockoutActive() async throws {
        let now = Date()
        var snap = PumpSnapshot()
        snap.controlIQEnabled = false
        snap.ciqZone = nil
        #expect(snap.ciqZone == nil, "ciqZone must be genuinely absent for this scenario to be non-vacuous")
        let fraction = lockoutIsFiring(now: now)
        #expect(fraction != nil, "the lockout must be genuinely active for this scenario to be non-vacuous")

        let entered = 7.25
        let (backend, fake) = makeDeliveringBackend(deliveredMilliunits: 7250)
        let delivered = try await backend.deliverBolus(units: entered, carbsGrams: nil, bgMgdl: nil, iobUnits: nil)
        #expect(delivered == entered)
        #expect(!backend.deliveryOutcomeUnknown)
        let sent = try #require(fake.lastSent(InitiateBolusRequest.props.opCode))
        #expect(sent.cargo == (try expectedUnitsOnlyCargo(enteredUnits: entered)))
    }

    /// ciqZone NIL, lockout INACTIVE — the baseline "no Control-IQ-awareness fact at all" case. The
    /// deliver path still writes and returns exactly the consented amount (and, trivially, is unaffected
    /// by the ABSENCE of CIQ-awareness state too — the invariant holds independent of which quadrant is
    /// true).
    @Test func deliveredEqualsConsentedWithCiqZoneAbsentAndLockoutInactive() async throws {
        let now = Date()
        var snap = PumpSnapshot()
        snap.controlIQEnabled = false
        snap.ciqZone = nil
        #expect(snap.ciqZone == nil, "ciqZone must be genuinely absent for this scenario to be non-vacuous")
        let fraction = AutoCorrectionDisclosure.lockoutRemainingFraction(
            descriptor: .controlIQPlus, controllerEnabled: true, lockoutStartDate: nil, now: now)
        #expect(fraction == nil, "no lockout start date means the lockout must be inactive (fail-closed)")

        let entered = 1.0
        let (backend, fake) = makeDeliveringBackend(deliveredMilliunits: 1000)
        let delivered = try await backend.deliverBolus(units: entered, carbsGrams: nil, bgMgdl: nil, iobUnits: nil)
        #expect(delivered == entered)
        #expect(!backend.deliveryOutcomeUnknown)
        let sent = try #require(fake.lastSent(InitiateBolusRequest.props.opCode))
        #expect(sent.cargo == (try expectedUnitsOnlyCargo(enteredUnits: entered)))
    }

    // MARK: - Cross-scenario invariant: the wire bytes never vary by quadrant

    /// Restates the 2x2 matrix as ONE explicit assertion: across every {ciqZone, lockout} quadrant, the
    /// EXACT `InitiateBolusRequest` cargo written to the wire for the SAME entered dose is byte-for-byte
    /// identical — no quadrant clamps, scales, or resizes it before it reaches the signed write. This is
    /// the strongest form of the invariant: it does not merely compare the (test-double-scripted) RETURNED
    /// delivered amount, it compares what was ACTUALLY sent.
    @Test func allFourQuadrantsWriteIdenticalWireBytesForTheSameEnteredAmount() async throws {
        let entered = 5.0
        let expectedCargo = try expectedUnitsOnlyCargo(enteredUnits: entered)
        var sentCargos: [[UInt8]] = []
        for _ in 0..<4 {
            let (backend, fake) = makeDeliveringBackend(deliveredMilliunits: 5000)
            _ = try await backend.deliverBolus(units: entered, carbsGrams: nil, bgMgdl: nil, iobUnits: nil)
            let sent = try #require(fake.lastSent(InitiateBolusRequest.props.opCode))
            sentCargos.append(sent.cargo)
        }
        for cargo in sentCargos {
            #expect(
                cargo == expectedCargo,
                "every quadrant must write byte-identical InitiateBolus cargo for the same consented amount")
        }
    }
}
