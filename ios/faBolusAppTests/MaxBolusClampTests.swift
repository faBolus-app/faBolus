import Testing
import Foundation
import faBolusCore
import TandemMessages
@testable import faBolus

/// The absolute 25 U max-bolus cap is a HARD block enforced at the funnel AND in every backend
/// through the one shared `Interlocks.clampMaxBolusLimit`, so a requested limit above 25 U can never take
/// effect — on ANY backend. Previously the `MockBackend` skipped the clamp entirely and only `TandemBackend`
/// enforced it. Distinct from the per-bolus DELIVERY block (`deliverBolus` throws), which is unchanged.
@Suite(.serialized) @MainActor
struct MaxBolusClampTests {

    /// The gap this closes: MockBackend used to store the raw value unclamped.
    @Test func mockBackendClampsTheMaxBolusLimit() async throws {
        let mock = MockBackend()
        try await mock.setMaxBolus(units: 30)
        #expect(mock.snapshot.maxBolusUnits == 25.0)
        try await mock.setMaxBolus(units: 8)  // a legitimate value is untouched
        #expect(mock.snapshot.maxBolusUnits == 8.0)
    }

    /// End-to-end through the app funnel: even asking for an absurd limit yields ≤ 25 U at the backend.
    @Test func appFunnelCapsTheLimitEndToEnd() async {
        let s = AppSettings.shared
        let savedAdv = s.advancedControlEnabled
        s.advancedControlEnabled = true  // .setMaxBolus is advanced-gated; Mock is .mobiAdvanced
        defer { s.advancedControlEnabled = savedAdv }
        let backend = MockBackend()
        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("maxbolus-ledger-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)
        await model.setMaxBolus(units: 999)
        #expect(backend.snapshot.maxBolusUnits == 25.0)
    }

    /// The pump-facing proof: the actual `SetMaxBolusLimitRequest` bytes TandemBackend writes are capped to
    /// 25 U (25000 mU) even when 30 U is requested. The fake records the write before the (unscripted)
    /// courtesy response await, so `try?` is safe — we assert on the recorded cargo.
    @Test func tandemBackendClampsTheWrittenLimit() async throws {
        let fake = FakePumpTransport()
        let backend = TandemBackend(testTransport: fake)
        backend.setConnectionForTesting(.connected)
        fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        try? await backend.setMaxBolus(units: 30)
        let sent = fake.lastSent(SetMaxBolusLimitRequest.props.opCode)
        #expect(sent != nil, "a max-bolus-limit write must have gone out")
        #expect(
            sent?.cargo == (try SetMaxBolusLimitRequest(maxBolusMilliunits: 25000)).cargo,
            "the WRITTEN limit must be capped to 25 U (25000 mU) even when 30 U is requested")
    }

    /// A max-bolus limit request below the app's OLD 0.05 U floor is aligned UP to the kit's 1.0 U
    /// throwing floor — never throws at the kit boundary.
    @Test func tandemBackendFloorsTheWrittenLimitToTheNewKitFloor() async throws {
        let fake = FakePumpTransport()
        let backend = TandemBackend(testTransport: fake)
        backend.setConnectionForTesting(.connected)
        fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        try? await backend.setMaxBolus(units: 0.1)  // below the old 0.05 U floor's neighbor, well below 1.0 U
        let sent = fake.lastSent(SetMaxBolusLimitRequest.props.opCode)
        #expect(sent != nil, "a max-bolus-limit write must have gone out")
        #expect(
            sent?.cargo == (try SetMaxBolusLimitRequest(maxBolusMilliunits: 1000)).cargo,
            "the WRITTEN limit must be floored to 1.0 U (1000 mU) even when 0.1 U is requested")
    }

    // MARK: - setMaxBasal ceiling clamp, symmetric with setMaxBolus

    /// A max-basal limit above the kit's byte-verified 15.0 U/hr throwing ceiling must be CLAMPED to
    /// 15.0 (15000 mU/hr) at the backend and dispatched — not thrown as a raw `ValidationError`. Before this
    /// `TandemBackend.setMaxBasal` clamped only the floor, so a 20 U/hr request threw at the kit boundary.
    @Test func tandemBackendClampsTheWrittenMaxBasalLimit() async throws {
        let fake = FakePumpTransport()
        let backend = TandemBackend(testTransport: fake)
        backend.setConnectionForTesting(.connected)
        fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        try await backend.setMaxBasal(unitsPerHour: 20)  // above the 15 U/hr ceiling → must clamp, not throw
        let sent = fake.lastSent(SetMaxBasalLimitRequest.props.opCode)
        #expect(sent != nil, "a max-basal-limit write must have gone out (clamped, not thrown)")
        #expect(
            sent?.cargo == (try SetMaxBasalLimitRequest(maxHourlyBasalMilliunits: 15000)).cargo,
            "the WRITTEN limit must be capped to 15.0 U/hr (15000 mU) even when 20 U/hr is requested")
    }

    /// Companion: a sub-floor max-basal request is floored to the kit's 1.0 U/hr throwing floor.
    @Test func tandemBackendFloorsTheWrittenMaxBasalLimit() async throws {
        let fake = FakePumpTransport()
        let backend = TandemBackend(testTransport: fake)
        backend.setConnectionForTesting(.connected)
        fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        try await backend.setMaxBasal(unitsPerHour: 0.1)  // below the 1.0 U/hr floor
        let sent = fake.lastSent(SetMaxBasalLimitRequest.props.opCode)
        #expect(sent != nil, "a max-basal-limit write must have gone out")
        #expect(
            sent?.cargo == (try SetMaxBasalLimitRequest(maxHourlyBasalMilliunits: 1000)).cargo,
            "the WRITTEN limit must be floored to 1.0 U/hr (1000 mU) even when 0.1 U/hr is requested")
    }

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
