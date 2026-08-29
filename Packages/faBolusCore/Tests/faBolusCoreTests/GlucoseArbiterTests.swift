import XCTest
@testable import faBolusCore

/// A stand-in `GlucoseSource` for arbiter tests.
@MainActor
private final class MockGlucoseSource: GlucoseSource {
    let id = "mock"
    let priority = 100
    let connectionKind: GlucoseConnectionKind = .localBLE  // conformers must classify
    var latest: GlucoseSample?
    var history: [GlucoseReading]
    var status: GlucoseSourceStatus = .connected
    var onChange: (@MainActor () -> Void)?
    init(latest: GlucoseSample?, history: [GlucoseReading] = []) {
        self.latest = latest
        self.history = history
    }
    func start() async {}
    func stop() {}
}

@MainActor
final class GlucoseArbiterTests: XCTestCase {
    private func snapshot(glucose: Int?, ageSec: TimeInterval) -> PumpSnapshot {
        var s = PumpSnapshot()
        s.glucose = glucose
        s.glucoseDate = glucose == nil ? nil : Date().addingTimeInterval(-ageSec)
        s.trend = GlucoseTrend.flat.rawValue
        return s
    }
    private func sample(_ mgdl: Int, ageSec: TimeInterval, trend: GlucoseTrend = .up) -> GlucoseSample {
        // The failable init never fails here — every caller passes an in-range mgdl (e.g. 120).
        GlucoseSample(mgdl: mgdl, date: Date().addingTimeInterval(-ageSec), trend: trend, sourceID: "mock")!
    }

    func testFreshPumpKeepsPumpValue() {
        let src = MockGlucoseSource(latest: sample(120, ageSec: 30))
        let (snap, _, prov) = GlucoseArbiter.merge(
            pumpSnapshot: snapshot(glucose: 100, ageSec: 60),
            pumpHistory: [], source: src)
        XCTAssertEqual(snap.glucose, 100)  // pump is fresh → source ignored
        XCTAssertEqual(prov, .pump)  // provenance = pump
    }

    func testFailsOverWhenPumpStale() {
        let src = MockGlucoseSource(latest: sample(120, ageSec: 30, trend: .up))
        let (snap, _, prov) = GlucoseArbiter.merge(
            pumpSnapshot: snapshot(glucose: 100, ageSec: 10 * 60),
            pumpHistory: [], source: src)
        XCTAssertEqual(snap.glucose, 120)  // stale pump → fresh source takes over
        XCTAssertEqual(snap.trend, GlucoseTrend.up.rawValue)
        XCTAssertTrue(snap.cgmActive)
        XCTAssertEqual(prov, .failover(sourceID: "mock", reason: .pumpStale))  // pump had a value → stale
    }

    func testFailoverReasonMissingWhenPumpHasNoReading() {
        let src = MockGlucoseSource(latest: sample(120, ageSec: 30))
        let (snap, _, prov) = GlucoseArbiter.merge(
            pumpSnapshot: snapshot(glucose: nil, ageSec: 0),
            pumpHistory: [], source: src)
        XCTAssertEqual(snap.glucose, 120)
        XCTAssertEqual(prov, .failover(sourceID: "mock", reason: .pumpMissing))  // pump never had one
    }

    func testAllStaleKeepsPumpFlagged() {
        let src = MockGlucoseSource(latest: sample(120, ageSec: 10 * 60))  // source also stale
        let pump = snapshot(glucose: 100, ageSec: 10 * 60)
        let (snap, _, prov) = GlucoseArbiter.merge(pumpSnapshot: pump, pumpHistory: [], source: src)
        XCTAssertEqual(snap.glucose, 100)  // never promotes a stale source
        XCTAssertTrue(snap.isGlucoseStale)  // shown, but flagged stale
        XCTAssertEqual(prov, .pump)  // no failover → still pump
    }

    func testNoSourceReturnsPumpUnchanged() {
        let (snap, hist, prov) = GlucoseArbiter.merge(
            pumpSnapshot: snapshot(glucose: 100, ageSec: 10 * 60),
            pumpHistory: [GlucoseReading(date: Date(), mgdl: 100)],
            source: nil)
        XCTAssertEqual(snap.glucose, 100)
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
