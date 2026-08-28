import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// **Regression: `tslim-misidentified-as-mobi`** (debug session
/// `.planning/debug/tslim-misidentified-as-mobi.md`).
///
/// A real, paired t:slim X2 was refused with "Tandem Mobi isn't supported…" on every bolus after an
/// ordinary cold launch. Root cause (Phase 15.5): on the fast `connectKnownPeripheral` reconnect (taken
/// once a `TrustedPumpIdentityStore` record exists) `didDiscover` never fires, so `applyDidDiscover` —
/// the only writer of `snapshot.pumpModelName` from the BLE name — is skipped.
/// `reapplyTrustedIdentityIfKnown()` restored ONLY the PRIVATE `detectedIsMobi` (and the kit device
/// context), not the PUBLISHED `snapshot.isMobi`/`snapshot.pumpModelName`. op33 then skipped its own
/// name assignment (it is guarded by `if detectedIsMobi() == nil`), so `snapshot.pumpModelName` stayed
/// empty → `snapshot.pumpModel == .unknown` → `validateDeliver`'s family gate
/// (`guard snapshot.pumpModel == .tslimX2`) threw `MobiRejectCopy.mobiNotSupported` for a genuine t:slim.
///
/// These drive the REAL fast-path reconnect (`armReconnectTargetForTesting` +
/// `applyClientState(.discovering)` → reapply) followed by a REAL op33 frame, from the realistic
/// cold-launch state (empty published model, nil name-authority signal). No live CoreBluetooth central.
@Suite(.serialized) @MainActor
struct TslimFastPathReconnectIdentityRegressionTests {

    private static let bolusId = 4242
    private let initiateRequestOp = InitiateBolusRequest.props.opCode

    /// Hermetic isolation (RESEARCH §A4 / codex C9): the identity stores are UserDefaults-backed and
    /// process-global, so seed state from one case must never leak into the next.
    private func resetIdentityStores() {
        TrustedPumpIdentityStore.clear()
        PumpPeripheralStore.clear()
    }

    /// A connected + paired backend with a fully-scripted accept→complete delivery and the default
    /// idle/ready cartridge — everything a below-max dose needs. Mirrors `PumpFamilyPreflightFailClosedTests`.
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

    /// Put the backend into the realistic cold-launch reconnect state: a prior `didDiscover` established
    /// the peripheral's trusted model (persisted), but THIS launch has not run `didDiscover` yet — so the
    /// published model is empty (`.unknown`) and the private name-authority signal is nil. `.scanning`
    /// (not the artificial `.connected` the test-double defaults to) so `applyClientState(.discovering)`'s
    /// `wasLive` teardown does not fire — faithfully modelling a cold-launch fast-path reconnect.
    private func armColdLaunchFastPath(_ b: TandemBackend, uuid: UUID) {
        b.setPumpModelIdentityForTesting(pumpModelName: "", isMobi: false)
        b.detectedIsMobiForTesting = nil
        b.setConnectionForTesting(.scanning)
        b.armReconnectTargetForTesting(uuid)  // connectKnownPeripheral armed the kit's reconnectTargetId
    }

    // MARK: - the regression: a paired t:slim reconnecting via the fast path must resolve to .tslimX2

    /// THE failing case. Persisted trusted t:slim record → fast path → reapply → op33 (2.5). Before the
    /// fix `snapshot.pumpModel` is `.unknown` (reapply left `pumpModelName` empty and op33 skipped it);
    /// after the fix reapply restores the published model so it is `.tslimX2`.
    @Test func tslimReconnectViaFastPathResolvesToTslimX2NotUnknown() {
        resetIdentityStores()
        let uuid = UUID()
        PumpPeripheralStore.set(uuid)
        TrustedPumpIdentityStore.set(isMobi: false, for: uuid)  // a genuine prior didDiscover identified a t:slim
        let b = TandemBackend(testTransport: FakePumpTransport())
        armColdLaunchFastPath(b, uuid: uuid)
        #expect(b.snapshot.pumpModel == .unknown, "precondition: fresh cold launch, model not yet published")

        b.applyClientState(.discovering)  // fires reapplyTrustedIdentityIfKnown()
        b.injectStatusFrameForTesting(FakePumpTransport.apiVersion(major: 2, minor: 5))  // REAL op33 (t:slim, API 2.5)

        #expect(
            b.snapshot.pumpModel == .tslimX2,
            "a paired t:slim reconnecting via the fast path must resolve to .tslimX2, never .unknown")
        #expect(!b.snapshot.isMobi, "the restored published identity must be t:slim, not Mobi")
    }

    /// End-to-end consequence: the same fast-path reconnect must NOT be Mobi-rejected at the delivery
    /// chokepoint — a genuine t:slim delivers the full scripted dose and reaches the initiate write.
    @Test func tslimReconnectViaFastPathDeliversAndIsNotFamilyRejected() async throws {
        resetIdentityStores()
        let uuid = UUID()
        PumpPeripheralStore.set(uuid)
        TrustedPumpIdentityStore.set(isMobi: false, for: uuid)
        let (b, fake) = makeDeliverableBackend()
        armColdLaunchFastPath(b, uuid: uuid)

        b.applyClientState(.discovering)
        b.injectStatusFrameForTesting(FakePumpTransport.apiVersion(major: 2, minor: 5))
        b.setConnectionForTesting(.connected)  // reconnect completed + polling resumed (markUsableAndStartPolling)

        let delivered = try await b.deliverBolus(units: 2.0, carbsGrams: nil, bgMgdl: nil, iobUnits: nil)
        #expect(delivered == 2.0, "a genuine t:slim reconnecting via the fast path must not be Mobi-rejected")
        #expect(fake.initiateWriteCount == 1, "the t:slim delivery reaches the initiate write")
        #expect(!b.deliveryOutcomeUnknown, "a clean delivery, never an indeterminate hold")
    }

    // MARK: - boundary neighbor: a paired Mobi reconnecting via the fast path must resolve to .mobi
    //
    // Proves the fix restores the PERSISTED model faithfully in BOTH directions — it is not a t:slim
    // hardcode. A trusted Mobi record must still resolve to `.mobi` (which the delivery family gate then
    // correctly refuses); the fix must not silently reclassify a Mobi as t:slim.

    @Test func mobiReconnectViaFastPathResolvesToMobiNotUnknown() {
        resetIdentityStores()
        let uuid = UUID()
        PumpPeripheralStore.set(uuid)
        TrustedPumpIdentityStore.set(isMobi: true, for: uuid)  // a genuine prior didDiscover identified a Mobi
        let b = TandemBackend(testTransport: FakePumpTransport())
        armColdLaunchFastPath(b, uuid: uuid)

        b.applyClientState(.discovering)
        b.injectStatusFrameForTesting(FakePumpTransport.apiVersion(major: 3, minor: 5))  // REAL op33 (Mobi, API 3.5)

        #expect(
            b.snapshot.pumpModel == .mobi,
            "the fix must restore the persisted model faithfully — a trusted Mobi resolves to .mobi, not .unknown or .tslimX2"
        )
        #expect(b.snapshot.isMobi, "the restored published identity must be Mobi")
    }
}
