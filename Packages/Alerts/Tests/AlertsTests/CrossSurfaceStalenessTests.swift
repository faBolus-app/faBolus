import Foundation
import Testing
import faBolusCore

@testable import Alerts

/// Every surface ages glucose from the sample's own measurement time, never its receive time, so a fresh
/// delivery of an old reading stays stale. Ported from the old app's suite of the same name: the shared
/// policy (`GlucoseFreshness`) and the alert surface (the urgent-low alarm and CGM loss) are here. The old
/// suite's remote-command fixture and widget snapshot are the watch's and the app's surfaces (their
/// slices); a reading with no timestamp can't exist any more (`Observed` requires one).
@Suite struct CrossSurfaceStalenessTests {
    let m: TimeInterval = 60

    private func pumpState(mgdl: Int, measuredAt: Date, receivedAt: Date) -> PumpState {
        var s = PumpState()
        s.glucose = Observed(PumpGlucose(mgdl: mgdl, trend: nil), measuredAt: measuredAt, receivedAt: receivedAt)
        return s
    }

    /// The keystone: a 60-minute-old sample that arrives now is stale on the shared policy, is CGM loss on
    /// the alert surface, and can't raise the urgent-low alarm.
    @Test func staleSampleAgesFromSourceNotReceiveTimeOnEverySurface() async {
        let h = await Harness.launch()
        let now = h.clock.now
        let taken = now.addingTimeInterval(-60 * m)
        #expect(GlucoseFreshness.isStale(taken, thresholds: .standard, now: now))
        #expect(GlucoseFreshness.ageLabel(for: taken, now: now) == "1h ago")
        #expect(Int(GlucoseFreshness.age(of: taken, now: now)) == 3600)

        await h.send(.readingsChanged([.glucose], pumpState(mgdl: 120, measuredAt: taken, receivedAt: now)))
        #expect(await h.coordinator.snapshot.cgmLost, "a fresh delivery of an old reading is still lost")
        // A 60-minute-old backup low, delivered now, isn't a current low.
        let oldLow = GlucoseSourceState(
            latest: GlucoseSample(mgdl: 45, date: taken, sourceID: "dexcom-share"), status: .connected)
        await h.coordinator.backupGlucoseChanged(oldLow)
        #expect(await h.scheduler.held[UrgentLowAlarm.dedupeKey] == nil)
    }

    /// A reading dated beyond the clock-skew tolerance in the future is never fresh: it can't raise the
    /// alarm and counts as lost. Within the skew it is unaffected.
    @Test func futureDatedSampleRendersStaleBeyondClockSkew() async {
        let h = await Harness.launch()
        let now = h.clock.now
        let future = now.addingTimeInterval(30 * m)
        #expect(GlucoseFreshness.isStale(future, thresholds: .standard, now: now))
        #expect(GlucoseFreshness.presentation(of: future, thresholds: .standard, now: now) == .stale)
        let futureLow = GlucoseSourceState(
            latest: GlucoseSample(mgdl: 45, date: future, sourceID: "dexcom-share"), status: .connected)
        await h.coordinator.backupGlucoseChanged(futureLow)
        #expect(await h.scheduler.held[UrgentLowAlarm.dedupeKey] == nil)
        await h.send(.readingsChanged([.glucose], pumpState(mgdl: 120, measuredAt: future, receivedAt: now)))
        #expect(await h.coordinator.snapshot.cgmLost)

        let slightlyAhead = now.addingTimeInterval(5)
        #expect(!GlucoseFreshness.isStale(slightlyAhead, thresholds: .standard, now: now))
        #expect(GlucoseFreshness.presentation(of: slightlyAhead, thresholds: .standard, now: now) == .fresh)
    }

    /// No reading at all is "no data", not lost.
    @Test func noReadingIsNotCgmLoss() async {
        let h = await Harness.launch()
        await h.coordinator.backupGlucoseChanged(nil)
        #expect(await !h.coordinator.snapshot.cgmLost)
    }

    /// Positive control: a 30-second-old sample is fresh on every surface, and a fresh backup low raises.
    @Test func freshSampleReadsFreshOnEverySurface() async {
        let h = await Harness.launch()
        let now = h.clock.now
        let taken = now.addingTimeInterval(-30)
        #expect(!GlucoseFreshness.isStale(taken, thresholds: .standard, now: now))
        await h.send(.readingsChanged([.glucose], pumpState(mgdl: 120, measuredAt: taken, receivedAt: now)))
        #expect(await !h.coordinator.snapshot.cgmLost)
        // The pump's reading goes stale; a fresh backup low raises.
        h.clock.advance(10 * m)
        let low = GlucoseSourceState(
            latest: GlucoseSample(mgdl: 45, date: h.clock.now.addingTimeInterval(-30), sourceID: "dexcom-share"),
            status: .connected)
        await h.coordinator.backupGlucoseChanged(low)
        #expect(await h.scheduler.held[UrgentLowAlarm.dedupeKey] != nil)
        #expect(await !h.coordinator.snapshot.cgmLost, "the backup's fresh reading is shown")
    }

    /// CGM loss is shown in the app and never posted, and the user's freshness window decides it.
    @Test func cgmLossIsNeverPostedAndFollowsTheUsersWindow() async {
        let h = await Harness.launch()
        let now = h.clock.now
        await h.send(
            .readingsChanged(
                [.glucose], pumpState(mgdl: 120, measuredAt: now.addingTimeInterval(-8 * m), receivedAt: now)))
        #expect(await h.coordinator.snapshot.cgmLost)
        #expect(await h.scheduler.held.isEmpty)
        await h.coordinator.freshnessChanged(FreshnessThresholds(glucoseStaleAfter: 10 * m))
        #expect(await !h.coordinator.snapshot.cgmLost)
    }
}
