import Testing
import Foundation
import TandemBLE
@testable import faBolus

/// Phase 09 (D-01, gap B1/B2 — `.planning/phases/09-god-object-refactor-appmodel-tandembackend-extraction/`).
/// Wave 1 guard tests for Target B (the BLE read cascade), closing the two send-side gaps the analyzer
/// found MISSING before any extraction lands:
///
/// - B1: `PumpPairingPostPairBootstrapOrderTests`/`PumpEgvPollTests` already pin the bootstrap-trio-FIRST
///   invariant and total dispatch COUNTS (17 / 14), but never assert the exact ordered MEMBERSHIP of
///   `fastRead()` (7)/`alertRead()` (5)/`staticRead()` (7) — a reorder or silent drop inside a tier could
///   still slip through a count-only check. This suite pins the exact ordered list per tier, split into
///   trio/fast/static/alert segments, straight from `TandemBackend.swift:314-318,1708-1736`.
/// - B2: the recurring `pollTimer` tick's cadence gating (alerts every tick, fast on `tick%4`, static on
///   `tick%40`, `:1874-1878`) had NO guard at all — the existing
///   `simulateRecurringFastAndStaticReadTickForTesting()` seam calls `fastRead()`/`staticRead()` directly,
///   bypassing the `%`-gating entirely, so it cannot prove the cadence. This suite's cadence section drives
///   the REAL tick body via the new `firePollTimerTickForTesting()` seam (Task 2's `recurringPollTick()`
///   micro-extraction — a behavior-preserving move of the pollTimer closure's four lines into a named,
///   directly-callable function; see that function's own doc comment).
///
/// Both gaps close BEFORE Wave 3 (`PumpReadScheduler`, D-06) and Wave 4 (the response-applier, D-07)
/// extractions land — this net is what proves those moves send byte-identical reads in the same order at
/// the same cadence. No wire bytes change in this suite.
@Suite(.serialized) @MainActor
struct ReadCascadeMembershipGuardTests {
    private func backend() -> TandemBackend { TandemBackend(testTransport: FakePumpTransport()) }

    // MARK: - Exact ordered tier membership (B1)

    private static let bootstrapTrio = ["ApiVersionRequest", "PumpVersionRequest", "TimeSinceResetRequest"]
    private static let fastReadTier = [
        "ControlIQIOBRequest", "CurrentEGVGuiDataRequest", "InsulinStatusRequest", "LastBolusStatusV2Request",
        "CurrentBatteryV2Request", "HomeScreenMirrorRequest", "LoadStatusRequest",
    ]
    private static let staticReadTier = [
        "CurrentBasalStatusRequest", "BolusCalcDataSnapshotRequest", "TimeSinceResetRequest",
        "ApiVersionRequest", "PumpFeaturesV1Request", "ControlIQInfoV2Request", "BasalLimitSettingsRequest",
    ]
    private static let alertReadTier = [
        "AlertStatusRequest", "AlarmStatusRequest", "CGMAlertStatusRequest", "ReminderStatusRequest",
        "MalfunctionStatusRequest",
    ]

    /// `startPollingForTesting()` dispatches, synchronously: the bootstrap trio, then fastRead's 7, then
    /// staticRead's 7 (17 total) — then, after `alertReadDelaySecForTesting`, alertRead's 5 (22 total).
    /// This is the FULL exact-membership pin gap B1 asks for — a stronger check than the existing
    /// count-only (17) + prefix(3)/[3] assertions in `PumpPairingPostPairBootstrapOrderTests`.
    @Test func startPollingDispatchesTheExactOrderedTrioThenFastThenStaticThenAlert() async {
        let b = backend()
        b.alertReadDelaySecForTesting = 0.05
        var dispatched: [String] = []
        b.onReadDispatchedForTesting = { typeName, _ in dispatched.append(typeName) }
        b.startPollingForTesting()

        #expect(dispatched.count == 17, "trio (3) + fastRead (7) + staticRead (7) must be synchronous")
        #expect(Array(dispatched[0..<3]) == Self.bootstrapTrio, "bootstrap trio must be first, in this exact order")
        #expect(Array(dispatched[3..<10]) == Self.fastReadTier, "fastRead's 7 must follow, in this exact order")
        #expect(Array(dispatched[10..<17]) == Self.staticReadTier, "staticRead's 7 must follow, in this exact order")

        try? await Task.sleep(nanoseconds: 200_000_000)   // let the delayed alertRead() burst land
        #expect(dispatched.count == 22, "alertRead's 5 must follow after the alert-read delay")
        #expect(Array(dispatched[17..<22]) == Self.alertReadTier, "alertRead's 5 must be in this exact order")
    }

    /// `simulateRecurringFastAndStaticReadTickForTesting()` calls `fastRead()`/`staticRead()` directly with
    /// NO bootstrap prepend — pins the exact ordered membership of both tiers back-to-back with no trio.
    @Test func recurringFastAndStaticTickDispatchesExactOrderedFastThenStaticWithNoBootstrap() {
        let b = backend()
        var dispatched: [String] = []
        b.onReadDispatchedForTesting = { typeName, _ in dispatched.append(typeName) }
        b.simulateRecurringFastAndStaticReadTickForTesting()

        #expect(dispatched.count == 14, "fastRead (7) + staticRead (7), no bootstrap trio")
        #expect(Array(dispatched[0..<7]) == Self.fastReadTier, "fastRead's 7 must be in this exact order")
        #expect(Array(dispatched[7..<14]) == Self.staticReadTier, "staticRead's 7 must be in this exact order")
        #expect(dispatched.first != "ApiVersionRequest",
                "no bootstrap-trio prepend — the first dispatch must be fastRead's own ControlIQIOBRequest")
    }
}
