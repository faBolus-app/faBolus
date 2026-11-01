import Foundation
import Testing

@testable import faBolusCore

/// Which glucose the app shows when the pump's feed and a backup source disagree. The pump wins while
/// its reading is fresh; a backup only takes over with a fresh reading of its own; nothing stale is
/// ever promoted to current.
///
/// Ages are 10 s ("fresh") and an hour ("stale"), far from any `GlucoseFreshness.staleAfter` setting
/// (4 to 20 minutes): other suites pin that global while these run in parallel.
@Suite("Glucose arbiter precedence")
struct GlucoseArbiterPrecedenceTests {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let fresh: TimeInterval = 10
    let stale: TimeInterval = 60 * 60

    func pump(_ mgdl: Int?, age: TimeInterval, receivedAge: TimeInterval? = nil) -> PumpState {
        var state = PumpState()
        if let mgdl {
            state.glucose = Observed(
                PumpGlucose(mgdl: mgdl, trend: .flat), measuredAt: now.addingTimeInterval(-age),
                receivedAt: now.addingTimeInterval(-(receivedAge ?? age)))
        }
        return state
    }

    func backup(_ mgdl: Int, age: TimeInterval, id: String = "dexcom-g6") -> GlucoseSourceState {
        let sample = GlucoseSample(mgdl: mgdl, date: now.addingTimeInterval(-age), trend: .down, sourceID: id)
        return GlucoseSourceState(latest: sample, status: .connected)
    }

    func shown(_ pumpState: PumpState, _ source: GlucoseSourceState?) -> (Int?, ObservationSource?, GlucoseProvenance) {
        let (state, _, provenance) = GlucoseArbiter.merge(
            pumpState: pumpState, pumpHistory: [], source: source, thresholds: .standard, now: now)
        return (state.glucose?.value.mgdl, state.glucose?.source, provenance)
    }

    @Test("a fresh pump reading beats a fresher backup reading")
    func freshPumpBeatsFresherBackup() {
        let (mgdl, source, provenance) = shown(pump(100, age: fresh), backup(180, age: 1))
        #expect(mgdl == 100)
        #expect(source == .pump)
        #expect(provenance == .pump)
    }

    @Test("a stale pump reading hands over to a fresh backup")
    func backupTakesOverFromStalePump() {
        let (mgdl, source, provenance) = shown(pump(100, age: stale), backup(180, age: fresh))
        #expect(mgdl == 180)
        #expect(source == .glucoseSource(id: "dexcom-g6"))
        #expect(provenance == .failover(sourceID: "dexcom-g6", reason: .pumpStale))
    }

    @Test("a stale backup never replaces a stale pump reading")
    func staleBackupNeverPromoted() {
        let (mgdl, source, provenance) = shown(pump(100, age: stale), backup(180, age: stale))
        #expect(mgdl == 100)
        #expect(source == .pump)
        #expect(provenance == .pump)
    }

    @Test("a stale backup is not shown when the pump has nothing")
    func staleBackupWithNoPumpReading() {
        let (state, _, provenance) = GlucoseArbiter.merge(
            pumpState: pump(nil, age: 0), pumpHistory: [], source: backup(180, age: stale), thresholds: .standard,
            now: now)
        #expect(state.glucose == nil)
        #expect(provenance == .pump)
    }

    @Test("a backup reading dated in the future beyond clock skew is not trusted")
    func futureDatedBackupIgnored() {
        let future = GlucoseFreshness.futureSkewTolerance + 60
        let (mgdl, _, provenance) = shown(pump(100, age: stale), backup(180, age: -future))
        #expect(mgdl == 100)
        #expect(provenance == .pump)
    }

    @Test("a pump reading dated in the future counts as stale, so a fresh backup is shown")
    func futureDatedPumpLosesToFreshBackup() {
        let future = CalcInputFreshness.futureSkewTolerance + 60
        let (mgdl, _, provenance) = shown(pump(100, age: -future, receivedAge: 0), backup(180, age: fresh))
        #expect(mgdl == 180)
        #expect(provenance == .failover(sourceID: "dexcom-g6", reason: .pumpStale))
    }

    @Test("a backup with no reading changes nothing")
    func backupWithoutReading() {
        let empty = GlucoseSourceState(latest: nil, status: .unavailable(.dexcomAppNotConnected))
        let (mgdl, _, provenance) = shown(pump(100, age: stale), empty)
        #expect(mgdl == 100)
        #expect(provenance == .pump)
    }

    @Test("the failover reading keeps its own measurement time, so it ages from when it was measured")
    func failoverKeepsMeasurementTime() {
        let source = backup(180, age: fresh)
        let (state, _, _) = GlucoseArbiter.merge(
            pumpState: pump(nil, age: 0), pumpHistory: [], source: source, thresholds: .standard, now: now)
        #expect(state.glucose?.measuredAt == source.latest?.date)
        #expect(state.glucose?.receivedAt == now)
        #expect(state.isGlucoseStale(thresholds: .standard, now: now.addingTimeInterval(stale)))
    }

    @Test("history: the pump wins a shared 5-minute bucket even when the backup is listed later")
    func historyPumpWinsSharedBucket() {
        let t = Date(timeIntervalSince1970: 1_800_000_100)
        let merged = GlucoseArbiter.mergeHistory(
            pump: [GlucoseReading(date: t.addingTimeInterval(120), mgdl: 100)],
            source: [GlucoseReading(date: t, mgdl: 150), GlucoseReading(date: t.addingTimeInterval(170), mgdl: 155)])
        #expect(merged.map(\.mgdl) == [100])
    }
}
