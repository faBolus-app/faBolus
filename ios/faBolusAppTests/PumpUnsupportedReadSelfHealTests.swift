import Testing
import Foundation
import TandemMessages
import TandemBLE
@testable import faBolus

/// Tests for debug session `pump-pairing-loop-api25` mechanism B (the op77 correlation backstop) — the
/// app-side, pin-HELD self-heal that recovers the TRUE failing opcode from an opcode-less op77. Confirmed
/// two-goal diagnosis + owner refinement: `.planning/debug/pump-pairing-loop-api25.md`.
///
/// On the API-2.5, non-Control-IQ t:slim X2 (sw 2.5) the app sends op20 `LoadStatusRequest` in the post-pair
/// burst; this pump answers it with an op77 `ErrorResponse` whose REAL 2-byte currentStatus cargo is `[0,0]`
/// — it does NOT embed the failing opcode — then tears the BLE link down ~90ms later (CBErrorDomain#7).
/// Because the op192-era `badOpcodes` never-resend backstop read the failing opcode from that (empty) cargo,
/// it recorded opcode 0 (useless) and re-sent op20 on every reconnect → endless connect/pair/drop loop.
///
/// Mechanism B (this suite) — an app-side correlation backstop that recovers the TRUE failing opcode from an
/// opcode-less op77 by correlating the error to the outstanding request (the pump echoes the request txId in
/// frame[1] — kit's hardware-confirmed t:slim behavior — or, failing that, in-order FIFO of outstanding
/// reads) and feeds it to `insertBadOpcode(...)` so the existing never-resend guard actually suppresses it.
/// Self-heals for op20 AND any other read this firmware rejects with an opcode-less error.
///
/// NOTE (owner refinement 2026-08-19): op20 RIDES the recurring `fastRead()` poll again (an initial fix,
/// commit 9f978a5, had gated it out for ALL models, which starved the 09.9 `cartridgeReadyForBolus`
/// pre-guard on pumps that DO support op20). op20 stays reachable on-demand too (A/on-demand below). The
/// DURABLE, per-pump persistence of the learned skip — so the API-2.5 pump drops op20 exactly once, ever —
/// is covered in `PumpLearnedOpcodePersistenceTests`.
@Suite(.serialized) @MainActor
struct PumpUnsupportedReadSelfHealTests {

    /// op20 — the read this API-2.5 t:slim X2 rejects.
    private var loadStatusOpcode: UInt8 { LoadStatusRequest.props.opCode }

    // MARK: - op20 is polled (refinement) AND reachable on-demand

    /// op20 rides the recurring fast-read burst again (refinement) so `cartridgeLoadState` — and the 09.9
    /// `cartridgeReadyForBolus` pre-guard it feeds — stays live on a pump that supports it. (A pump that
    /// REJECTS op20 learns-and-skips it durably — see `PumpLearnedOpcodePersistenceTests`.)
    @Test func fastReadBurstSendsLoadStatusOnAPumpWithNoLearnedRejection() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        var dispatchedNames: [String] = []
        var dispatchedOps: [UInt8] = []
        b.onReadDispatchedForTesting = { name, op in dispatchedNames.append(name); dispatchedOps.append(op) }
        b.simulateRecurringFastAndStaticReadTickForTesting()   // real fastRead() + staticRead()
        #expect(dispatchedNames.contains("LoadStatusRequest"),
                "op20 LoadStatusRequest must ride the recurring fast-read burst (refinement restored it)")
        #expect(dispatchedOps.contains(loadStatusOpcode),
                "the fast tier must carry op20 so the cartridge pre-guard stays live on supported pumps")
    }

    /// The full post-pair startup burst sends op20 on a pump with no learned rejection — the pre-guard is fed
    /// from the first poll. api25 static-registry hardening: op20 is IDENTITY-GATED (deferred out of the
    /// pre-version burst), so it is dispatched once the bootstrap version responses identify the pump — here
    /// a SUPPORTED pump (default identity, not the t:slim X2 sw-2.5 bad combo), released via the test seam.
    @Test func postPairStartupBurstSendsLoadStatusOnAPumpWithNoLearnedRejection() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        var dispatchedOps: [UInt8] = []
        b.onReadDispatchedForTesting = { _, op in dispatchedOps.append(op) }
        b.startPollingForTesting()
        b.releaseIdentityGatedReadsForTesting()   // op33/op85 identify a supported pump → deferred op20 goes out
        #expect(dispatchedOps.contains(loadStatusOpcode),
                "op20 must be polled (after version identity) on a pump with no persisted op20 rejection")
    }

    /// op20 also stays reachable via the on-demand `refreshLoadStatus()` path (the pump wizard), which must
    /// route through the guarded scheduler send so it is (a) observable via the same dispatch seam and (b)
    /// subject to the `badOpcodes` never-resend guard.
    @Test func loadStatusRemainsReachableViaOnDemandRefresh() async {
        let b = TandemBackend(testTransport: FakePumpTransport())   // testTransport init → connection == .connected
        var dispatchedOps: [UInt8] = []
        b.onReadDispatchedForTesting = { _, op in dispatchedOps.append(op) }
        await b.refreshLoadStatus()
        #expect(dispatchedOps.contains(loadStatusOpcode),
                "the on-demand refresh must send op20 — the load-state capability stays reachable on demand")
    }

    // MARK: - Mechanism B — opcode-less op77 correlated back to the outstanding op20

    /// B/1: an op77 `ErrorResponse` whose real 2-byte currentStatus cargo is `[0,0]` (the on-wire shape
    /// this pump sends — it does not embed the failing opcode) must be correlated back to the outstanding
    /// op20 (via the txId echo in frame[1], or in-order FIFO) and marked bad — never opcode 0.
    @Test func opcodeLessErrorResponseCorrelatesToOutstandingLoadStatus() async {
        let b = TandemBackend(testTransport: FakePumpTransport())   // connected
        // Drive op20 out on the on-demand path so it is the sole outstanding read (txId 0) — both
        // correlation strategies (txId echo / in-order FIFO) then resolve to op20 unambiguously.
        await b.refreshLoadStatus()
        // Real 7-byte on-wire frame: [op77, txId=0, len=2, cargo 0,0, crc, crc]. The cargo names no opcode;
        // frame[1] (txId) echoes op20's request — the only correlation signal the pump provides.
        b.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 0, errorCode: 0))
        #expect(b.badOpcodesForTesting.contains(loadStatusOpcode),
                "an opcode-less op77 must be correlated back to the outstanding op20 and marked bad")
        #expect(!b.badOpcodesForTesting.contains(0),
                "opcode 0 (the empty-cargo artifact) must never be what gets suppressed")
    }

    /// B/2: once op20 is correlated as pump-rejected, a subsequent on-demand refresh must SKIP it (the
    /// never-resend guard) — this is the self-heal that ends the reconnect loop.
    @Test func aCorrelatedLoadStatusIsNeverResent() async {
        let b = TandemBackend(testTransport: FakePumpTransport())   // connected
        await b.refreshLoadStatus()
        b.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 0, errorCode: 0))

        var skippedOps: [UInt8] = []
        var dispatchedOps: [UInt8] = []
        b.onReadSkippedForTesting = { _, op in skippedOps.append(op) }
        b.onReadDispatchedForTesting = { _, op in dispatchedOps.append(op) }
        await b.refreshLoadStatus()
        #expect(skippedOps.contains(loadStatusOpcode),
                "after being marked bad, op20 must be skipped by the never-resend guard, not re-sent")
        #expect(!dispatchedOps.contains(loadStatusOpcode),
                "op20 must never be dispatched again this connection-lifetime")
    }

    // MARK: - R2-10 (CR-02) — a dose-input read (op108/op115) is RE-PROBED each connection, never durably skipped

    /// op108 `ControlIQIOBRequest` (IOB) and op115 `BolusCalcDataSnapshotRequest` (therapy settings) feed the
    /// bolus calculator; op109 is the ONLY IOB source, so a DURABLE skip would fail-close `recommendBolus`
    /// forever with no re-probe. Unlike op20 (which learns-and-STAYS-skipped across reconnects), a dose-input
    /// read op77'd this connection is skipped only for the REST of this session and is DROPPED from
    /// `badOpcodes` on the next `startPolling()`, so it is re-sent every connection. op20 (NOT a dose input)
    /// stays skipped across the reconnect — the contrast that proves the R2-10 allowlist is dose-input-scoped.
    @Test func aDoseInputReadOp77dThisConnectionIsReProbedNextConnectionWhileOp20StaysSkipped() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        let iob = ControlIQIOBRequest.props.opCode                 // op108 (dose input)
        let therapy = BolusCalcDataSnapshotRequest.props.opCode    // op115 (dose input)
        let op20 = loadStatusOpcode                                // op20 (cartridge pre-guard read)

        // Connection N: run the full post-pair burst and release the identity-gated op20, so op108, op115 and
        // op20 are all outstanding with distinct wire txIds.
        b.startPollingForTesting()
        b.releaseIdentityGatedReadsForTesting()   // op33/op85 identify a supported pump → deferred op20 goes out
        guard let iobTxId = b.outstandingReadsForTesting.first(where: { $0.opcode == iob })?.txId,
              let therapyTxId = b.outstandingReadsForTesting.first(where: { $0.opcode == therapy })?.txId,
              let op20TxId = b.outstandingReadsForTesting.first(where: { $0.opcode == op20 })?.txId else {
            Issue.record("op108, op115 and op20 must all be outstanding after the burst"); return
        }
        // The pump op77's each of them (opcode-less [0,0], correlated by the echoed request txId in frame[1]).
        b.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 0, errorCode: 0, txId: iobTxId))
        b.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 0, errorCode: 0, txId: therapyTxId))
        b.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 0, errorCode: 0, txId: op20TxId))
        #expect(b.badOpcodesForTesting.isSuperset(of: [iob, therapy, op20]),
                "all three op77'd reads are skipped for the rest of THIS session (in-memory badOpcodes)")

        // Connection N+1: startPolling re-probes the dose-input reads (dropped from badOpcodes) but keeps op20.
        var dispatched: [UInt8] = []
        b.onReadDispatchedForTesting = { _, op in dispatched.append(op) }
        b.startPollingForTesting()
        #expect(!b.badOpcodesForTesting.contains(iob),
                "op108 must be dropped from badOpcodes on the next connection — re-probed, never durably skipped (R2-10)")
        #expect(!b.badOpcodesForTesting.contains(therapy),
                "op115 must be dropped from badOpcodes on the next connection — re-probed, never durably skipped (R2-10)")
        #expect(dispatched.contains(iob), "op108 must be RE-SENT on connection N+1")
        #expect(dispatched.contains(therapy), "op115 must be RE-SENT on connection N+1")
        #expect(b.badOpcodesForTesting.contains(op20),
                "op20 (NOT a dose-input read) must STAY skipped across the reconnect — the contrast that scopes the allowlist")
    }
}

/// GO-1 Step 7 (16-07, REMED-16) — proves the narrowed `source as? TandemOnlyOps` casts introduced in
/// `AppModel` behave IDENTICALLY to the `source as? TandemBackend` / `source is TandemBackend` casts
/// they replaced, for every non-Tandem backend. Colocated with `PumpUnsupportedReadSelfHealTests`
/// per the 16-07 plan's file list (both suites concern the concrete-Tandem-only diagnostics/history
/// surface `AppModel` reaches through a cast).
///
/// `MockBackend` is the reference non-Tandem backend — it intentionally does NOT conform to
/// `TandemOnlyOps` (see `ios/faBolus/Data/MockBackend.swift`, no `TandemOnlyOps` conformance anywhere
/// in the file), so `source as? TandemOnlyOps` is `nil` for it, and every cast-guarded branch must take
/// the identical fallback it took under the old concrete `TandemBackend` cast.
@MainActor
@Suite(.serialized) struct TandemOnlyOpsMockFallbackParityTests {

    /// A unique durable-ledger URL so instances don't share the App Group ledger between serialized tests.
    private func tempLedgerURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("tandem-only-ops-\(UUID().uuidString).json")
    }

    /// Direct, type-level proof of non-conformance — the most literal statement of the must-have truth
    /// ("MockBackend does NOT conform to TandemOnlyOps"), independent of any `AppModel` plumbing.
    @Test func mockBackendDoesNotConformToTandemOnlyOps() {
        let backend = MockBackend()
        #expect((backend as? TandemOnlyOps) == nil,
                "MockBackend must not conform to TandemOnlyOps — every narrowed cast site must fall back exactly as it did under `source as? TandemBackend`")
    }

    /// `AppModel.badOpcodesForDiagnostics` is a computed property re-evaluating the cast on every read
    /// (R5) — proves the `?? []` fallback fires under a MockBackend source, identical to the pre-16-07
    /// `(source as? TandemBackend)?.badOpcodesForDiagnostics ?? []`.
    @Test func badOpcodesForDiagnosticsIsEmptyUnderMockBackend() {
        let model = AppModel(source: MockBackend(), ledgerStoreURL: tempLedgerURL())
        #expect(model.badOpcodesForDiagnostics.isEmpty,
                "a non-Tandem backend must report no rejected opcodes rather than crashing the diagnostics read-out")
    }

    /// `AppModel.historySyncState` (D-01/D-05) is only ever advanced away from its `.idle(lastSynced:
    /// nil)` default by the narrowed cast inside `refresh()` (R29/R34) — under MockBackend that cast is
    /// always nil, so the observable state never leaves its initial idle value.
    @Test func historySyncStateStaysIdleUnderMockBackend() {
        let model = AppModel(source: MockBackend(), ledgerStoreURL: tempLedgerURL())
        #expect(model.historySyncState == .idle(lastSynced: nil),
                "history-sync state must stay idle under a non-Tandem backend — the narrowed cast never fires for it")
    }

    /// `syncHistoryNow()`/`stopHistorySync()` (D-05 "Sync now"/"Stop syncing", R29) are no-ops under a
    /// non-Tandem backend both before AND after the 16-07 narrowing — calling them must not crash and
    /// must not perturb `historySyncState`, exactly mirroring the old `(source as? TandemBackend)?...`
    /// no-op.
    @Test func syncHistoryNowAndStopHistorySyncAreNoOpsUnderMockBackend() {
        let model = AppModel(source: MockBackend(), ledgerStoreURL: tempLedgerURL())
        model.syncHistoryNow()
        model.stopHistorySync()
        #expect(model.historySyncState == .idle(lastSynced: nil),
                "'Sync now'/'Stop syncing' must remain silent no-ops under a non-Tandem backend, never triggering a real history sync")
    }
}
