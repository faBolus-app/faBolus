import Testing
import Foundation
import faBolusCore
import TandemMessages
import TandemBLE
@testable import faBolus

/// Pins that an unread cartridge-load state presents as unknown, never confirmed-ready. The dose path still allows `.unknown` (pump rejection is the backstop) so an op-20-excluded t:slim is not permanently blocked.
@Suite(.serialized) @MainActor
struct CartridgeReadinessFailClosedTests {

    private var loadStatusOpcode: UInt8 { LoadStatusRequest.props.opCode }

    // MARK: - Pure snapshot tri-state (faBolusCore)

    /// Default snapshot (op-20 never read): readiness is UNKNOWN — NOT a fail-open confirmed `.ready` — even
    /// though the dose-path block decision still allows (relies on the pump).
    @Test func defaultSnapshotReadsUnknownNotFailOpenReady() {
        let s = PumpSnapshot()
        #expect(s.cartridgeLoadState == 6, "the idle/unknown default")
        #expect(s.cartridgeReadiness == .unknown,
                "the fail-open default must read UNKNOWN, never a confirmed .ready")
        #expect(s.cartridgeReadyForBolus,
                "the dose-path block decision must still ALLOW when unknown — no permanent block")
    }

    /// A CONFIRMED non-loading op-20 reply reads `.ready`.
    @Test func confirmedNonLoadingReadsReady() {
        var s = PumpSnapshot()
        s.cartridgeLoadState = 6
        s.cartridgeLoadStateConfirmed = true
        #expect(s.cartridgeReadiness == .ready)
        #expect(s.cartridgeReadyForBolus)
    }

    /// A CONFIRMED loading state (0/1/2) reads `.notReady` and BLOCKS — fail-closed.
    @Test func confirmedLoadingStateReadsNotReadyAndBlocks() {
        for state in [0, 1, 2] {
            var s = PumpSnapshot()
            s.cartridgeLoadState = state
            s.cartridgeLoadStateConfirmed = true
            #expect(s.cartridgeReadiness == .notReady, "loading state \(state) must block")
            #expect(!s.cartridgeReadyForBolus, "loading state \(state) must fail the pre-guard closed")
        }
    }

    // MARK: - End-to-end (TandemBackend + PumpResponseApplier)

    /// A real polled op-20 reply CONFIRMS the state: a non-loading reply → `.ready`; a loading reply →
    /// `.notReady`. Proves the poll feeds the tri-state live on a supported pump.
    @Test func aRealLoadStatusReplyConfirmsReadiness() {
        let b = TandemBackend(testTransport: FakePumpTransport())
        #expect(b.snapshot.cartridgeReadiness == .unknown, "before any op-20 reply: unknown")

        b.injectStatusFrameForTesting(FakePumpTransport.loadStatus(isLoadingActive: false, loadStateId: 6))
        #expect(b.snapshot.cartridgeReadiness == .ready, "a confirmed non-loading reply reads .ready")
        #expect(b.snapshot.cartridgeLoadStateConfirmed)

        b.injectStatusFrameForTesting(FakePumpTransport.loadStatus(isLoadingActive: true, loadStateId: 0))
        #expect(b.snapshot.cartridgeReadiness == .notReady, "a confirmed loading reply reads .notReady")
        #expect(!b.snapshot.cartridgeReadyForBolus)
    }

    /// When op-20 is auto-excluded and never confirmed, the cartridge pre-check stays unknown — never
    /// fail-open confirmed-ready — yet the dose path is not permanently blocked.
    @Test func anExcludedLoadStatusLeavesReadinessUnknownNotFailOpenReady() async {
        let b = TandemBackend(testTransport: FakePumpTransport())   // testTransport init → connected
        await b.refreshLoadStatus()                                 // op-20 out (txId 0), now outstanding
        b.injectStatusFrameForTesting(FakePumpTransport.errorResponse(requestOpCode: 0, errorCode: 0))
        #expect(b.badOpcodesForTesting.contains(loadStatusOpcode), "op-20 is now auto-excluded")

        #expect(b.snapshot.cartridgeReadiness == .unknown,
                "an auto-excluded op-20 must leave the cartridge pre-check UNKNOWN, never confirmed-ready")
        #expect(!b.snapshot.cartridgeLoadStateConfirmed)
        #expect(b.snapshot.cartridgeReadyForBolus,
                "the dose path must NOT be permanently blocked on an op-20-excluded pump (relies on pump)")
    }
}
