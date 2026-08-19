import Testing
import Foundation
import TandemMessages
import TandemBLE
@testable import faBolus

/// Debug session `pump-pairing-loop-api25` — DEEP-REVIEW remediation of the op77 correlation backstop.
///
/// The mechanism-B self-heal (recover the TRUE failing read opcode from an op77 `ErrorResponse` and add it
/// to the never-resend `badOpcodes` set) had a deterministic misattribution path and a robustness gap that
/// the new PER-PUMP PERSISTENCE would make permanent:
///
///  - CR-01 / WR-01: the correlation is characteristic-BLIND. The pinned kit registers `ErrorResponse` on
///    BOTH `.currentStatus` AND `.control`, so a NACKed control/delivery WRITE's op77 reaches
///    `PumpResponseApplier.apply` on `.opcodeFIFO` pumps (Mobi/default). Via the cargo `named` path (op164
///    SetTempRate == LastBolusStatusV2 READ; op144 EnterChangeCartridge == CurrentBatteryV2 READ — both
///    EXCLUDED from the delivery guard so the READ stays learnable) OR the opcode-less txId/FIFO path, that
///    control-write rejection would durably blacklist a supported READ.
///  - WR-02: the opcode-less fallback blindly guessed the FIFO-OLDEST outstanding read. op20 is
///    `fastRead()`'s LAST send, so the oldest is always a bootstrap/early read — doubly wrong (blacklists an
///    innocent read AND never blacklists op20).
///  - WR-03: the prior tests were vacuous — a SOLE outstanding read (op20 via `refreshLoadStatus`) with the
///    hardcoded txId 0, so txId-echo and FIFO trivially agreed and deleting the byTxId branch still passed.
///
/// The root fix (reviewer option a): thread the frame's `Characteristic` through `apply` and RESOLVE +
/// RECORD an op77 ONLY on `.currentStatus`; drop the blind FIFO-oldest (txId-echo PRIMARY, else the
/// exactly-one-outstanding shortcut, else FAIL CLOSED to 0). `PumpTransactionCoordinator` is OUT of scope
/// (09.11); the TandemKit pin stays HELD (1a09dba).
@Suite(.serialized) @MainActor
struct PumpErrorCorrelationScopeTests {

    private var loadStatusOpcode: UInt8 { LoadStatusRequest.props.opCode }

    // MARK: - CR-01: a rejected control WRITE never blacklists its colliding supported READ

    /// op164 = `SetTempRateRequest` (`.control` WRITE) AND `LastBolusStatusV2Request` (`.currentStatus`
    /// READ). A `.control` op77 whose cargo NAMES op164 (a rejected temp-rate write) must NEVER suppress the
    /// LastBolusStatusV2 READ. Before the fix the `named` path recorded it (op164 ∉ the delivery guard set);
    /// after, a `.control` op77 can never touch `badOpcodes`.
    @Test func aControlWriteNackNamingAReadCollidingOpcodeNeverBlacklistsTheRead() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        let op164 = SetTempRateRequest.props.opCode
        #expect(op164 == LastBolusStatusV2Request.props.opCode)   // proven collision
        b.injectControlFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: op164, errorCode: 6))
        #expect(!b.badOpcodesForTesting.contains(op164),
                "a .control write NACK naming op164 must NEVER suppress the colliding LastBolusStatusV2 READ (CR-01)")
        #expect(b.badOpcodesForTesting.isEmpty, "no read may be blacklisted by a control-write rejection")
    }

    /// op144 = `EnterChangeCartridgeModeRequest` (WRITE) AND `CurrentBatteryV2Request` (READ) — same hazard.
    @Test func aControlWriteNackNamingOp144NeverBlacklistsTheBatteryRead() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        let op144 = EnterChangeCartridgeModeRequest.props.opCode
        #expect(op144 == CurrentBatteryV2Request.props.opCode)   // proven collision
        b.injectControlFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: op144, errorCode: 6))
        #expect(!b.badOpcodesForTesting.contains(op144),
                "a .control write NACK naming op144 must NEVER suppress the colliding CurrentBatteryV2 READ (CR-01)")
    }

    // MARK: - WR-01: an opcode-less control op77 never correlates to an outstanding READ

    /// With op20 the sole outstanding READ (txId 0), an OPCODE-LESS op77 on `.control` whose echoed txId (0)
    /// would otherwise correlate to op20 must NOT blacklist it — a control op77 says nothing about reads.
    @Test func anOpcodeLessControlOp77NeverBlacklistsAnOutstandingRead() async {
        let b = TandemBackend(testTransport: FakePumpTransport())   // connected
        await b.refreshLoadStatus()                                 // op20 outstanding, txId 0
        b.injectControlFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 0, errorCode: 0, txId: 0))
        #expect(!b.badOpcodesForTesting.contains(loadStatusOpcode),
                "a .control op77 must never correlate to / suppress an outstanding currentStatus READ (WR-01)")
        #expect(b.badOpcodesForTesting.isEmpty)
    }

    /// Control counterpart to the currentStatus self-heal test: the SAME opcode-less `[0,0]` op77 that
    /// self-heals op20 on `.currentStatus` must be inert on `.control`.
    @Test func theSameOpcodeLessErrorSelfHealsOnCurrentStatusButIsInertOnControl() async {
        // currentStatus → self-heals (records op20)
        let a = TandemBackend(testTransport: FakePumpTransport())
        await a.refreshLoadStatus()
        a.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 0, errorCode: 0))
        #expect(a.badOpcodesForTesting.contains(loadStatusOpcode), "currentStatus op77 self-heals op20")

        // control → inert (records nothing)
        let c = TandemBackend(testTransport: FakePumpTransport())
        await c.refreshLoadStatus()
        c.injectControlFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 0, errorCode: 0))
        #expect(c.badOpcodesForTesting.isEmpty, "the identical op77 on .control must record nothing (CR-01/WR-01)")
    }

    // MARK: - WR-02: fail closed when the echoed txId matches no outstanding read

    /// Full post-pair burst (many outstanding reads with distinct txIds), then a `.currentStatus` op77 whose
    /// echoed txId matches NO outstanding read. The old blind FIFO-oldest fallback would blacklist an
    /// innocent bootstrap read; the fix FAILS CLOSED (resolves to 0, records nothing).
    @Test func anOpcodeLessCurrentStatusOp77WithNoMatchingTxIdFailsClosed() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        b.startPollingForTesting()
        #expect(!b.outstandingReadsForTesting.isEmpty, "the burst must leave reads outstanding")
        #expect(b.outstandingReadsForTesting.count > 1, "must be ambiguous (more than one outstanding)")
        // txId 200 is never assigned in the burst (txIds are a small 0-based counter).
        b.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 0, errorCode: 0, txId: 200))
        #expect(b.badOpcodesForTesting.isEmpty,
                "an op77 whose txId matches no outstanding read must FAIL CLOSED — never guess the FIFO-oldest (WR-02)")
    }

    /// The single-outstanding on-demand path still self-heals WITHOUT a txId echo (unambiguous): exactly one
    /// read outstanding → resolve to it. (Proves WR-02's fail-closed change didn't break the wizard path.)
    @Test func aSoleOutstandingReadSelfHealsEvenWithoutATxIdEcho() async {
        let b = TandemBackend(testTransport: FakePumpTransport())
        await b.refreshLoadStatus()                                 // op20 sole outstanding, txId 0
        // Inject an op77 with a txId (77) that does NOT match op20's txId (0) — the exactly-one-outstanding
        // shortcut must still resolve to op20.
        b.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 0, errorCode: 0, txId: 77))
        #expect(b.badOpcodesForTesting.contains(loadStatusOpcode),
                "with exactly one read outstanding, an opcode-less op77 resolves to it unambiguously (WR-02)")
    }

    // MARK: - WR-03: non-vacuous burst correlation — txId echo picks the right read, not the oldest

    /// Full burst with 7+ distinct txIds; an op77 echoing op20's REAL wire txId must blacklist op20 — NOT
    /// the FIFO-oldest read. This is only satisfiable via the byTxId branch (op20 is sent last), so it can
    /// no longer be passed by a FIFO fallback.
    @Test func aBurstOp77EchoingLoadStatusTxIdBlacklistsLoadStatusNotTheOldest() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        b.startPollingForTesting()
        let op20 = loadStatusOpcode
        guard let op20TxId = b.outstandingReadsForTesting.first(where: { $0.opcode == op20 })?.txId else {
            Issue.record("op20 must be one of the outstanding reads after the burst"); return
        }
        guard let oldest = b.outstandingReadsForTesting.first?.opcode else {
            Issue.record("the burst must leave reads outstanding"); return
        }
        #expect(oldest != op20, "op20 is fastRead()'s LAST send — the FIFO-oldest must be a DIFFERENT read")
        b.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 0, errorCode: 0, txId: op20TxId))
        #expect(b.badOpcodesForTesting.contains(op20),
                "the op77's echoed txId identifies op20 — it must be the read blacklisted (WR-03)")
        #expect(!b.badOpcodesForTesting.contains(oldest),
                "the FIFO-oldest read must NOT be blacklisted — correlation is by txId echo, not by guessing oldest (WR-03)")
    }

    /// Negative: an op77 echoing an EARLIER read's txId blacklists THAT read (by txId), and op20 is left
    /// untouched — proving op20 is never blindly caught.
    @Test func aBurstOp77EchoingAnEarlierReadsTxIdDoesNotBlacklistLoadStatus() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        b.startPollingForTesting()
        let op20 = loadStatusOpcode
        guard let earlier = b.outstandingReadsForTesting.first(where: { $0.opcode != op20 }) else {
            Issue.record("expected at least one non-op20 outstanding read"); return
        }
        b.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 0, errorCode: 0, txId: earlier.txId))
        #expect(b.badOpcodesForTesting.contains(earlier.opcode),
                "the op77's echoed txId identifies the earlier read — that read is blacklisted (WR-03)")
        #expect(!b.badOpcodesForTesting.contains(op20),
                "op20 must NOT be blacklisted when the op77's txId points at a different read (WR-03)")
    }
}

/// IN-02 (debug pump-pairing-loop-api25, deep review): the calc-input reads (op-115 BolusCalcDataSnapshot,
/// op-109 ControlIQIOB) previously went out via the RAW `send` seam, bypassing the `badOpcodes` never-resend
/// guard, the `outstandingReads` correlation map, and the standing "read send →" log — inconsistent with
/// every other status read. They now route through the guarded `sendStatusRead`.
@Suite(.serialized) @MainActor
struct CalcInputGuardedSendTests {

    @Test func calcInputReadsRouteThroughTheGuardedSendPath() async {
        let s = PumpReadScheduler()
        s.isConnected = { true }
        s.send = { _ in 0 }
        s.calcInputRefreshTimeout = 0.05
        var dispatched: [UInt8] = []
        s.onReadDispatchedForTesting = { _, op in dispatched.append(op) }
        _ = await s.refreshCalcInputsConfirmed()
        #expect(dispatched.contains(BolusCalcDataSnapshotRequest.props.opCode),
                "op-115 must route through the guarded sendStatusRead path (IN-02)")
        #expect(dispatched.contains(ControlIQIOBRequest.props.opCode),
                "op-109 must route through the guarded sendStatusRead path (IN-02)")
    }

    /// Corollary: a calc-input read the pump has rejected is now SKIPPED by the never-resend guard, not
    /// re-sent every cycle (the exact pattern the raw seam did NOT honour before).
    @Test func aRejectedCalcInputReadIsSkippedNotResent() async {
        let s = PumpReadScheduler()
        s.isConnected = { true }
        s.send = { _ in 0 }
        s.calcInputRefreshTimeout = 0.05
        s.insertBadOpcode(ControlIQIOBRequest.props.opCode)   // op-109 previously rejected (a READ)
        var skipped: [UInt8] = []
        s.onReadSkippedForTesting = { _, op in skipped.append(op) }
        _ = await s.refreshCalcInputsConfirmed()
        #expect(skipped.contains(ControlIQIOBRequest.props.opCode),
                "a rejected calc-input read must be skipped by the badOpcodes guard, not re-sent (IN-02)")
    }
}
