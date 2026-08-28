import Testing
import Foundation
import TandemBLE
@testable import faBolus

/// Exact ordered membership of bootstrap/fast/static/alert reads so a silent drop of a dose-path
/// read (e.g. LoadStatus for cartridge-ready) cannot slip through a count-only check.
@Suite(.serialized) @MainActor
struct ReadCascadeMembershipGuardTests {
    private func backend() -> TandemBackend { TandemBackend(testTransport: FakePumpTransport()) }

    // MARK: - Exact ordered tier membership

    private static let bootstrapTrio = ["ApiVersionRequest", "PumpVersionRequest", "TimeSinceResetRequest"]
    // op20 stays in fastRead so cartridge-ready stays live on supported pumps; a pump that
    // rejects it learns-and-skips via persisted `badOpcodes`.
    private static let fastReadTier = [
        "ControlIQIOBRequest", "CurrentEGVGuiDataRequest", "InsulinStatusRequest", "LastBolusStatusV2Request",
        "CurrentBatteryV2Request", "HomeScreenMirrorRequest", "LoadStatusRequest",
    ]
    // op20 is identity-gated: held out of the pre-version burst, then sent after op33/op85
    // identify the pump (known-bad t:slim X2 sw-2.5 suppresses it before the first send).
    private static let fastReadTierPreVersion = [
        "ControlIQIOBRequest", "CurrentEGVGuiDataRequest", "InsulinStatusRequest", "LastBolusStatusV2Request",
        "CurrentBatteryV2Request", "HomeScreenMirrorRequest",
    ]
    private static let staticReadTier = [
        "CurrentBasalStatusRequest", "BolusCalcDataSnapshotRequest", "TimeSinceResetRequest",
        "ApiVersionRequest", "PumpFeaturesV1Request", "ControlIQInfoV2Request", "BasalLimitSettingsRequest",
    ]
    // Control-IQ-era AAM reads (op120/op146) are not in alertRead — they provoked the API-2.5 reconnect loop.
    private static let alertReadTier = [
        "AlertStatusRequest", "AlarmStatusRequest", "CGMAlertStatusRequest", "ReminderStatusRequest",
        "MalfunctionStatusRequest",
    ]

    /// `startPollingForTesting()` dispatches, synchronously: the bootstrap trio, then fastRead's 6 NON-gated
    /// reads (op20 deferred), then staticRead's 7 (16 total) — then, after `alertReadDelaySecForTesting`,
    /// alertRead's 5 (21 total). Once the bootstrap version responses identify the pump, the deferred op20 is
    /// dispatched (restored to the cascade after identity). This is the FULL exact-membership pin gap B1
    /// asks for — a stronger check than the count-only (16) + prefix(3)/[3] assertions in
    /// `PumpPairingPostPairBootstrapOrderTests`.
    /// (debug pump-pairing-loop-api25 static-registry hardening: op20 is identity-gated — deferred out of the
    /// pre-version burst, then dispatched after the op33/op85 version responses identify the pump.)
    @Test func startPollingDispatchesTheExactOrderedTrioThenFastThenStaticThenAlert() async {
        let b = backend()
        b.alertReadDelaySecForTesting = 0.05
        var dispatched: [String] = []
        b.onReadDispatchedForTesting = { typeName, _ in dispatched.append(typeName) }
        b.startPollingForTesting()

        #expect(dispatched.count == 16, "trio (3) + fastRead's 6 non-gated (op20 deferred) + staticRead (7) must be synchronous")
        #expect(Array(dispatched[0..<3]) == Self.bootstrapTrio, "bootstrap trio must be first, in this exact order")
        #expect(Array(dispatched[3..<9]) == Self.fastReadTierPreVersion, "fastRead's 6 non-gated reads must follow, in this exact order (op20 deferred)")
        #expect(Array(dispatched[9..<16]) == Self.staticReadTier, "staticRead's 7 must follow, in this exact order")
        #expect(!dispatched.contains("LoadStatusRequest"), "op20 must NOT appear in the pre-version burst — it is identity-gated")

        try? await Task.sleep(nanoseconds: 200_000_000)   // let the delayed alertRead() burst land
        #expect(dispatched.count == 21, "alertRead's 5 must follow after the alert-read delay (op20 still deferred)")
        #expect(Array(dispatched[16..<21]) == Self.alertReadTier, "alertRead's 5 must be in this exact order")

        // Once the bootstrap version responses identify the pump (a SUPPORTED pump here — default identity),
        // the deferred op20 IS dispatched, restoring it to the read cascade (owner req #2).
        b.releaseIdentityGatedReadsForTesting()
        #expect(dispatched.contains("LoadStatusRequest"),
                "op20 must be dispatched once the version responses identify a supported pump")
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
