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
///   (fastRead restored op20 `LoadStatusRequest` to 7 — debug pump-pairing-loop-api25 refinement.)
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
    // Debug pump-pairing-loop-api25 (refinement): op20 `LoadStatusRequest` is RESTORED to `fastRead()`
    // (tier back to 7) so the 09.9 `cartridgeReadyForBolus` pre-guard stays live on pumps that support it;
    // the API-2.5 t:slim X2 that rejects op20 learns-and-skips it via the per-pump persisted `badOpcodes`
    // set (one-drop-ever). See `PumpUnsupportedReadSelfHealTests` / `PumpLearnedOpcodePersistenceTests`.
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
    /// (fastRead restored op20 to 7 — debug pump-pairing-loop-api25 refinement.)
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

    // MARK: - Recurring poll-tick cadence (B2)

    /// Fires one `recurringPollTick()` and awaits long enough for that tick's `scheduleAlertRead()` call
    /// (armed with `alertReadDelaySecForTesting` set to a near-zero delay) to land, then returns everything
    /// dispatched during this single tick — in DISPATCH order. `recurringPollTick()`'s body calls
    /// `scheduleAlertRead()` (async, arrives LAST) BEFORE the synchronous `fastRead()`/`staticRead()` calls
    /// (which — when gated in — dispatch immediately), so the captured order per tick is always
    /// `[fastRead's 7 if %4] + [staticRead's 7 if %40] + [alertRead's 5, always, last]`.
    private func tickAndCollect(_ b: TandemBackend) async -> [String] {
        var dispatched: [String] = []
        b.onReadDispatchedForTesting = { typeName, _ in dispatched.append(typeName) }
        b.firePollTimerTickForTesting()
        try? await Task.sleep(nanoseconds: 20_000_000)   // margin over the 1ms alertReadDelaySecForTesting
        return dispatched
    }

    /// Gap B2: the recurring `pollTimer` tick fires the alert burst on EVERY tick, the fuller fast-read
    /// only when the tick counter is a multiple of 4, and the static/settings read only when it's a
    /// multiple of 40 — pinned across a real sequence of ticks (1 through 40) via the REAL tick body
    /// (`recurringPollTick()`, Task 2's behavior-preserving extraction), not the old
    /// `simulateRecurringFastAndStaticReadTickForTesting()` seam (which bypasses the `%`-gating entirely).
    @Test func recurringPollTickFiresAlertsEveryTickFastOnMod4StaticOnMod40() async {
        let b = backend()
        b.alertReadDelaySecForTesting = 0.001
        b.startPollingForTesting()
        // Let startPolling()'s OWN scheduled alertRead (armed by this same near-zero delay) land while
        // `onReadDispatchedForTesting` is still nil (a no-op call) — otherwise it could race into tick 1's
        // captured array below.
        try? await Task.sleep(nanoseconds: 50_000_000)

        // Ticks 1-3 (none is %4 or %40): only the every-tick alert burst.
        for tick in 1...3 {
            let dispatched = await tickAndCollect(b)
            #expect(dispatched == Self.alertReadTier, "tick \(tick) (not %4) must fire only the alert burst")
        }

        // Tick 4 (%4==0, %40!=0): fast fires (synchronously, first), then the alert burst (delayed, last)
        // — NOT static.
        let tick4 = await tickAndCollect(b)
        #expect(tick4 == Self.fastReadTier + Self.alertReadTier,
                "tick 4 must fire fast + alert, never static")

        // Ticks 5-39 (none is %4 or %40 again until 39→skip, but drive through them so tick 40 is reached
        // via the real counter, not a jump): only the every-tick alert burst — except every 4th one
        // (8, 12, ..., 36), which also fires fast.
        for tick in 5...39 {
            let dispatched = await tickAndCollect(b)
            if tick % 4 == 0 {
                #expect(dispatched == Self.fastReadTier + Self.alertReadTier,
                        "tick \(tick) (%4==0, %40!=0) must fire fast + alert, never static")
            } else {
                #expect(dispatched == Self.alertReadTier, "tick \(tick) (not %4) must fire only the alert burst")
            }
        }

        // Tick 40 (%4==0 AND %40==0): fast fires, then static fires (both synchronous, fast first per the
        // real body's `if %4 { fastRead() }` preceding `if %40 { staticRead() }`), then the alert burst.
        let tick40 = await tickAndCollect(b)
        #expect(tick40 == Self.fastReadTier + Self.staticReadTier + Self.alertReadTier,
                "tick 40 must fire BOTH fast and static (fast first), plus the every-tick alert burst")
    }
}
