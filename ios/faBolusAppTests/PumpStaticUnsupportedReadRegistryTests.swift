import Testing
import Foundation
import TandemMessages
import TandemBLE
@testable import faBolus

/// Tests for the STATIC known-unsupported-reads registry — the ADDITIVE hardening pass of debug session
/// `pump-pairing-loop-api25` (2026-08-19, on top of the on-device-verified dynamic self-heal at HEAD
/// a48bb44, which STAYS). Full diagnosis + prior fixes: `.planning/debug/pump-pairing-loop-api25.md`.
///
/// PROBLEM this pass closes: on a FRESH install / never-before-seen pump the app cannot know it is the
/// evidenced bad combo at `startPolling()` time — `softwareVersion` is unknown until the async op33
/// `ApiVersionResponse` returns; only `isMobi` (BLE name) is known. So op20 `LoadStatusRequest` (the last
/// read of `fastRead()`) is sent BLINDLY in the pre-version burst and the API-2.5, non-Control-IQ t:slim X2
/// (sw 2.5) drops the link ~2-3× (~25 s) before the dynamic op77 self-heal learns + persists the skip.
///
/// FIX (this suite pins it): a STATIC registry keyed PRECISELY on the evidenced combo
/// `(isMobi == false && softwareVersion == "2.5") → { op20 }`, consulted RIGHT AFTER the bootstrap version
/// responses (op33 `ApiVersionResponse` carries both key fields; op85 `PumpVersionResponse` rides the same
/// trio) identify the pump. The identity-gated read(s) (op20) are DEFERRED out of the pre-version burst and
/// sent only once the version responses are processed — so on the known-bad combo op20 is seeded into the
/// never-resend `badOpcodes` set BEFORE it is ever sent (zero drops, even on the first-ever connect with no
/// persisted history), while any OTHER pump keeps polling op20 (the 09.9 `cartridgeReadyForBolus` pre-guard
/// stays live). Keyed PRECISELY on sw 2.5 — a newer firmware may support op20, and the dynamic path already
/// covers unknown-bad combos.
///
/// ADDITIVE (composition asserted below): the dynamic op77 self-heal + per-pump persistence remain the net
/// for any UNKNOWN incompatibility; Guardrail A (no delivery/control-write opcode ever enters `badOpcodes`)
/// and Guardrail B (op20 excluded ⇒ `cartridgeReadiness == .unknown`, never a fail-open confirmed-ready)
/// stay intact. `PumpTransactionCoordinator` is OUT of scope (09.11); the TandemKit pin stays HELD (1a09dba).
@Suite(.serialized) @MainActor
struct PumpStaticUnsupportedReadRegistryTests {

    /// op20 — the read the evidenced API-2.5 t:slim X2 (sw 2.5) rejects, and the one seeded entry of the
    /// static registry.
    private var loadStatusOpcode: UInt8 { LoadStatusRequest.props.opCode }

    // MARK: - (a) Known-bad combo: op20 NEVER sent, even once, on a first-ever connect

    /// The core guarantee: on a first-EVER connect (fresh backend, NO persisted history) to the evidenced
    /// bad combo — t:slim X2 (non-Mobi), sw/API 2.5 — op20 `LoadStatusRequest` must be sent ZERO times
    /// across a full connect. Not in the pre-version burst; not after the version responses identify the
    /// pump. This eliminates the ~2-3-drop / ~25 s first-connect learn cost entirely.
    @Test func knownBadCombo_neverSendsLoadStatus_onAFirstEverConnect() {
        let b = TandemBackend(testTransport: FakePumpTransport())   // fresh, no persisted store configured
        var dispatched: [UInt8] = []
        b.onReadDispatchedForTesting = { _, op in dispatched.append(op) }
        b.startPollingForTesting()
        // The bootstrap version responses return and IDENTIFY the pump as the evidenced bad combo.
        b.injectStatusFrameForTesting(FakePumpTransport.pumpVersion(modelNum: 0))          // op85
        b.injectStatusFrameForTesting(FakePumpTransport.apiVersion(major: 2, minor: 5))    // op33 → isMobi=false, sw "2.5"
        #expect(!dispatched.contains(loadStatusOpcode),
                "op20 must NEVER be sent on the known-bad t:slim X2 sw-2.5 combo — not in the pre-version burst, not after identity")
    }

    // MARK: - (b) op20 is identity-gated: deferred out of the pre-version burst, then polled if supported

    /// op20 must NOT be sent in the pre-version burst (owner req #2: identity-gated reads go out AFTER the
    /// bootstrap version responses are processed, never blindly before). Once a SUPPORTED identity is
    /// processed (t:slim X2 sw 3.0 — NOT the bad combo), op20 IS polled so the cartridge pre-guard stays
    /// live. The bootstrap trio is still sent first (unchanged) — only the identity-gated read is deferred.
    @Test func loadStatus_isDeferredOutOfThePreVersionBurst_thenPolledOnASupportedPump() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        var dispatched: [UInt8] = []
        b.onReadDispatchedForTesting = { _, op in dispatched.append(op) }
        b.startPollingForTesting()
        #expect(!dispatched.contains(loadStatusOpcode),
                "op20 must NOT appear in the pre-version burst — it is identity-gated on the version responses")
        // The bootstrap trio, however, IS sent first, synchronously (invariant preserved).
        #expect(dispatched.contains(ApiVersionRequest().opCode) && dispatched.contains(PumpVersionRequest().opCode),
                "the bootstrap version reads must still be sent first, in the pre-version burst")

        b.injectStatusFrameForTesting(FakePumpTransport.pumpVersion(modelNum: 0))
        b.injectStatusFrameForTesting(FakePumpTransport.apiVersion(major: 3, minor: 0))    // supported (not 2.5)
        #expect(dispatched.contains(loadStatusOpcode),
                "after the version responses identify a SUPPORTED pump, op20 IS polled (pre-guard stays live)")
    }

    // MARK: - (c) Composition — static exclusion ⊕ dynamic self-heal ⊕ persistence ⊕ Guardrails A/B

    /// The static registry SEEDS op20 into the SAME never-resend `badOpcodes` set the dynamic op77 self-heal
    /// uses — so it composes with the dynamic path — but does so WITHOUT ever sending op20 (no drop).
    @Test func knownBadCombo_seedsStaticExclusionIntoBadOpcodes_withoutEverSending() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        var dispatched: [UInt8] = []
        b.onReadDispatchedForTesting = { _, op in dispatched.append(op) }
        b.startPollingForTesting()
        b.injectStatusFrameForTesting(FakePumpTransport.apiVersion(major: 2, minor: 5))
        #expect(b.badOpcodesForTesting.contains(loadStatusOpcode),
                "the static registry must seed op20 into the never-resend set on the bad combo (shared with the dynamic self-heal)")
        #expect(!dispatched.contains(loadStatusOpcode),
                "op20 must be suppressed BEFORE it is ever sent — no first-connect drop at all")
    }

    /// Guardrail A: the static exclusion is READ-ONLY — on the bad combo `badOpcodes` holds exactly {op20}
    /// and is DISJOINT from every delivery/control-WRITE opcode, so the static path can never suppress a
    /// delivery command.
    @Test func knownBadCombo_staticExclusionIsReadOnly_guardrailA() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        b.startPollingForTesting()
        b.injectStatusFrameForTesting(FakePumpTransport.apiVersion(major: 2, minor: 5))
        #expect(b.badOpcodesForTesting.contains(loadStatusOpcode),
                "the static exclusion must record the evidenced read op20")
        #expect(b.badOpcodesForTesting.isDisjoint(with: PumpReadCatalog.deliveryControlWriteOpcodes),
                "Guardrail A: the static exclusion must NEVER put a delivery/control-write opcode in badOpcodes")
    }

    /// Guardrail B: with op20 statically excluded, cartridge readiness is `.unknown` (same as the dynamic
    /// case) — never a fail-open confirmed-ready — and op20 is never sent to try to confirm it.
    @Test func knownBadCombo_cartridgeReadinessIsUnknown_guardrailB() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        var dispatched: [UInt8] = []
        b.onReadDispatchedForTesting = { _, op in dispatched.append(op) }
        b.startPollingForTesting()
        b.injectStatusFrameForTesting(FakePumpTransport.apiVersion(major: 2, minor: 5))
        #expect(!dispatched.contains(loadStatusOpcode),
                "op20 must never be sent on the excluded combo")
        #expect(b.snapshot.cartridgeReadiness == .unknown,
                "Guardrail B: an op20-excluded pump reports cartridgeReadiness .unknown, not a fail-open confirmed-ready")
    }

    /// The static exclusion composes with EVERY send path that consults `badOpcodes`, including the
    /// on-demand `refreshLoadStatus()` (the pump wizard): once statically excluded, op20 is skipped there too.
    @Test func staticExclusion_isHonoredByTheOnDemandRefreshPath() async {
        let b = TandemBackend(testTransport: FakePumpTransport())
        b.startPollingForTesting()
        b.injectStatusFrameForTesting(FakePumpTransport.apiVersion(major: 2, minor: 5))   // bad combo → op20 excluded
        var dispatched: [UInt8] = []; var skipped: [UInt8] = []
        b.onReadDispatchedForTesting = { _, op in dispatched.append(op) }
        b.onReadSkippedForTesting = { _, op in skipped.append(op) }
        await b.refreshLoadStatus()
        #expect(skipped.contains(loadStatusOpcode),
                "the static exclusion must be honored by the on-demand refresh path too (shared badOpcodes guard)")
        #expect(!dispatched.contains(loadStatusOpcode),
                "on-demand op20 must be skipped on the statically-excluded combo")
    }

    /// The static exclusion is ADDITIVE to — not a replacement for — the per-pump LEARNED persistence: it
    /// suppresses op20 on a first-ever connect even with an EMPTY persisted store, and it must NOT pollute
    /// that learned store (it is re-derived from the registry every connect, so a firmware update that newly
    /// supports op20 is honored the instant the pump reports the new version).
    @Test func staticExclusion_isAdditiveToPerPumpPersistence_andNeverPollutesTheLearnedStore() {
        let suite = "pboc-static-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = PumpBadOpcodeStore(defaults: defaults, storageKey: "learnedBadOpcodesByPump.test")
        let key = "pump-badcombo-\(UUID().uuidString)"

        let b = TandemBackend(testTransport: FakePumpTransport())
        b.configurePersistedBadOpcodesForTesting(store: store, pumpKey: key)   // empty store — first-ever connect
        var dispatched: [UInt8] = []
        b.onReadDispatchedForTesting = { _, op in dispatched.append(op) }
        b.startPollingForTesting()
        b.injectStatusFrameForTesting(FakePumpTransport.apiVersion(major: 2, minor: 5))
        #expect(!dispatched.contains(loadStatusOpcode),
                "static exclusion suppresses op20 with no send, even against an empty persisted store (first-ever connect)")
        #expect(store.learnedOpcodes(for: key).isEmpty,
                "the STATIC exclusion must NOT be persisted into the per-pump LEARNED store — it is additive, re-derived each connect")
    }
}
