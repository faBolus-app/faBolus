import XCTest
@testable import faBolusCore

final class GlucoseArbiterTests: XCTestCase {
    private let now = Date()
    private func pumpState(glucose: Int?, ageSec: TimeInterval) -> PumpState {
        var s = PumpState()
        if let glucose {
            let at = now.addingTimeInterval(-ageSec)
            s.glucose = Observed(PumpGlucose(mgdl: glucose, trend: .flat), measuredAt: at, receivedAt: at)
        }
        return s
    }
    private func source(_ latest: GlucoseSample?, history: [GlucoseReading] = []) -> GlucoseSourceState {
        GlucoseSourceState(latest: latest, history: history, status: .connected)
    }
    private func sample(_ mgdl: Int, ageSec: TimeInterval, trend: GlucoseTrend = .up) -> GlucoseSample {
        // The failable init never fails here — every caller passes an in-range mgdl (e.g. 120).
        GlucoseSample(mgdl: mgdl, date: now.addingTimeInterval(-ageSec), trend: trend, sourceID: "mock")!
    }

    func testFreshPumpKeepsPumpValue() {
        let (state, _, prov) = GlucoseArbiter.merge(
            pumpState: pumpState(glucose: 100, ageSec: 60),
            pumpHistory: [], source: source(sample(120, ageSec: 30)), now: now)
        XCTAssertEqual(state.glucose?.value.mgdl, 100)  // pump is fresh → source ignored
        XCTAssertEqual(state.glucose?.source, .pump)
        XCTAssertEqual(prov, .pump)  // provenance = pump
    }

    func testFailsOverWhenPumpStale() {
        let failover = sample(120, ageSec: 30, trend: .up)
        let (state, _, prov) = GlucoseArbiter.merge(
            pumpState: pumpState(glucose: 100, ageSec: 10 * 60),
            pumpHistory: [], source: source(failover), now: now)
        XCTAssertEqual(state.glucose?.value.mgdl, 120)  // stale pump → fresh source takes over
        XCTAssertEqual(state.glucose?.value.trend, .up)
        // The failover value keeps the source's own measurement time and names its source.
        XCTAssertEqual(state.glucose?.measuredAt, failover.date)
        XCTAssertEqual(state.glucose?.source, .glucoseSource(id: "mock"))
        XCTAssertEqual(prov, .failover(sourceID: "mock", reason: .pumpStale))  // pump had a value → stale
    }

    func testFailoverWithNoTrendShowsNoArrow() {
        let noTrend = GlucoseSample(mgdl: 120, date: now.addingTimeInterval(-30), trend: nil, sourceID: "mock")!
        let (state, _, _) = GlucoseArbiter.merge(
            pumpState: pumpState(glucose: nil, ageSec: 0), pumpHistory: [], source: source(noTrend), now: now)
        XCTAssertNil(state.glucose?.value.trend)
    }

    func testFailoverReasonMissingWhenPumpHasNoReading() {
        let (state, _, prov) = GlucoseArbiter.merge(
            pumpState: pumpState(glucose: nil, ageSec: 0),
            pumpHistory: [], source: source(sample(120, ageSec: 30)), now: now)
        XCTAssertEqual(state.glucose?.value.mgdl, 120)
        XCTAssertEqual(prov, .failover(sourceID: "mock", reason: .pumpMissing))  // pump never had one
    }

    func testAllStaleKeepsPumpFlagged() {
        let pump = pumpState(glucose: 100, ageSec: 10 * 60)
        let (state, _, prov) = GlucoseArbiter.merge(
            pumpState: pump, pumpHistory: [], source: source(sample(120, ageSec: 10 * 60)), now: now)
        XCTAssertEqual(state.glucose?.value.mgdl, 100)  // never promotes a stale source
        XCTAssertTrue(state.isGlucoseStale(now: now))  // shown, but flagged stale
        XCTAssertEqual(prov, .pump)  // no failover → still pump
    }

    func testNoSourceReturnsPumpUnchanged() {
        let (state, hist, prov) = GlucoseArbiter.merge(
            pumpState: pumpState(glucose: 100, ageSec: 10 * 60),
            pumpHistory: [GlucoseReading(date: now, mgdl: 100)],
            source: nil, now: now)
        XCTAssertEqual(state.glucose?.value.mgdl, 100)
        XCTAssertEqual(hist.count, 1)
        XCTAssertEqual(prov, .pump)
    }

    func testHistoryDedupByFiveMinuteBucketPumpWins() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)  // fixed bucket boundary
        let pump = [GlucoseReading(date: t, mgdl: 100)]
        let source = [
            GlucoseReading(date: t.addingTimeInterval(60), mgdl: 150),  // same 5-min bucket
            GlucoseReading(date: t.addingTimeInterval(600), mgdl: 160)
        ]  // a later bucket
        let merged = GlucoseArbiter.mergeHistory(pump: pump, source: source)
        XCTAssertEqual(merged.count, 2)  // two buckets
        XCTAssertEqual(merged.first?.mgdl, 100)  // pump wins the shared bucket
        XCTAssertEqual(merged.last?.mgdl, 160)
        XCTAssertTrue(merged[0].date <= merged[1].date)  // sorted oldest→newest
    }

    // MARK: - The app-owned urgent-low alarm's pure activation rule

    func testProvenanceIsFailoverTrueOnlyForTheFailoverCase() {
        XCTAssertFalse(GlucoseProvenance.pump.isFailover)
        XCTAssertTrue(GlucoseProvenance.failover(sourceID: "x", reason: .pumpStale).isFailover)
        XCTAssertTrue(GlucoseProvenance.failover(sourceID: "x", reason: .pumpMissing).isFailover)
    }

    func testUrgentLowAlarmActiveOnlyWhenFailoverAndAtOrBelowThreshold() {
        let failover = GlucoseProvenance.failover(sourceID: "dexcom-share", reason: .pumpStale)
        XCTAssertTrue(
            UrgentLowAlarm.isActive(mgdl: UrgentLowAlarm.thresholdMgdl, provenance: failover),
            "AT the threshold must count as active (Dexcom's own Urgent Low fires AT 55, not only below it)")
        XCTAssertTrue(UrgentLowAlarm.isActive(mgdl: 40, provenance: failover))
        XCTAssertFalse(
            UrgentLowAlarm.isActive(mgdl: UrgentLowAlarm.thresholdMgdl + 1, provenance: failover),
            "above the threshold must not be urgent-low")
        XCTAssertFalse(
            UrgentLowAlarm.isActive(mgdl: 40, provenance: .pump),
            "must never fire while the pump's own feed is live — it remains the primary annunciator")
        XCTAssertFalse(
            UrgentLowAlarm.isActive(mgdl: nil, provenance: failover),
            "no live value at all is never 'urgent low'")
    }
}
