import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// P10 (defect group A) — the cross-surface exit criterion (§A regression).
///
/// One stale sample is injected once; every model/policy-layer surface must report its age from the
/// reading's OWN source timestamp, never from when the message was received or published. The widget
/// families and the complication have no unit-test seam, so the shared substrate they render from is
/// pinned here instead:
///   • `GlucoseFreshness` — the phone's HUD and the single policy every surface shares,
///   • `RemoteClientModel` — the shared base for the Apple Watch, the Mac, and the remote-iPhone client,
///   • `WidgetSnapshot`   — the value every widget family and the complication read.
/// The Garmin surface is pinned in its own repo (the Monkey C epochs parse + the `historyEpochs`
/// schema key), since it consumes the same wire contract.
///
/// The keystone assertion is that a fresh *receive/publish* time cannot make an old *sample* read as
/// fresh: the sample is 60 min old but arrives "now", and every surface must still say 60 min / stale.
/// §A also requires that a reading reaching a display layer with NO source timestamp render as stale /
/// no-data, never fresh — asserted below. (The telemetry counter for that no-timestamp case is P12.)
@MainActor
@Suite(.serialized) struct CrossSurfaceStalenessTests {

    /// Minimal in-memory transport so a `RemoteClientModel` can be exercised without a real link.
    /// The test drives `handle(_:)` directly (the same entry point the link's `onReceive` calls), so
    /// nothing here is invoked — it only satisfies the initializer.
    private final class FakeLink: RemoteTransport {
        var onReceive: (@MainActor (RemoteCommand) -> Void)?
        var onReachabilityChange: (@MainActor (Bool) -> Void)?
        var onUndeliverable: (@MainActor (RemoteCommand) -> Void)?
        var isReachable: Bool = true
        func send(_ command: RemoteCommand) {}
    }

    /// A `statusRead` carrying a reading whose immutable source time is `sourceEpoch` (Unix seconds),
    /// exactly as the host composes it (`AppModel.statusCommand` sets `glucoseEpochSec`).
    private func statusRead(bgMgdl: Double, sourceEpoch: Int?) -> RemoteCommand {
        var cmd = RemoteCommand(kind: .statusRead, bgMgdl: bgMgdl)
        cmd.glucoseEpochSec = sourceEpoch
        return cmd
    }

    /// The keystone: a 60-min-old sample that arrives *now*. Age must come from the sample time, not
    /// from receipt — on the remote client, on the widget substrate, and via the shared policy.
    @Test func staleSampleAgesFromSourceNotReceiveTimeOnEverySurface() {
        let now = Date()
        let sourceEpoch = Int(now.timeIntervalSince1970) - 3600      // taken 60 min ago
        let sourceDate = Date(timeIntervalSince1970: TimeInterval(sourceEpoch))

        // --- RemoteClientModel (Apple Watch / Mac / remote-iPhone shared base) ---
        let model = RemoteClientModel(link: FakeLink())
        model.handle(statusRead(bgMgdl: 120, sourceEpoch: sourceEpoch))
        // The stored date is the SOURCE time, not receive time. If age were taken at receipt this
        // would be ≈ now and the deltas below would be ≈ 0.
        #expect(abs(model.glucoseDate!.timeIntervalSince1970 - Double(sourceEpoch)) < 2)
        #expect(model.ageMinutes! >= 59 && model.ageMinutes! <= 61)
        #expect(model.ageLabel == "1h ago")
        #expect(model.isGlucoseStale)          // 60 min ≫ any configured stale threshold

        // --- WidgetSnapshot (every widget family + the complication) ---
        // Built exactly as `RemoteClientModel.publishSnapshot` builds it
        // (Shared/RemoteClientModel.swift:233): `glucoseDate` is the SAMPLE time, `updatedAt` is the
        // PUBLISH/receive time. `updatedAt` is deliberately `now` (a brand-new publish) — staleness
        // must key off `glucoseDate`, so a fresh publish of an old sample stays stale.
        let snap = WidgetSnapshot(glucose: model.glucose, glucoseDate: model.glucoseDate,
                                  updatedAt: now, staleAfterSec: 5 * 60, hideAfterSec: nil)
        #expect(snap.glucoseDate == sourceDate)
        #expect(snap.isStale(asOf: now))       // off glucoseDate (60 min), NOT updatedAt (0 min)

        // --- GlucoseFreshness (the phone HUD + the one shared policy) ---
        #expect(GlucoseFreshness.isStale(sourceDate, now: now))
        #expect(GlucoseFreshness.ageLabel(for: sourceDate, now: now) == "1h ago")
        #expect(Int(GlucoseFreshness.age(of: sourceDate, now: now)) == 3600)
    }

    /// §A: a reading with a value but NO source timestamp (no epoch, no age) must render stale /
    /// no-data — never fresh — on every surface. The counter that records this case ships in P12.
    @Test func sampleWithNoSourceTimestampRendersStaleNeverFresh() {
        let model = RemoteClientModel(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead, bgMgdl: 120)
        cmd.glucoseEpochSec = nil
        cmd.glucoseAgeSec = nil
        model.handle(cmd)
        #expect(model.glucose == 120)
        #expect(model.glucoseDate == nil)
        #expect(model.isGlucoseStale)          // unknown age → stale, never fresh
        #expect(model.ageLabel == nil)

        // Widget substrate: a value with no sample date is stale at any `now`, and is shown (marked)
        // rather than hidden — matching the "old/unknown is worse than nothing" policy.
        let snap = WidgetSnapshot(glucose: 120, glucoseDate: nil, updatedAt: Date())
        #expect(snap.isStale(asOf: Date()))
        #expect(!snap.isHidden(asOf: Date()))

        // The shared policy agrees: a nil date is stale, and its presentation is `.stale` (shown), not
        // `.hidden` and never `.fresh`.
        #expect(GlucoseFreshness.isStale(nil))
        #expect(GlucoseFreshness.presentation(of: nil) == .stale)
    }

    /// Audit fix #1 (loop-comms study): a reading whose source timestamp is in the FUTURE must never
    /// read as fresh. A source with a fast clock stamps readings ahead of `now`; the raw elapsed time
    /// then goes negative and — before the fix — `age(of:)` clamped it to 0, so the reading presented
    /// as "fresh" indefinitely. A phantom-fresh future reading could suppress the stale-CGM bolus
    /// warning and mislead a manual dose, so beyond a small clock skew
    /// (`GlucoseFreshness.futureSkewTolerance`, 5 min) it is stale on every surface that shares the
    /// policy. Within the skew, ordinary jitter is tolerated and the reading is unaffected.
    @Test func futureDatedSampleRendersStaleBeyondClockSkew() {
        let now = Date()

        // 30 min in the future — far beyond the 5 min skew: stale, never fresh, on the shared policy.
        let future = now.addingTimeInterval(30 * 60)
        #expect(GlucoseFreshness.isStale(future, now: now))
        #expect(GlucoseFreshness.presentation(of: future, now: now) == .stale)

        // RemoteClientModel (Apple Watch / Mac / remote-iPhone shared base) delegates to the policy,
        // so the future-dated reading reads stale there too. (`isGlucoseStale` evaluates against the
        // real wall clock, ≈ `now`; a 30-min-ahead stamp is stale with wide margin.)
        let model = RemoteClientModel(link: FakeLink())
        model.handle(statusRead(bgMgdl: 120, sourceEpoch: Int(future.timeIntervalSince1970)))
        #expect(model.isGlucoseStale)

        // A few seconds ahead (within skew) is unaffected — still fresh, exactly like a fresh sample.
        let slightlyAhead = now.addingTimeInterval(5)
        #expect(!GlucoseFreshness.isStale(slightlyAhead, now: now))
        #expect(GlucoseFreshness.presentation(of: slightlyAhead, now: now) == .fresh)
    }

    /// Positive control so the stale checks above are not vacuously true: a 30-second-old sample reads
    /// fresh on every surface.
    @Test func freshSampleReadsFreshOnEverySurface() {
        let now = Date()
        let sourceEpoch = Int(now.timeIntervalSince1970) - 30       // taken 30 s ago
        let sourceDate = Date(timeIntervalSince1970: TimeInterval(sourceEpoch))

        let model = RemoteClientModel(link: FakeLink())
        model.handle(statusRead(bgMgdl: 120, sourceEpoch: sourceEpoch))
        #expect(!model.isGlucoseStale)
        #expect(model.ageMinutes == 0)

        let snap = WidgetSnapshot(glucose: 120, glucoseDate: sourceDate,
                                  updatedAt: now, staleAfterSec: 5 * 60)
        #expect(!snap.isStale(asOf: now))
        #expect(!GlucoseFreshness.isStale(sourceDate, now: now))
    }
}
