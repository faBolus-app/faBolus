import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// `validateDeliver` fails closed unless the identified family is t:slim X2, before any signed frame
/// is written — even a connected, paired, cartridge-ready Mobi or an unidentified pump.
@Suite(.serialized) @MainActor
struct PumpFamilyPreflightFailClosedTests {

    private static let bolusId = 4242
    /// The SENT-frame opcode for the delivery write (`sent`/`lastSent` record requests, not responses).
    private let initiateRequestOp = InitiateBolusRequest.props.opCode

    /// A connected + paired backend (via `init(testTransport:)`, which also defaults `therapyParamsDate`
    /// to "already read"), with a fully-scripted accept→complete delivery and the default idle/ready
    /// cartridge (load state 6) — i.e. everything a below-max dose needs. The ONLY thing a test then
    /// varies is the identified pump family, set via an injected `apiVersion` frame (or left `.unknown`).
    private func makeDeliverableBackend() -> (TandemBackend, FakePumpTransport) {
        let fake = FakePumpTransport()
        let backend = TandemBackend(testTransport: fake)
        fake.script(TimeSinceResetResponse.props.opCode, .frame(FakePumpTransport.timeResponse()))
        fake.script(
            BolusPermissionResponse.props.opCode, .frame(FakePumpTransport.permissionGranted(bolusId: Self.bolusId)))
        fake.script(
            InitiateBolusResponse.props.opCode, .frame(FakePumpTransport.initiateAccepted(bolusId: Self.bolusId)))
        fake.script(
            CurrentBolusStatusResponse.props.opCode,
            .frame(FakePumpTransport.currentBolusStatus(statusId: 0, bolusId: Self.bolusId)))
        fake.script(
            LastBolusStatusV2Response.props.opCode,
            .frame(FakePumpTransport.lastBolus(bolusId: Self.bolusId, deliveredMilliunits: 2000)))
        return (backend, fake)
    }

    private func capture(_ op: () async throws -> Double) async -> Error? {
        do {
            _ = try await op()
            return nil
        } catch { return error }
    }

    /// Assert a delivery attempt was fail-closed by the family preflight: it threw `.pumpRejected` carrying
    /// the exact Mobi-not-supported copy (pinning THIS guard, not the "not paired"/freshness `.pumpRejected`
    /// sites), wrote NO signed frame (not even the permission ask — the guard precedes it), and left the
    /// backend un-blocked (a clean pre-write refusal, never an indeterminate hold).
    private func expectFamilyRejectNoWrite(_ e: Error?, _ fake: FakePumpTransport, _ b: TandemBackend) {
        guard case .pumpRejected(let message)? = e as? BolusError else {
            Issue.record("expected BolusError.pumpRejected from the family preflight, got \(String(describing: e))")
            return
        }
        #expect(
            message == MobiRejectCopy.mobiNotSupported,
            "the family guard must reject with the Mobi-not-supported copy")
        #expect(
            fake.sent.filter { $0.opCode == BolusPermissionRequest.props.opCode }.isEmpty,
            "no permission request may be written for a family-rejected attempt")
        #expect(fake.initiateWriteCount == 0, "no initiate request may be written for a family-rejected attempt")
        #expect(fake.lastSent(initiateRequestOp) == nil, "no InitiateBolus frame may reach the wire")
        #expect(!b.deliveryOutcomeUnknown, "a clean pre-write refusal, never an indeterminate block")
    }

    // MARK: - fail closed: a Mobi is blocked on every delivery surface

    /// A Mobi that is otherwise fully deliverable (connected, paired, op-115 read, cartridge idle, dose in
    /// limit, a full accept→complete script queued) is rejected on BOTH the standard and the extended
    /// funnel — the two public deliver entry points that share `validateDeliver`.
    @Test func mobiIsBlockedOnStandardAndExtendedDeliverDespiteOtherwiseDeliverable() async {
        let (b, fake) = makeDeliverableBackend()
        b.injectStatusFrameForTesting(FakePumpTransport.apiVersion(major: 4, minor: 0))  // → isMobi=true ⇒ .mobi
        #expect(b.snapshot.pumpModel == .mobi, "op33 (API 4.0) identifies the pump as a Mobi")

        // Standard bolus funnel.
        let e1 = await capture { try await b.deliverBolus(units: 2.0, carbsGrams: nil, bgMgdl: nil, iobUnits: nil) }
        expectFamilyRejectNoWrite(e1, fake, b)

        // Extended (combo) bolus funnel — same `validateDeliver` chokepoint, same fail-closed outcome.
        let e2 = await capture {
            try await b.deliverExtendedBolus(
                totalUnits: 2.0, nowUnits: 1.0, durationMinutes: 120,
                carbsGrams: nil, bgMgdl: nil, iobUnits: nil)
        }
        expectFamilyRejectNoWrite(e2, fake, b)
    }

    // MARK: - fail closed: a not-yet-identified (.unknown) pump is blocked

    /// The guard also blocks `.unknown` (family never identified). A fresh `testTransport` backend has an
    /// empty `pumpModelName`, so no injected `apiVersion` frame ⇒ `.unknown` ⇒ fail-closed on both funnels,
    /// even though everything else is delivery-ready.
    @Test func unknownFamilyIsBlockedOnStandardAndExtendedDeliver() async {
        let (b, fake) = makeDeliverableBackend()
        // Force the never-identified state (the test-double now defaults to t:slim X2): clear the family so
        // pumpModelName == "" ⇒ .unknown, without injecting any op33 identity frame.
        b.setPumpModelIdentityForTesting(pumpModelName: "", isMobi: false)
        #expect(
            b.snapshot.pumpModel == .unknown,
            "a not-yet-identified pump (empty pumpModelName) resolves to .unknown")

        let e1 = await capture { try await b.deliverBolus(units: 2.0, carbsGrams: nil, bgMgdl: nil, iobUnits: nil) }
        expectFamilyRejectNoWrite(e1, fake, b)

        let e2 = await capture {
            try await b.deliverExtendedBolus(
                totalUnits: 2.0, nowUnits: 1.0, durationMinutes: 120,
                carbsGrams: nil, bgMgdl: nil, iobUnits: nil)
        }
        expectFamilyRejectNoWrite(e2, fake, b)
    }

    // MARK: - positive control: a t:slim X2 with the SAME otherwise-deliverable state delivers

    /// The guard is exactly `== .tslimX2`, NOT a blanket block: an identified t:slim X2 — otherwise
    /// state-identical to the rejected cases above — passes the family preflight and delivers the full
    /// scripted dose, reaching (and completing) the initiate write.
    @Test func tslimX2WithIdenticalStateDeliversAndReachesTheWrite() async throws {
        let (b, fake) = makeDeliverableBackend()
        b.injectStatusFrameForTesting(FakePumpTransport.apiVersion(major: 2, minor: 5))  // → isMobi=false ⇒ .tslimX2
        #expect(b.snapshot.pumpModel == .tslimX2, "op33 (API 2.5) identifies the pump as a t:slim X2")

        let delivered = try await b.deliverBolus(units: 2.0, carbsGrams: nil, bgMgdl: nil, iobUnits: nil)
        #expect(delivered == 2.0, "the family preflight must not block a genuine t:slim X2")
        #expect(fake.initiateWriteCount == 1, "the t:slim X2 delivery reaches the initiate write")
        #expect(!b.deliveryOutcomeUnknown)
    }
}
