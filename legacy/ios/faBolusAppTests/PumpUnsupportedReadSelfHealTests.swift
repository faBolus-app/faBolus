import Testing
import Foundation
import TandemMessages
import TandemBLE
@testable import faBolus

/// Opcode-less op77 correlates to the true failing read (fail-closed never-resend) so a rejected
/// LoadStatus cannot loop reconnects, while dose-input reads are re-probed each connection.
@Suite(.serialized) @MainActor
struct PumpUnsupportedReadSelfHealTests {

    /// op20 — the read this API-2.5 t:slim X2 rejects.
    private var loadStatusOpcode: UInt8 { LoadStatusRequest.props.opCode }

    // MARK: - op20 is polled (refinement) AND reachable on-demand

    /// op20 rides the recurring fast-read burst again (refinement) so `cartridgeLoadState` — and the
    /// `cartridgeReadyForBolus` pre-guard it feeds — stays live on a pump that supports it. (A pump that
    /// REJECTS op20 learns-and-skips it durably — see `PumpLearnedOpcodePersistenceTests`.)
    @Test func fastReadBurstSendsLoadStatusOnAPumpWithNoLearnedRejection() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        var dispatchedNames: [String] = []
        var dispatchedOps: [UInt8] = []
        b.onReadDispatchedForTesting = { name, op in
            dispatchedNames.append(name)
            dispatchedOps.append(op)
        }
        b.simulateRecurringFastAndStaticReadTickForTesting()  // real fastRead() + staticRead()
        #expect(
            dispatchedNames.contains("LoadStatusRequest"),
            "op20 LoadStatusRequest must ride the recurring fast-read burst (refinement restored it)")
        #expect(
            dispatchedOps.contains(loadStatusOpcode),
            "the fast tier must carry op20 so the cartridge pre-guard stays live on supported pumps")
    }

    /// The full post-pair startup burst sends op20 on a pump with no learned rejection — the pre-guard is fed
    /// from the first poll. op20 is IDENTITY-GATED (deferred out of the
    /// pre-version burst), so it is dispatched once the bootstrap version responses identify the pump — here
    /// a SUPPORTED pump (default identity, not the t:slim X2 sw-2.5 bad combo), released via the test seam.
    @Test func postPairStartupBurstSendsLoadStatusOnAPumpWithNoLearnedRejection() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        var dispatchedOps: [UInt8] = []
        b.onReadDispatchedForTesting = { _, op in dispatchedOps.append(op) }
        b.startPollingForTesting()
        b.releaseIdentityGatedReadsForTesting()  // op33/op85 identify a supported pump → deferred op20 goes out
        #expect(
            dispatchedOps.contains(loadStatusOpcode),
            "op20 must be polled (after version identity) on a pump with no persisted op20 rejection")
    }

    /// op20 also stays reachable via the on-demand `refreshLoadStatus()` path (the pump wizard), which must
    /// route through the guarded scheduler send so it is (a) observable via the same dispatch seam and (b)
    /// subject to the `badOpcodes` never-resend guard.
    @Test func loadStatusRemainsReachableViaOnDemandRefresh() async {
        let b = TandemBackend(testTransport: FakePumpTransport())  // testTransport init → connection == .connected
        var dispatchedOps: [UInt8] = []
        b.onReadDispatchedForTesting = { _, op in dispatchedOps.append(op) }
        await b.refreshLoadStatus()
        #expect(
            dispatchedOps.contains(loadStatusOpcode),
            "the on-demand refresh must send op20 — the load-state capability stays reachable on demand")
    }

    // MARK: - Mechanism B — opcode-less op77 correlated back to the outstanding op20

    /// B/1: an op77 `ErrorResponse` whose real 2-byte currentStatus cargo is `[0,0]` (the on-wire shape
    /// this pump sends — it does not embed the failing opcode) must be correlated back to the outstanding
    /// op20 (via the txId echo in frame[1], or in-order FIFO) and marked bad — never opcode 0.
    @Test func opcodeLessErrorResponseCorrelatesToOutstandingLoadStatus() async {
        let b = TandemBackend(testTransport: FakePumpTransport())  // connected
        // Drive op20 out on the on-demand path so it is the sole outstanding read (txId 0) — both
        // correlation strategies (txId echo / in-order FIFO) then resolve to op20 unambiguously.
        await b.refreshLoadStatus()
        // Real 7-byte on-wire frame: [op77, txId=0, len=2, cargo 0,0, crc, crc]. The cargo names no opcode;
        // frame[1] (txId) echoes op20's request — the only correlation signal the pump provides.
        b.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 0, errorCode: 0))
        #expect(
            b.badOpcodesForTesting.contains(loadStatusOpcode),
            "an opcode-less op77 must be correlated back to the outstanding op20 and marked bad")
        #expect(
            !b.badOpcodesForTesting.contains(0),
            "opcode 0 (the empty-cargo artifact) must never be what gets suppressed")
    }

    /// B/2: once op20 is correlated as pump-rejected, a subsequent on-demand refresh must SKIP it (the
    /// never-resend guard) — this is the self-heal that ends the reconnect loop.
    @Test func aCorrelatedLoadStatusIsNeverResent() async {
        let b = TandemBackend(testTransport: FakePumpTransport())  // connected
        await b.refreshLoadStatus()
        b.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 0, errorCode: 0))

        var skippedOps: [UInt8] = []
        var dispatchedOps: [UInt8] = []
        b.onReadSkippedForTesting = { _, op in skippedOps.append(op) }
        b.onReadDispatchedForTesting = { _, op in dispatchedOps.append(op) }
        await b.refreshLoadStatus()
        #expect(
            skippedOps.contains(loadStatusOpcode),
            "after being marked bad, op20 must be skipped by the never-resend guard, not re-sent")
        #expect(
            !dispatchedOps.contains(loadStatusOpcode),
            "op20 must never be dispatched again this connection-lifetime")
    }

    // MARK: - a dose-input read (op108/op115) is re-probed each connection, never durably skipped

    /// Every read op77'd by an AMBIGUOUS error while a burst was in flight is re-probed on the next
    /// connection — the dose-input reads (op108 `ControlIQIOBRequest` IOB, op115 `BolusCalcDataSnapshotRequest`
    /// therapy settings) AND op20, which is not a dose input.
    ///
    /// OWNER DECISION (debug session `tslim-reservoir-battery-zero`), recorded here so it is not
    /// accidentally undone: **do not restore the old family-scoped assertion.** This test previously
    /// asserted the opposite for op20 — "op20, NOT being a dose-input read, STAYS skipped across the
    /// reconnect — the contrast that proves the re-probe allowlist is dose-input-scoped". That framing was
    /// the bug. The allowlist is no longer scoped by which read FAMILY an opcode belongs to; it is scoped by
    /// what the pump's error actually PROVED, because family membership was never evidence about capability.
    ///
    /// Here op20 is attributed by a txId echo while a full ~16-read burst is outstanding
    /// (`PumpOpcodeCorrelation.txIdEchoUnderBurst`) from an opcode-less `[0,0]` cargo
    /// (`PumpErrorClass.ambiguous`). That is a MIS-CORRELATION artefact — the error was produced by the
    /// burst and merely pinned onto whichever read the echo pointed at — not a capability fact, so it must
    /// stay PROVISIONAL and be re-probed until `PumpBadOpcodeStore.durableStrikeThreshold` cycles
    /// corroborate it. Treating that single observation as authoritative is precisely what durably deleted
    /// five perfectly-supported reads (op-20/36/56/144/164) on a brand-new t:slim X2 and blanked the
    /// reservoir and battery rows.
    ///
    /// The one-drop-ever guarantee is NOT weakened; it is pinned where it was actually earned, by
    /// `op20LearnedAsTheSoleOutstandingReadStillStaysSkippedAcrossAReconnect` below (unambiguous
    /// attribution on the on-demand `refreshLoadStatus()` path the API-2.5 t:slim X2 pairing-loop self-heal
    /// really uses) and by `PumpTransientErrorNeverDurablyBlacklistsTests`'
    /// `aGenuineBadOpcodeStillPersistsOnTheFirstObservation` (a real `BAD_OPCODE(6)`,
    /// which still sticks immediately regardless of correlation). Dose-input reads additionally stay
    /// never-durable in their own right: op109 is the sole IOB source, so a durable skip would fail-close
    /// `recommendBolus` forever with no re-probe.
    @Test func aDoseInputReadAndABurstAttributedOp20AreBothReProbedOnTheNextConnection() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        let iob = ControlIQIOBRequest.props.opCode  // op108 (dose input)
        let therapy = BolusCalcDataSnapshotRequest.props.opCode  // op115 (dose input)
        let op20 = loadStatusOpcode  // op20 (cartridge pre-guard read)

        // Connection N: run the full post-pair burst and release the identity-gated op20, so op108, op115 and
        // op20 are all outstanding with distinct wire txIds.
        b.startPollingForTesting()
        b.releaseIdentityGatedReadsForTesting()  // op33/op85 identify a supported pump → deferred op20 goes out
        guard let iobTxId = b.outstandingReadsForTesting.first(where: { $0.opcode == iob })?.txId,
            let therapyTxId = b.outstandingReadsForTesting.first(where: { $0.opcode == therapy })?.txId,
            let op20TxId = b.outstandingReadsForTesting.first(where: { $0.opcode == op20 })?.txId
        else {
            Issue.record("op108, op115 and op20 must all be outstanding after the burst")
            return
        }
        // The pump op77's each of them (opcode-less [0,0], correlated by the echoed request txId in frame[1]).
        b.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 0, errorCode: 0, txId: iobTxId))
        b.injectStatusFrameForTesting(
            FakePumpTransport.errorResponse(requestOpCode: 0, errorCode: 0, txId: therapyTxId))
        b.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 0, errorCode: 0, txId: op20TxId))
        #expect(
            b.badOpcodesForTesting.isSuperset(of: [iob, therapy, op20]),
            "all three op77'd reads are skipped for the rest of THIS session (in-memory badOpcodes)")

        // Connection N+1: startPolling re-probes the dose-input reads (dropped from badOpcodes) but keeps op20.
        var dispatched: [UInt8] = []
        b.onReadDispatchedForTesting = { _, op in dispatched.append(op) }
        b.startPollingForTesting()
        // op20 is IDENTITY-GATED: `startPolling()` resets `bootstrapVersionIdentified` /
        // `identityGatedReadsDispatchedThisCycle` and calls `fastRead(includingIdentityGatedReads: false)`,
        // so op20 is held back until this cycle's op33 identifies the pump. Release it here exactly as
        // connection N does above — otherwise op20 is never offered to `sendStatusRead` at all on N+1 and
        // the re-probe assertion below would be unobservable for the wrong reason (it would appear in
        // NEITHER `dispatched` nor `skipped`). Do NOT "fix" a failure here by raising the fixture's API
        // version: `sendStatusRead` applies no `minApi`/`isSupported` floor gate — its only skip condition
        // is `badOpcodes` — so the floor cannot be what withholds op20 on this path.
        b.releaseIdentityGatedReadsForTesting()
        #expect(
            !b.badOpcodesForTesting.contains(iob),
            "op108 must be dropped from badOpcodes on the next connection — re-probed, never durably skipped")
        #expect(
            !b.badOpcodesForTesting.contains(therapy),
            "op115 must be dropped from badOpcodes on the next connection — re-probed, never durably skipped")
        #expect(dispatched.contains(iob), "op108 must be RE-SENT on connection N+1")
        #expect(dispatched.contains(therapy), "op115 must be RE-SENT on connection N+1")
        // op20's treatment here is the OWNER DECISION documented at the top of this test: burst-attributed
        // + opcode-less ⇒ provisional, re-probed until corroborated. Do not flip this back to
        // `contains(op20)`; read the header first.
        #expect(
            !b.badOpcodesForTesting.contains(op20),
            "a BURST-attributed ambiguous op77 is provisional — op20 must be re-probed, not permanently dropped")
        #expect(dispatched.contains(op20), "op20 must be re-probed on connection N+1 after a burst-attributed op77")
    }

    /// The other side of the contract above: when op20 is the SOLE outstanding read (the on-demand
    /// `refreshLoadStatus()` shape the API-2.5 t:slim X2 pairing-loop self-heal is built on) the
    /// attribution involves no guess, so the skip is authoritative and STILL survives the reconnect —
    /// one drop, ever. Debug session `tslim-reservoir-battery-zero` narrowed the provisional treatment to
    /// burst-attributed rejections only; it must not have weakened this path.
    @Test func op20LearnedAsTheSoleOutstandingReadStillStaysSkippedAcrossAReconnect() async {
        let b = TandemBackend(testTransport: FakePumpTransport())
        b.setSoftwareVersionForTesting("2.5")
        await b.refreshLoadStatus()  // op20 is the ONLY outstanding read
        b.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 0, errorCode: 0))
        #expect(b.badOpcodesForTesting.contains(loadStatusOpcode))

        var dispatched: [UInt8] = []
        var skipped: [UInt8] = []
        b.onReadDispatchedForTesting = { _, op in dispatched.append(op) }
        b.onReadSkippedForTesting = { _, op in skipped.append(op) }
        b.startPollingForTesting()
        b.releaseIdentityGatedReadsForTesting()
        #expect(
            b.badOpcodesForTesting.contains(loadStatusOpcode),
            "an unambiguously-attributed op20 rejection stays skipped across the reconnect — one drop, ever")
        #expect(skipped.contains(loadStatusOpcode))
        #expect(!dispatched.contains(loadStatusOpcode))
    }
}

/// A non-Tandem backend must take the same fail-closed fallbacks `source as? TandemBackend`
/// used to: no diagnostics opcodes, history sync stays idle, Sync now is a no-op.
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
        #expect(
            (backend as? TandemOnlyOps) == nil,
            "MockBackend must not conform to TandemOnlyOps — every narrowed cast site must fall back exactly as it did under `source as? TandemBackend`"
        )
    }

    /// `AppModel.badOpcodesForDiagnostics` is a computed property re-evaluating the cast on every read —
    /// proves the `?? []` fallback fires under a MockBackend source, identical to the older
    /// `(source as? TandemBackend)?.badOpcodesForDiagnostics ?? []`.
    @Test func badOpcodesForDiagnosticsIsEmptyUnderMockBackend() {
        let model = AppModel(source: MockBackend(), ledgerStoreURL: tempLedgerURL())
        #expect(
            model.badOpcodesForDiagnostics.isEmpty,
            "a non-Tandem backend must report no rejected opcodes rather than crashing the diagnostics read-out")
    }

    /// `AppModel.historySyncState` is only ever advanced away from its `.idle(lastSynced:
    /// nil)` default by the narrowed cast inside `refresh()` — under MockBackend that cast is
    /// always nil, so the observable state never leaves its initial idle value.
    @Test func historySyncStateStaysIdleUnderMockBackend() {
        let model = AppModel(source: MockBackend(), ledgerStoreURL: tempLedgerURL())
        #expect(
            model.historySyncState == .idle(lastSynced: nil),
            "history-sync state must stay idle under a non-Tandem backend — the narrowed cast never fires for it")
    }

    /// `syncHistoryNow()`/`stopHistorySync()` (the "Sync now"/"Stop syncing" actions) are no-ops under a
    /// non-Tandem backend both before AND after the narrowing — calling them must not crash and
    /// must not perturb `historySyncState`, exactly mirroring the old `(source as? TandemBackend)?...`
    /// no-op.
    @Test func syncHistoryNowAndStopHistorySyncAreNoOpsUnderMockBackend() {
        let model = AppModel(source: MockBackend(), ledgerStoreURL: tempLedgerURL())
        model.syncHistoryNow()
        model.stopHistorySync()
        #expect(
            model.historySyncState == .idle(lastSynced: nil),
            "'Sync now'/'Stop syncing' must remain silent no-ops under a non-Tandem backend, never triggering a real history sync"
        )
    }
}
