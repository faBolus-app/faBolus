import Foundation
import Testing
import faBolusCore

@testable import Alerts

/// The app-owned urgent-low alarm, ported from the alarm half of the old app's
/// `BackgroundWorkModelAndUrgentLowAlarmTests`: it raises once per episode on the backup source while the
/// pump's own feed is stale, also on a fresh below-range "LOW", and clears on recovery. The old suite's
/// background-work half was the old app's iOS background tasks, and its static
/// "never references the dose path" check was a source-text guard, which isn't ported.
@Suite struct UrgentLowAlarmTests {
    let m: TimeInterval = 60

    private func pumpState(mgdl: Int, at date: Date) -> PumpState {
        var s = PumpState()
        s.glucose = Observed(PumpGlucose(mgdl: mgdl, trend: nil), measuredAt: date, receivedAt: date)
        return s
    }

    private func backup(mgdl: Int?, at date: Date, belowRangeAt: Date? = nil) -> GlucoseSourceState {
        GlucoseSourceState(
            latest: mgdl.flatMap { GlucoseSample(mgdl: $0, date: date, sourceID: "dexcom-share") },
            status: .connected, belowRangeAt: belowRangeAt)
    }

    /// The pump's reading is 10 minutes old; the backup's fresh 55 takes over and raises the alarm once.
    /// A steady condition doesn't raise it again; the pump's feed returning clears it.
    @Test func raisesOnTheFailoverValueOnceAndClearsOnRecovery() async {
        let h = await Harness.launch()
        let now = h.clock.now
        await h.send(.readingsChanged([.glucose], pumpState(mgdl: 120, at: now.addingTimeInterval(-10 * m))))
        await h.coordinator.backupGlucoseChanged(backup(mgdl: UrgentLowAlarm.thresholdMgdl, at: now))
        let notice = await h.scheduler.held[UrgentLowAlarm.dedupeKey]
        #expect(notice?.category == .urgentLowGlucose, "its own category, not CGM loss")
        #expect(notice?.level == .timeSensitive)
        await h.scheduler.clearCalls()
        await h.coordinator.backupGlucoseChanged(backup(mgdl: 50, at: now.addingTimeInterval(1)))
        await h.coordinator.tick()
        #expect(await h.scheduler.adds.isEmpty, "a steady alarm must not re-fire")
        h.clock.advance(m)
        await h.send(.readingsChanged([.glucose], pumpState(mgdl: 120, at: h.clock.now)))
        #expect(await h.scheduler.removed == [UrgentLowAlarm.dedupeKey])
    }

    /// While the pump's own feed is live it is the annunciator: a low backup reading doesn't raise.
    @Test func doesNotRaiseWhileThePumpFeedIsFresh() async {
        let h = await Harness.launch()
        let now = h.clock.now
        await h.send(.readingsChanged([.glucose], pumpState(mgdl: 120, at: now)))
        await h.coordinator.backupGlucoseChanged(backup(mgdl: 45, at: now))
        #expect(await h.scheduler.held[UrgentLowAlarm.dedupeKey] == nil)
    }

    /// A LOW never becomes a sample, so merge reports pump provenance, yet the alarm fires off the fresh
    /// LOW with the pump's feed stale. Without this a below-range low with no pump reading would be
    /// invisible.
    @Test func raisesOnAFreshBelowRangeReadingWithoutFailoverProvenance() async {
        let h = await Harness.launch()
        let now = h.clock.now
        let low = backup(mgdl: nil, at: now, belowRangeAt: now)
        let (_, _, provenance) = GlucoseArbiter.merge(
            pumpState: PumpState(), pumpHistory: [], source: low, thresholds: .standard, now: now)
        #expect(provenance == .pump, "no valid sample exists to fail over to")
        await h.coordinator.backupGlucoseChanged(low)
        #expect(await h.scheduler.held[UrgentLowAlarm.dedupeKey] != nil)
    }

    /// A later in-range reading ends the LOW, and so does the LOW ageing out.
    @Test func anInRangeReadingAfterTheLowOrTheLowAgeingEndsIt() async {
        let h = await Harness.launch()
        let now = h.clock.now
        await h.coordinator.backupGlucoseChanged(backup(mgdl: nil, at: now, belowRangeAt: now))
        #expect(await h.scheduler.held[UrgentLowAlarm.dedupeKey] != nil)
        await h.coordinator.backupGlucoseChanged(backup(mgdl: 80, at: now.addingTimeInterval(5 * m), belowRangeAt: now))
        #expect(await h.scheduler.held[UrgentLowAlarm.dedupeKey] == nil)
        await h.coordinator.backupGlucoseChanged(backup(mgdl: nil, at: now, belowRangeAt: now))
        #expect(await h.scheduler.held[UrgentLowAlarm.dedupeKey] != nil)
        h.clock.advance(7 * m)
        await h.coordinator.tick()
        #expect(await h.scheduler.held[UrgentLowAlarm.dedupeKey] == nil, "a 7-minute-old LOW is stale")
    }

    @Test func canBeTurnedOff() async {
        let h = await Harness.launch()
        var policy = AlertPolicy()
        policy.setOn(false, for: .urgentLowGlucose)
        await h.coordinator.setPolicy(policy)
        await h.coordinator.backupGlucoseChanged(backup(mgdl: 45, at: h.clock.now))
        #expect(await h.scheduler.held.isEmpty)
    }
}
