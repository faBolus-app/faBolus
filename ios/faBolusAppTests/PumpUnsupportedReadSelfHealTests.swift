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

    /// The full post-pair startup burst (bootstrap trio + fastRead + staticRead) sends op20 on a pump with
    /// no learned rejection — the pre-guard is fed from the very first poll.
    @Test func postPairStartupBurstSendsLoadStatusOnAPumpWithNoLearnedRejection() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        var dispatchedOps: [UInt8] = []
        b.onReadDispatchedForTesting = { _, op in dispatchedOps.append(op) }
        b.startPollingForTesting()
        #expect(dispatchedOps.contains(loadStatusOpcode),
                "op20 must appear in the post-pair burst on a pump with no persisted op20 rejection")
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
}
