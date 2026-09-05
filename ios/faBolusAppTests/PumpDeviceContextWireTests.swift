import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// op33 re-wires the kit model gate every connection cycle because `didDiscover` does not re-fire on
/// a silent reconnect; BLE-name detection wins over the API-version heuristic, which is never
/// forwarded as trusted. A pairing that predates the trust store must scan so a genuine `didDiscover`
/// writes the name-derived record before any model-restricted send.
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
            let applier = PumpResponseApplier(resolveBadOpcodeForError: { requestCodeId, _, _ in
                UInt8(truncatingIfNeeded: requestCodeId)
            })
            var captured: Bool?
            var apiVer: ApiVersion?
            var trusted: Bool?
            applier.detectedIsMobi = { nil }
            applier.applyDeviceContext = {
                captured = $0
                apiVer = $1
                trusted = $2
            }
            let mobi = apiVersion(major: 3, minor: 5)
            #expect(mobi.isMobi, "3.5 is the Mobi threshold")
            applier.apply(mobi, txId: 0, characteristic: .currentStatus)
            #expect(captured == true, "name unknown ⇒ device context uses the op33 heuristic (Mobi)")
            #expect(
                apiVer == ApiVersion(major: 3, minor: 5), "the REAL negotiated apiVersion is forwarded (3.5)")
            #expect(trusted == false, "the op33 heuristic is NEVER forwarded as trusted")
        }
        // t:slim X2 API version (2.5) with no name detection ⇒ heuristic says NOT Mobi.
        do {
            let applier = PumpResponseApplier(resolveBadOpcodeForError: { requestCodeId, _, _ in
                UInt8(truncatingIfNeeded: requestCodeId)
            })
            var captured: Bool?
            var apiVer: ApiVersion?
            var trusted: Bool?
            applier.detectedIsMobi = { nil }
            applier.applyDeviceContext = {
                captured = $0
                apiVer = $1
                trusted = $2
            }
            let tslim = apiVersion(major: 2, minor: 5)
            #expect(!tslim.isMobi, "2.5 is t:slim X2, not Mobi")
            applier.apply(tslim, txId: 0, characteristic: .currentStatus)
            #expect(captured == false, "name unknown ⇒ device context uses the op33 heuristic (t:slim)")
            #expect(
                apiVer == ApiVersion(major: 2, minor: 5), "the REAL negotiated apiVersion is forwarded (2.5)")
            #expect(trusted == false, "the op33 heuristic is NEVER forwarded as trusted")
        }
    }

    /// The BLE-name detection WINS over the op33 API-version heuristic: when `detectedIsMobi()` returns a
    /// non-nil value, `applyDeviceContext` is called with THAT value even when the message's own `isMobi`
    /// disagrees.
    @Test func bleNameDetectionWinsOverApiHeuristic() {
        // Name says Mobi, but the op33 frame's heuristic says t:slim (2.5) — the name must win.
        // The apiVersion forwarded is the frame's own (2.5), independent of the name-derived model.
        do {
            let applier = PumpResponseApplier(resolveBadOpcodeForError: { requestCodeId, _, _ in
                UInt8(truncatingIfNeeded: requestCodeId)
            })
            var captured: Bool?
            var apiVer: ApiVersion?
            var trusted: Bool?
            applier.detectedIsMobi = { true }
            applier.applyDeviceContext = {
                captured = $0
                apiVer = $1
                trusted = $2
            }
            let tslimByApi = apiVersion(major: 2, minor: 5)
            #expect(!tslimByApi.isMobi, "the heuristic alone would say NOT Mobi")
            applier.apply(tslimByApi, txId: 0, characteristic: .currentStatus)
            #expect(captured == true, "name-detected Mobi must win over the op33 API heuristic")
            #expect(
                apiVer == ApiVersion(major: 2, minor: 5),
                "apiVersion is the frame's own (2.5), independent of the name-derived model")
            #expect(trusted == true, "a name-derived value (fresh or trusted-record-reapplied) is trusted")
        }
        // Name says t:slim, but the op33 frame's heuristic says Mobi (3.5) — the name must win.
        do {
            let applier = PumpResponseApplier(resolveBadOpcodeForError: { requestCodeId, _, _ in
                UInt8(truncatingIfNeeded: requestCodeId)
            })
            var captured: Bool?
            var apiVer: ApiVersion?
            var trusted: Bool?
            applier.detectedIsMobi = { false }
            applier.applyDeviceContext = {
                captured = $0
                apiVer = $1
                trusted = $2
            }
            let mobiByApi = apiVersion(major: 3, minor: 5)
            #expect(mobiByApi.isMobi, "the heuristic alone would say Mobi")
            applier.apply(mobiByApi, txId: 0, characteristic: .currentStatus)
            #expect(captured == false, "name-detected t:slim must win over the op33 API heuristic")
            #expect(
                apiVer == ApiVersion(major: 3, minor: 5),
                "apiVersion is the frame's own (3.5), independent of the name-derived model")
            #expect(trusted == true, "a name-derived value (fresh or trusted-record-reapplied) is trusted")
        }
    }

    // MARK: - Directional proofs — drive the real TandemBackend reconnect path
    //
    // Exercise `TandemBackend.applyClientState(_:)` directly (no live CoreBluetooth). A real Mobi is
    // never over-gated (before or after op33), a misidentified t:slim stays fail-closed, and a stale
    // trusted record never trusts a mismatched peripheral.

    /// A [.mobi]-restricted, 0xCE-opcode message used to probe `identityGateErrorForTesting`.
    private func tracerMessage() -> SetSleepScheduleRequest {
        SetSleepScheduleRequest(slot: 0, schedule: [0, 0, 0, 0, 0, 0], flag: 0)
    }

    /// Hermetic isolation: `TrustedPumpIdentityStore`/`PumpPeripheralStore` are UserDefaults-backed and
    /// process-global, so seed/target state from one case must never leak into the next. Each test also
    /// constructs its own fresh `TandemBackend`.
    private func resetIdentityStores() {
        TrustedPumpIdentityStore.clear()
        PumpPeripheralStore.clear()
    }

    /// A persisted trusted Mobi is reapplied on `.discovering`, before op33.
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

    /// Reapplied trust must survive a real op33 arriving later in the same silent-reconnect cycle;
    /// otherwise op33 would recompute `nameTrusted == false` (because `detectedIsMobi` stayed nil) and
    /// clobber trust.
    @Test func realMobiStaysTrustedWhenOp33ArrivesAfterReapply() {
        resetIdentityStores()
        let uuid = UUID()
        PumpPeripheralStore.set(uuid)
        TrustedPumpIdentityStore.set(isMobi: true, for: uuid)
        let b = TandemBackend(testTransport: FakePumpTransport())
        b.armReconnectTargetForTesting(uuid)

        b.applyClientState(.discovering)
        #expect(b.identityTrustedForTesting == true, "precondition: reapply stamped trust before op33")

        b.injectStatusFrameForTesting(FakePumpTransport.apiVersion(major: 3, minor: 5))  // REAL op33, arrives later this cycle

        #expect(
            b.identityTrustedForTesting == true, "op33 must NOT clobber the reapplied trust back to false")
        #expect(
            b.identityGateErrorForTesting(tracerMessage()) == nil,
            "a real, trusted Mobi's [.mobi]-restricted 0xCE send must NOT be gated")
    }

    /// With no persisted trusted record, a t:slim misidentified as Mobi by the op33 API-version
    /// heuristic stays untrusted — `connectedPumpModel` may still become `.mobi`, but the identity
    /// gate refuses the [.mobi]-restricted send.
    @Test func misidentifiedTslimStaysUntrustedThroughSilentReconnect() {
        resetIdentityStores()
        let b = TandemBackend(testTransport: FakePumpTransport())

        b.applyClientState(.discovering)  // no persisted record ⇒ reapply is a no-op

        b.injectStatusFrameForTesting(FakePumpTransport.apiVersion(major: 3, minor: 5))  // the exact t:slim-reporting-API-3.5 fixture

        #expect(
            b.connectedPumpModelForTesting == .mobi,
            "real-apiVersion forwarding unaffected: the heuristic still identifies a model")
        #expect(b.identityTrustedForTesting == false, "the op33 heuristic can never satisfy the trust bit")
        #expect(
            b.identityGateErrorForTesting(tracerMessage())
                == .identityNotEstablished(opcode: SetSleepScheduleRequest.props.opCode),
            "a misidentified t:slim's Mobi-only send must fail closed")
    }

    // MARK: - op33 supplies the real apiVersion so the kit floors bite
    //
    // Before this, `setDeviceContext` was called with `apiVersion: nil`, so every `minApi` floor was
    // inert (fail-open). op33 must supply the negotiated version so a below-floor read is filtered on
    // API-2.5 t:slim, and a Mobi at or above the floor is not over-gated.

    /// The API-2.5 t:slim: op33 makes the negotiated apiVersion (2,5) live, so a below-3.4-floor read
    /// (op20) is refused by the device/API send gate — pre-op33 it fails open (nil apiVersion).
    @Test func va06_op33SuppliesRealApiVersion_soBelowFloorReadIsFilteredOnApi25Tslim() {
        resetIdentityStores()
        let b = TandemBackend(testTransport: FakePumpTransport())

        // Pre-op33: apiVersion is nil ⇒ the floor fails OPEN (today's send-then-NACK behavior).
        #expect(b.negotiatedApiVersionForTesting == nil, "no apiVersion negotiated before op33")
        #expect(
            b.deviceSupportErrorForTesting(LoadStatusRequest()) == nil,
            "pre-op33 the minApi floor fails open (nil apiVersion) — behavior-preserving")

        b.injectStatusFrameForTesting(FakePumpTransport.apiVersion(major: 2, minor: 5))  // REAL op33

        #expect(
            b.negotiatedApiVersionForTesting == ApiVersion(major: 2, minor: 5),
            "op33 supplies the REAL negotiated apiVersion (2.5), not nil")
        #expect(b.connectedPumpModelForTesting == .tslim, "op33 (2.5) identifies a t:slim")
        #expect(
            b.deviceSupportErrorForTesting(LoadStatusRequest())
                == .unsupportedOnDevice(opcode: LoadStatusRequest.props.opCode),
            "the minApi floor now BITES: op20 (minApi 3.4) is filtered on the API-2.5 t:slim — no send, no op-77, no teardown"
        )
    }

    /// A Mobi (API 3.5) must not be over-gated: its own reads still pass. The floor is evaluated
    /// per-dimension.
    @Test func va06_mobiIsNotRegressed_itsReadsStillPassTheGate() {
        resetIdentityStores()
        let b = TandemBackend(testTransport: FakePumpTransport())

        b.injectStatusFrameForTesting(FakePumpTransport.apiVersion(major: 3, minor: 5))  // REAL op33 (Mobi)

        #expect(
            b.negotiatedApiVersionForTesting == ApiVersion(major: 3, minor: 5),
            "op33 supplies the REAL negotiated apiVersion (3.5)")
        #expect(b.connectedPumpModelForTesting == .mobi, "op33 (3.5) identifies a Mobi")
        // A Mobi-restricted read ([.mobi], minApi 3.5) is SUPPORTED on a Mobi at 3.5 — not filtered.
        #expect(
            b.deviceSupportErrorForTesting(CgmStatusV2Request()) == nil,
            "the real-apiVersion gate must NOT regress Mobi: a [.mobi] / minApi-3.5 read still passes on a Mobi at 3.5")
        // And the below-floor-on-t:slim read op20 is FINE on the Mobi (3.5 ≥ 3.4) — the floor is per-API.
        #expect(
            b.deviceSupportErrorForTesting(LoadStatusRequest()) == nil,
            "op20 (minApi 3.4) is supported on a Mobi at API 3.5 — the gate is API-floored, not blanket")
    }

    /// Reapply must confirm the peripheral the kit is actually (re)connecting before stamping trust —
    /// a persisted trusted record for UUID-A must not be applied to a session whose `reconnectTargetId`
    /// is a different UUID-B.
    @Test func reapplyDoesNotTrustAMismatchedPeripheral() {
        resetIdentityStores()
        let uuidA = UUID(), uuidB = UUID()
        PumpPeripheralStore.set(uuidA)
        TrustedPumpIdentityStore.set(isMobi: true, for: uuidA)
        let b = TandemBackend(testTransport: FakePumpTransport())
        b.armReconnectTargetForTesting(uuidB)  // the kit is reconnecting a DIFFERENT peripheral

        b.applyClientState(.discovering)

        #expect(
            b.identityTrustedForTesting == false, "a stale trusted record for UUID-A must not trust a UUID-B session")
    }

    // MARK: - Forced one-time authoritative re-scan when peripheral is known but trust store is empty
    //
    // A pairing that predates this build has a `PumpPeripheralStore.id()` but no
    // `TrustedPumpIdentityStore` entry, so `connect()` must scan (a genuine `didDiscover`) instead of
    // the fast path — which would leave the trust store empty and refuse every [.mobi]-restricted op.

    /// The upgrade day-zero state: `PumpPeripheralStore` has an id, `TrustedPumpIdentityStore` is empty.
    /// `connect()` must FORCE a full scan (not the fast path) so a genuine `didDiscover` writes the
    /// authoritative name-derived trusted record before any Mobi-op send.
    @Test func connectForcesAuthoritativeScanWhenPeripheralKnownButTrustStoreEmpty() async {
        resetIdentityStores()
        let uuid = UUID()
        PumpPeripheralStore.set(uuid)  // pre-existing pairing…
        // …but NO TrustedPumpIdentityStore entry (the day-zero-upgrade state).
        #expect(TrustedPumpIdentityStore.isMobi(for: uuid) == nil, "precondition: empty trust store")
        let b = TandemBackend(testTransport: FakePumpTransport())

        await b.connect()

        #expect(
            b.lastConnectRouteForTesting == .scan,
            "with a known peripheral but empty trust store, connect() must SCAN (force a genuine didDiscover), NOT take the fast connectKnownPeripheral path"
        )
    }

    /// The complementary steady state: once a trusted record exists for the known peripheral, `connect()`
    /// resumes the fast `connectKnownPeripheral` path automatically.
    @Test func connectTakesFastPathOnceTrustedRecordExists() async {
        resetIdentityStores()
        let uuid = UUID()
        PumpPeripheralStore.set(uuid)
        TrustedPumpIdentityStore.set(isMobi: true, for: uuid)  // a genuine prior didDiscover ran
        let b = TandemBackend(testTransport: FakePumpTransport())

        await b.connect()

        #expect(
            b.lastConnectRouteForTesting == .known,
            "with a trusted record present, connect() resumes the fast connectKnownPeripheral path")
    }

    /// First-ever pairing (no stored peripheral id at all) still scans — unchanged behavior.
    @Test func connectScansWhenNoPeripheralIdAtAll() async {
        resetIdentityStores()  // no PumpPeripheralStore.id()
        let b = TandemBackend(testTransport: FakePumpTransport())

        await b.connect()

        #expect(
            b.lastConnectRouteForTesting == .scan,
            "first-ever pairing (no stored peripheral id) scans, as before")
    }

    // No dedicated "nil/unknown-target no-op preserves a pre-set `detectedIsMobi`" test here, and that
    // is deliberate — do NOT re-add one. Its precondition is not reproducible in this test host: a
    // fresh `PumpBLEClient(restoreIdentifier:)` can come up with a NON-nil `reconnectTargetId` (e.g.
    // from CoreBluetooth state restoration), so the assertion proved non-deterministic. The nil-target
    // path is review-verified instead.

    // MARK: - `reapplyTrustedIdentityIfKnown()` clears `detectedIsMobi` on a genuine peripheral mismatch
    //
    // Makes reapply self-defensive against a reconnect-state-machine regression that could leave a
    // stale name-authority value for the wrong peripheral. Matching-peripheral restore is covered by
    // `trustedModelIsReappliedOnDiscoveringForKnownPeripheral`.

    /// Genuine mismatch: the kit is (re)connecting a DIFFERENT peripheral (UUID-B) than the stored one
    /// (UUID-A). Reapply must clear a stale `detectedIsMobi` before returning.
    @Test func reapplyClearsStaleDetectedIsMobiOnGenuinePeripheralMismatch() {
        resetIdentityStores()
        let uuidA = UUID(), uuidB = UUID()
        PumpPeripheralStore.set(uuidA)
        TrustedPumpIdentityStore.set(isMobi: true, for: uuidA)
        let b = TandemBackend(testTransport: FakePumpTransport())
        b.armReconnectTargetForTesting(uuidB)  // kit is driving a DIFFERENT peripheral
        b.detectedIsMobiForTesting = true  // a stale name-authority value from a prior session

        b.applyClientState(.discovering)

        #expect(
            b.detectedIsMobiForTesting == nil,
            "a genuine peripheral mismatch must defensively clear the stale detectedIsMobi")
        #expect(b.identityTrustedForTesting == false, "and it must never stamp trust for the mismatched peripheral")
    }
}
