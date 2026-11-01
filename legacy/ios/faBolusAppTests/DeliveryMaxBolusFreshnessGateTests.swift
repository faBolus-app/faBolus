import Testing
import Foundation
import faBolusCore
import TandemMessages
@testable import faBolus

/// `TandemBackend.validateDeliver`'s two independent, composable delivery guards: fail-closed until the
/// pump's own configured max-bolus (op-115) has been read at least once, and — once read — the max-bound
/// check against that pump-reported ceiling. Distinct from the app-side `Interlocks.clampMaxBolusLimit`
/// unit (covered by `InterlocksTests`) and from the retired `setMaxBolus`/`setMaxBasal` limit-SETTERS —
/// this file's remaining subject is the per-bolus DELIVERY path (`deliverBolus`), never the limit writers.
@Suite(.serialized) @MainActor
struct DeliveryMaxBolusFreshnessGateTests {

    // MARK: - Fail-closed unread-op-115 freshness gate

    /// A manual units bolus attempted while `therapyParamsDate == nil`
    /// (op-115 has never been read) must be fail-closed — thrown as `BolusError.pumpRejected`, BEFORE
    /// any delivery bytes are constructed (`validateDeliver` runs first thing inside `deliverBolus`,
    /// ahead of any `perform`/BLE write). Without the guard, the permissive 25 U default
    /// (`PumpSnapshot.maxBolusUnits`) would silently stand in as the operative bound for a real pump
    /// whose actual configured max might be lower.
    @Test func manualDeliverBlocksWhileMaxBolusUnread() async throws {
        let fake = FakePumpTransport()
        let backend = TandemBackend(testTransport: fake)
        backend.setTherapyParamsDateForTesting(nil)  // recreate the never-read-op-115 window
        fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        do {
            _ = try await backend.deliverBolus(units: 2.0, carbsGrams: nil, bgMgdl: nil, iobUnits: nil)
            Issue.record("expected deliverBolus to throw BolusError.pumpRejected while op-115 is unread")
        } catch let error as BolusError {
            guard case .pumpRejected = error else {
                Issue.record("expected .pumpRejected, got \(error)")
                return
            }
        }
        // No delivery write should have gone out — the guard fires before `perform` sends anything.
        #expect(
            fake.lastSent(InitiateBolusRequest.props.opCode) == nil,
            "no delivery bytes may be constructed while op-115 is unread")
    }

    // MARK: - Boundary neighbors — the freshness guard composes with the max-bound guard

    private static let boundaryBolusId = 9911

    /// A connected+paired backend scripted to accept a delivery, with an op-115 frame ALREADY injected via
    /// the real `didReceiveFrame` path (stamping `therapyParamsDate` for real and setting
    /// `snapshot.maxBolusUnits` to `pumpMaxUnits`) — the "read-and-bounded" state these boundary tests probe.
    private func makeReadBackend(pumpMaxUnits: Double) -> (TandemBackend, FakePumpTransport) {
        let fake = FakePumpTransport()
        let backend = TandemBackend(testTransport: fake)
        fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        fake.script(
            BolusPermissionResponse.props.opCode,
            .frame(FakePumpTransport.permissionGranted(bolusId: Self.boundaryBolusId)))
        backend.injectStatusFrameForTesting(
            FakePumpTransport.calcDataSnapshot(
                iobMilliunits: 0, targetBg: 110, isf: 40, carbRatioMilliGramsPerUnit: 10_000,
                maxBolusMilliunits: Int((pumpMaxUnits * 1000).rounded())))
        return (backend, fake)
    }

    /// Post-read-then-deliver: the REAL op-115 handler stamps `therapyParamsDate`, clearing the fail-closed
    /// guard, and a below-max delivery succeeds — proving a genuine read (not just the test-double default)
    /// clears the guard too.
    @Test func deliverSucceedsAfterOp115Read() async throws {
        let (b, fake) = makeReadBackend(pumpMaxUnits: 10.0)
        fake.script(
            InitiateBolusResponse.props.opCode,
            .frame(FakePumpTransport.initiateAccepted(bolusId: Self.boundaryBolusId)))
        fake.script(
            CurrentBolusStatusResponse.props.opCode,
            .frame(FakePumpTransport.currentBolusStatus(statusId: 0, bolusId: Self.boundaryBolusId)))
        fake.script(
            LastBolusStatusV2Response.props.opCode,
            .frame(FakePumpTransport.lastBolus(bolusId: Self.boundaryBolusId, deliveredMilliunits: 3000)))
        let delivered = try await b.deliverBolus(units: 3.0, carbsGrams: nil, bgMgdl: nil, iobUnits: nil)
        #expect(delivered == 3.0)
    }

    /// Exactly-at-pump-max after read succeeds — the existing `<=` bound is inclusive, unweakened by the
    /// new freshness guard.
    @Test func deliverAtExactlyPumpMaxSucceedsAfterRead() async throws {
        let (b, fake) = makeReadBackend(pumpMaxUnits: 10.0)
        fake.script(
            InitiateBolusResponse.props.opCode,
            .frame(FakePumpTransport.initiateAccepted(bolusId: Self.boundaryBolusId)))
        fake.script(
            CurrentBolusStatusResponse.props.opCode,
            .frame(FakePumpTransport.currentBolusStatus(statusId: 0, bolusId: Self.boundaryBolusId)))
        fake.script(
            LastBolusStatusV2Response.props.opCode,
            .frame(FakePumpTransport.lastBolus(bolusId: Self.boundaryBolusId, deliveredMilliunits: 10000)))
        let delivered = try await b.deliverBolus(units: 10.0, carbsGrams: nil, bgMgdl: nil, iobUnits: nil)
        #expect(delivered == 10.0)
    }

    /// Pump-max + 0.05 after read throws `exceedsMax` (NOT `pumpRejected`) — proving the freshness guard
    /// did not displace or weaken the pre-existing max-bound guard; the two guards are independent and both
    /// active.
    @Test func deliverAbovePumpMaxThrowsAfterRead() async throws {
        let (b, _) = makeReadBackend(pumpMaxUnits: 10.0)
        do {
            _ = try await b.deliverBolus(units: 10.05, carbsGrams: nil, bgMgdl: nil, iobUnits: nil)
            Issue.record("expected deliverBolus to throw BolusError.exceedsMax above the pump's read max")
        } catch let error as BolusError {
            guard case .exceedsMax = error else {
                Issue.record("expected .exceedsMax, got \(error)")
                return
            }
        }
    }
}
