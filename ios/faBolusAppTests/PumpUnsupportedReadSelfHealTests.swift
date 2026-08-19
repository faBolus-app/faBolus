import Testing
import Foundation
import TandemMessages
import TandemBLE
@testable import faBolus

/// RED tests for debug session `pump-pairing-loop-api25` (owner decision: fix shape A+B, app-side only,
/// TandemKit pin HELD). Confirmed two-goal diagnosis: `.planning/debug/pump-pairing-loop-api25.md`.
///
/// On the API-2.5, non-Control-IQ t:slim X2 (sw 2.5) the app sends op20 `LoadStatusRequest` as the 10th
/// message of the pre-capability post-pair burst (`PumpReadScheduler.fastRead()`'s last read). This pump
/// answers it with an op77 `ErrorResponse` whose REAL 2-byte currentStatus cargo is `[0,0]` — it does NOT
/// embed the failing opcode — then tears the BLE link down ~90ms later (CBErrorDomain#7). Because the
/// op192-era `badOpcodes` never-resend backstop reads the failing opcode from that (empty) cargo, it
/// records opcode 0 (useless) and re-sends op20 on every reconnect → endless connect/pair/drop loop.
///
/// The fix is two co-operating, app-side-only mechanisms (pin stays HELD; `PumpTransactionCoordinator` is
/// OUT of scope — that is 09.11):
///  - A — op20 is gated OUT of the pre-capability `fastRead()` burst so it is never sent before the pump's
///        supported-capability set is known (mirrors op192's "just don't send it there" precedent), while
///        load-state stays reachable via the on-demand `refreshLoadStatus()` path — the capability is not
///        lost, it just stops riding the fatal pre-capability burst.
///  - B — an app-side correlation backstop that recovers the TRUE failing opcode from an opcode-less op77
///        by correlating the error to the outstanding request (the pump echoes the request txId in
///        frame[1] — kit's hardware-confirmed t:slim behavior — or, failing that, in-order FIFO of
///        outstanding reads) and feeds it to `insertBadOpcode(...)` so the existing never-resend guard
///        actually suppresses it. This self-heals for op20 AND any other read this firmware rejects with
///        an opcode-less error.
///
/// Every assertion below FAILS against the current (unfixed) tree:
///  - A: `fastRead()` still sends op20, and the on-demand refresh bypasses the observable scheduler send.
///  - B: the op77 handler records `requestCodeId` (= 0, from the empty cargo), so op20 never enters
///       `badOpcodes` and is re-sent forever.
@Suite(.serialized) @MainActor
struct PumpUnsupportedReadSelfHealTests {

    /// op20 — the read this API-2.5 t:slim X2 rejects.
    private var loadStatusOpcode: UInt8 { LoadStatusRequest.props.opCode }

    // MARK: - Mechanism A — op20 gated out of the pre-capability burst, still reachable on-demand

    /// A/1: the recurring fast-read burst (`fastRead()`) must NOT send op20 `LoadStatusRequest`. It is the
    /// read the pump rejects before its capability set is known, triggering the teardown loop, so it must
    /// not ride the pre-capability burst.
    @Test func fastReadBurstDoesNotSendLoadStatus() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        var dispatchedNames: [String] = []
        var dispatchedOps: [UInt8] = []
        b.onReadDispatchedForTesting = { name, op in dispatchedNames.append(name); dispatchedOps.append(op) }
        b.simulateRecurringFastAndStaticReadTickForTesting()   // real fastRead() + staticRead()
        #expect(!dispatchedNames.contains("LoadStatusRequest"),
                "op20 LoadStatusRequest must be gated out of the pre-capability fast-read burst")
        #expect(!dispatchedOps.contains(loadStatusOpcode),
                "no message in the fast/static tiers may carry op20")
    }

    /// A/2: the full post-pair startup burst (bootstrap trio + fastRead + staticRead) — the exact sequence
    /// that reproduced the on-device loop — must not send op20 anywhere.
    @Test func postPairStartupBurstDoesNotSendLoadStatus() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        var dispatchedOps: [UInt8] = []
        b.onReadDispatchedForTesting = { _, op in dispatchedOps.append(op) }
        b.startPollingForTesting()
        #expect(!dispatchedOps.contains(loadStatusOpcode),
                "op20 must not appear anywhere in the pre-capability post-pair burst")
    }

    /// A/3: removing op20 from the burst must NOT lose the capability — load-state stays reachable via the
    /// on-demand `refreshLoadStatus()` path, which must route through the guarded scheduler send so it is
    /// (a) observable via the same dispatch seam and (b) subject to the `badOpcodes` never-resend guard.
    @Test func loadStatusRemainsReachableViaOnDemandRefresh() async {
        let b = TandemBackend(testTransport: FakePumpTransport())   // testTransport init → connection == .connected
        var dispatchedOps: [UInt8] = []
        b.onReadDispatchedForTesting = { _, op in dispatchedOps.append(op) }
        await b.refreshLoadStatus()
        #expect(dispatchedOps.contains(loadStatusOpcode),
                "the on-demand refresh must still send op20 — the capability must survive its removal from the burst")
    }

    // MARK: - Mechanism B — opcode-less op77 correlated back to the outstanding op20

    /// B/1: an op77 `ErrorResponse` whose real 2-byte currentStatus cargo is `[0,0]` (the on-wire shape
    /// this pump sends — it does not embed the failing opcode) must be correlated back to the outstanding
    /// op20 (via the txId echo in frame[1], or in-order FIFO) and marked bad. Today the handler trusts the
    /// empty cargo and records opcode 0, so op20 never enters `badOpcodes`.
    @Test func opcodeLessErrorResponseCorrelatesToOutstandingLoadStatus() async {
        let b = TandemBackend(testTransport: FakePumpTransport())   // connected
        // op20 is the SOLE outstanding read (post-A the burst no longer sends it) — so both correlation
        // strategies (txId echo / in-order FIFO) resolve to op20 unambiguously.
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
