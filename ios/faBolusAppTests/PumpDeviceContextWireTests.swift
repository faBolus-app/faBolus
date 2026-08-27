import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// **VA-06 (op33 device-context re-wire).** Pins that `PumpResponseApplier` re-wires the kit's
/// device-support MODEL gate every connection cycle, off the op33 `ApiVersionResponse`.
///
/// WHY op33 is the re-wire point: the kit's `client.setDeviceContext(model:)` resets to nil on every link
/// change, and `didDiscover` does NOT re-fire on a silent reconnect — so a bare `.connected` after a
/// background disconnect would leave the model gate un-set, and a Mobi-only / t:slim-only write would be
/// mis-gated. op33 arrives on every connection cycle's bootstrap read, so routing the re-wire through it
/// makes the gate survive a silent reconnect.
///
/// The applier calls `applyDeviceContext(detectedIsMobi() ?? m.isMobi)` (PumpResponseApplier.swift): the
/// BLE-name detection (`detectedIsMobi`, set at discovery) is authoritative and WINS over the op33
/// API-version heuristic; the heuristic (`ApiVersionResponse.isMobi`, true at API 3.5+) is the fallback
/// used only when the name did not identify the model. Both closures are ConnectIQ/BLE-free injected
/// seams, so this drives the REAL applier dispatch (`apply(_:txId:characteristic:)`) directly — no
/// CoreBluetooth, no TandemBackend — mirroring the injected-hook test pattern the applier was built for.
@Suite(.serialized) @MainActor
struct PumpDeviceContextWireTests {

    /// op33 cargo is majorVersion short@0 + minorVersion short@2 (little-endian) — the same layout
    /// `FakePumpTransport.apiVersion(major:minor:)` frames. isMobi is derived: `major > 3 || (major == 3
    /// && minor >= 5)`. 3.5 ⇒ Mobi; 2.5 ⇒ t:slim X2.
    private func apiVersion(major: Int, minor: Int) -> ApiVersionResponse {
        ApiVersionResponse(cargo: Bytes.firstTwoBytesLittleEndian(major) + Bytes.firstTwoBytesLittleEndian(minor))
    }

    /// When the BLE name did NOT identify the model (`detectedIsMobi() == nil`), `applyDeviceContext`
    /// falls back to the op33 API-version heuristic — invoked with the message's own `isMobi`.
    @Test func fallsBackToApiHeuristicWhenNameUnknown() {
        // Mobi API version (3.5) with no name detection ⇒ heuristic says Mobi.
        do {
            let applier = PumpResponseApplier()
            var captured: Bool?
            var apiVer: ApiVersion?
            var trusted: Bool?
            applier.detectedIsMobi = { nil }
            applier.applyDeviceContext = { captured = $0; apiVer = $1; trusted = $2 }
            let mobi = apiVersion(major: 3, minor: 5)
            #expect(mobi.isMobi, "3.5 is the Mobi threshold")
            applier.apply(mobi, txId: 0, characteristic: .currentStatus)
            #expect(captured == true, "name unknown ⇒ device context uses the op33 heuristic (Mobi)")
            #expect(apiVer == ApiVersion(major: 3, minor: 5), "VA-06: the REAL negotiated apiVersion is forwarded (3.5)")
            #expect(trusted == false, "CC-06/C1: the op33 heuristic is NEVER forwarded as trusted")
        }
        // t:slim X2 API version (2.5) with no name detection ⇒ heuristic says NOT Mobi.
        do {
            let applier = PumpResponseApplier()
            var captured: Bool?
            var apiVer: ApiVersion?
            var trusted: Bool?
            applier.detectedIsMobi = { nil }
            applier.applyDeviceContext = { captured = $0; apiVer = $1; trusted = $2 }
            let tslim = apiVersion(major: 2, minor: 5)
            #expect(!tslim.isMobi, "2.5 is t:slim X2, not Mobi")
            applier.apply(tslim, txId: 0, characteristic: .currentStatus)
            #expect(captured == false, "name unknown ⇒ device context uses the op33 heuristic (t:slim)")
            #expect(apiVer == ApiVersion(major: 2, minor: 5), "VA-06: the REAL negotiated apiVersion is forwarded (2.5)")
            #expect(trusted == false, "CC-06/C1: the op33 heuristic is NEVER forwarded as trusted")
        }
    }

    /// The BLE-name detection WINS over the op33 API-version heuristic: when `detectedIsMobi()` returns a
    /// non-nil value, `applyDeviceContext` is called with THAT value even when the message's own `isMobi`
    /// disagrees.
    @Test func bleNameDetectionWinsOverApiHeuristic() {
        // Name says Mobi, but the op33 frame's heuristic says t:slim (2.5) — the name must win. VA-06: the
        // apiVersion forwarded is the frame's own (2.5), independent of the name-derived MODEL.
        do {
            let applier = PumpResponseApplier()
            var captured: Bool?
            var apiVer: ApiVersion?
            var trusted: Bool?
            applier.detectedIsMobi = { true }
            applier.applyDeviceContext = { captured = $0; apiVer = $1; trusted = $2 }
            let tslimByApi = apiVersion(major: 2, minor: 5)
            #expect(!tslimByApi.isMobi, "the heuristic alone would say NOT Mobi")
            applier.apply(tslimByApi, txId: 0, characteristic: .currentStatus)
            #expect(captured == true, "name-detected Mobi must win over the op33 API heuristic")
            #expect(apiVer == ApiVersion(major: 2, minor: 5), "VA-06: apiVersion is the frame's own (2.5), independent of the name-derived model")
            #expect(trusted == true, "CC-06/C1: a name-derived value (fresh or C8-reapplied) is trusted")
        }
        // Name says t:slim, but the op33 frame's heuristic says Mobi (3.5) — the name must win.
        do {
            let applier = PumpResponseApplier()
            var captured: Bool?
            var apiVer: ApiVersion?
            var trusted: Bool?
            applier.detectedIsMobi = { false }
            applier.applyDeviceContext = { captured = $0; apiVer = $1; trusted = $2 }
            let mobiByApi = apiVersion(major: 3, minor: 5)
            #expect(mobiByApi.isMobi, "the heuristic alone would say Mobi")
            applier.apply(mobiByApi, txId: 0, characteristic: .currentStatus)
            #expect(captured == false, "name-detected t:slim must win over the op33 API heuristic")
            #expect(apiVer == ApiVersion(major: 3, minor: 5), "VA-06: apiVersion is the frame's own (3.5), independent of the name-derived model")
            #expect(trusted == true, "CC-06/C1: a name-derived value (fresh or C8-reapplied) is trusted")
        }
    }

    // MARK: - Directional proofs (codex C1/C8/C9/C10) — drive the REAL TandemBackend/PumpConnectionLifecycle
    //
    // These exercise `TandemBackend.applyClientState(_:)` directly (no live CoreBluetooth central needed —
    // `applyClientState` is reachable on a plain `TandemBackend(testTransport:)`), plus the DEBUG test
    // seams Task 1 added (`armReconnectTargetForTesting`/`identityTrustedForTesting`/
    // `connectedPumpModelForTesting`/`identityGateErrorForTesting`), to prove the app-side trust design
    // end-to-end: a real Mobi is never over-gated (before OR after op33), a misidentified t:slim stays
    // fail-closed, and a stale trusted record never trusts a mismatched peripheral.

    /// A [.mobi]-restricted, 0xCE-opcode message — the ONE message the 15.5-01 tracer gate currently
    /// covers — used to probe `identityGateErrorForTesting`.
    private func tracerMessage() -> SetSleepScheduleRequest {
        SetSleepScheduleRequest(slot: 0, schedule: [0, 0, 0, 0, 0, 0], flag: 0)
    }

    /// Hermetic isolation (RESEARCH §A4 / codex C9): `TrustedPumpIdentityStore`/`PumpPeripheralStore` are
    /// UserDefaults-backed and process-global, so seed/target state from one case must never leak into the
    /// next. Each test also constructs its OWN fresh `TandemBackend` (and therefore its own fresh
    /// `PumpBLEClient`, whose `reconnectTargetId` starts nil), so `armReconnectTargetForTesting` state
    /// never crosses cases either.
    private func resetIdentityStores() {
        TrustedPumpIdentityStore.clear()
        PumpPeripheralStore.clear()
    }

    /// codex C1 (necessary, per C9 NOT sufficient by itself — see the next test): a persisted trusted
    /// Mobi is reapplied on `.discovering`, before op33 — asserts state IMMEDIATELY after `.discovering`.
    @Test func trustedModelIsReappliedOnDiscoveringForKnownPeripheral() {
        resetIdentityStores()
        let uuid = UUID()
        PumpPeripheralStore.set(uuid)
        TrustedPumpIdentityStore.set(isMobi: true, for: uuid)
        let b = TandemBackend(testTransport: FakePumpTransport())
        b.armReconnectTargetForTesting(uuid)

        b.applyClientState(.discovering)

        #expect(b.connectedPumpModelForTesting == .mobi, "the persisted trusted Mobi is reapplied on .discovering")
        #expect(b.identityTrustedForTesting == true, "reapply stamps TRUSTED, not merely a non-nil model")
    }

    /// codex C8/C9 (the BLOCKER fix + its directional proof): the reapplied trust must SURVIVE a REAL
    /// op33 arriving later the SAME silent-reconnect cycle. This is the test that actually exercises the
    /// C8 clobber path — `trustedModelIsReappliedOnDiscoveringForKnownPeripheral` above asserts state
    /// BEFORE op33 and so cannot, by itself, catch a design where op33 later clobbers the trust back to
    /// false. Injects a REAL op33 frame (API 3.5, `m.isMobi == true`) through `injectStatusFrameForTesting`
    /// so the production op33 path runs against the REAL `detectedIsMobi` closure (not stubbed) — its
    /// value must come from reapply's C8 restore. MUST FAIL against the pre-C8-fix design (op33 would
    /// recompute `nameTrusted == false` because `detectedIsMobi` stayed nil, clobbering trust); passes only
    /// because reapply restores `detectedIsMobi` before op33 runs.
    @Test func realMobiStaysTrustedWhenOp33ArrivesAfterReapply() {
        resetIdentityStores()
        let uuid = UUID()
        PumpPeripheralStore.set(uuid)
        TrustedPumpIdentityStore.set(isMobi: true, for: uuid)
        let b = TandemBackend(testTransport: FakePumpTransport())
        b.armReconnectTargetForTesting(uuid)

        b.applyClientState(.discovering)
        #expect(b.identityTrustedForTesting == true, "precondition: reapply stamped trust before op33")

        b.injectStatusFrameForTesting(FakePumpTransport.apiVersion(major: 3, minor: 5))   // REAL op33, arrives later this cycle

        #expect(b.identityTrustedForTesting == true, "codex C8: op33 must NOT clobber the reapplied trust back to false")
        #expect(b.identityGateErrorForTesting(tracerMessage()) == nil,
                "a real, trusted Mobi's [.mobi]-restricted 0xCE send must NOT be gated")
    }

    /// codex C1 (the fail-closed direction): with NO persisted trusted record, a t:slim misidentified as
    /// Mobi by the op33 API-version heuristic (API ≥3.5) stays UNTRUSTED — `connectedPumpModel` may still
    /// become `.mobi` (VA-06's own device-support gate is unaffected by trust), but the identity gate
    /// refuses the [.mobi]-restricted send.
    @Test func misidentifiedTslimStaysUntrustedThroughSilentReconnect() {
        resetIdentityStores()
        let b = TandemBackend(testTransport: FakePumpTransport())

        b.applyClientState(.discovering)   // no persisted record ⇒ reapply is a no-op

        b.injectStatusFrameForTesting(FakePumpTransport.apiVersion(major: 3, minor: 5))   // the exact t:slim-reporting-API-3.5 fixture

        #expect(b.connectedPumpModelForTesting == .mobi, "VA-06 unaffected: the heuristic still identifies a model")
        #expect(b.identityTrustedForTesting == false, "the op33 heuristic can never satisfy the trust bit")
        #expect(b.identityGateErrorForTesting(tracerMessage()) == .identityNotEstablished(opcode: SetSleepScheduleRequest.props.opCode),
                "a misidentified t:slim's Mobi-only send must fail closed")
    }

    // MARK: - VA-06 (tslim-reconnect-loop Phase B): op33 supplies the REAL apiVersion → the kit floors bite
    //
    // Reverses the CX-T-04/VA-06 deferral. Before this change `setDeviceContext` was called with
    // `apiVersion: nil`, so every `minApi` floor was inert (fail-open). These drive the REAL op33 path
    // (`injectStatusFrameForTesting`) through a real `TandemBackend` and assert (a) the negotiated
    // apiVersion is now the exact value op33 reported, (b) a below-floor read is now FILTERED on the
    // API-2.5 t:slim (the gate bites), and (c) a Mobi (API ≥ floor) is NOT regressed — its reads still
    // pass. `LoadStatusRequest` (op20) carries the conservative `.benchConservativeUnverifiedFloor`
    // (v3.4) floor; `CgmStatusV2Request` is `[.mobi]` + `mobi_v3_5`.

    /// The API-2.5 t:slim: op33 makes the negotiated apiVersion (2,5) live, so a below-3.4-floor read
    /// (op20) is now refused by the device/API send gate — pre-op33 it fails OPEN (nil apiVersion).
    @Test func va06_op33SuppliesRealApiVersion_soBelowFloorReadIsFilteredOnApi25Tslim() {
        resetIdentityStores()
        let b = TandemBackend(testTransport: FakePumpTransport())

        // Pre-op33: apiVersion is nil ⇒ the floor fails OPEN (today's send-then-NACK behavior).
        #expect(b.negotiatedApiVersionForTesting == nil, "no apiVersion negotiated before op33")
        #expect(b.deviceSupportErrorForTesting(LoadStatusRequest()) == nil,
                "pre-op33 the minApi floor fails open (nil apiVersion) — behavior-preserving")

        b.injectStatusFrameForTesting(FakePumpTransport.apiVersion(major: 2, minor: 5))   // REAL op33

        #expect(b.negotiatedApiVersionForTesting == ApiVersion(major: 2, minor: 5),
                "VA-06: op33 supplies the REAL negotiated apiVersion (2.5), not nil")
        #expect(b.connectedPumpModelForTesting == .tslim, "op33 (2.5) identifies a t:slim")
        #expect(b.deviceSupportErrorForTesting(LoadStatusRequest())
                    == .unsupportedOnDevice(opcode: LoadStatusRequest.props.opCode),
                "VA-06 now BITES: op20 (minApi 3.4) is filtered on the API-2.5 t:slim — no send, no op-77, no teardown")
    }

    /// A Mobi (API 3.5) must NOT be regressed by VA-06: its own reads still pass the gate. Proves the
    /// floor is evaluated per-dimension and a supported target is never over-gated.
    @Test func va06_mobiIsNotRegressed_itsReadsStillPassTheGate() {
        resetIdentityStores()
        let b = TandemBackend(testTransport: FakePumpTransport())

        b.injectStatusFrameForTesting(FakePumpTransport.apiVersion(major: 3, minor: 5))   // REAL op33 (Mobi)

        #expect(b.negotiatedApiVersionForTesting == ApiVersion(major: 3, minor: 5),
                "VA-06: op33 supplies the REAL negotiated apiVersion (3.5)")
        #expect(b.connectedPumpModelForTesting == .mobi, "op33 (3.5) identifies a Mobi")
        // A Mobi-restricted read ([.mobi], minApi 3.5) is SUPPORTED on a Mobi at 3.5 — not filtered.
        #expect(b.deviceSupportErrorForTesting(CgmStatusV2Request()) == nil,
                "VA-06 must NOT regress Mobi: a [.mobi] / minApi-3.5 read still passes on a Mobi at 3.5")
        // And the below-floor-on-t:slim read op20 is FINE on the Mobi (3.5 ≥ 3.4) — the floor is per-API.
        #expect(b.deviceSupportErrorForTesting(LoadStatusRequest()) == nil,
                "op20 (minApi 3.4) is supported on a Mobi at API 3.5 — the gate is API-floored, not blanket")
    }

    /// codex C10: reapply must confirm the peripheral the kit is ACTUALLY (re)connecting before stamping
    /// trust — a persisted trusted record for UUID-A must NOT be applied to a session whose kit
    /// `reconnectTargetId` is a DIFFERENT UUID-B (pump-swap-mid-reconnect / a restoration adopting a
    /// different peripheral).
    @Test func reapplyDoesNotTrustAMismatchedPeripheral() {
        resetIdentityStores()
        let uuidA = UUID(), uuidB = UUID()
        PumpPeripheralStore.set(uuidA)
        TrustedPumpIdentityStore.set(isMobi: true, for: uuidA)
        let b = TandemBackend(testTransport: FakePumpTransport())
        b.armReconnectTargetForTesting(uuidB)   // the kit is reconnecting a DIFFERENT peripheral

        b.applyClientState(.discovering)

        #expect(b.identityTrustedForTesting == false, "a stale trusted record for UUID-A must not trust a UUID-B session")
    }
}
