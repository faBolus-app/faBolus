import XCTest
@testable import faBolusCore

/// A stand-in `GlucoseSource` for arbiter tests.
@MainActor
private final class MockGlucoseSource: GlucoseSource {
    let id = "mock"
    let priority = 100
    var latest: GlucoseSample?
    var history: [GlucoseReading]
    var status: GlucoseSourceStatus = .connected
    var onChange: (@MainActor () -> Void)?
    init(latest: GlucoseSample?, history: [GlucoseReading] = []) {
        self.latest = latest; self.history = history
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
        GlucoseSample(mgdl: mgdl, date: Date().addingTimeInterval(-ageSec), trend: trend, sourceID: "mock")
    }

    func testFreshPumpKeepsPumpValue() {
        let src = MockGlucoseSource(latest: sample(120, ageSec: 30))
        let (snap, _) = GlucoseArbiter.merge(pumpSnapshot: snapshot(glucose: 100, ageSec: 60),
                                             pumpHistory: [], source: src)
        XCTAssertEqual(snap.glucose, 100)                    // pump is fresh → source ignored
    }

    func testFailsOverWhenPumpStale() {
        let src = MockGlucoseSource(latest: sample(120, ageSec: 30, trend: .up))
        let (snap, _) = GlucoseArbiter.merge(pumpSnapshot: snapshot(glucose: 100, ageSec: 10 * 60),
                                             pumpHistory: [], source: src)
        XCTAssertEqual(snap.glucose, 120)                    // stale pump → fresh source takes over
        XCTAssertEqual(snap.trend, GlucoseTrend.up.rawValue)
        XCTAssertTrue(snap.cgmActive)
    }

    func testAllStaleKeepsPumpFlagged() {
        let src = MockGlucoseSource(latest: sample(120, ageSec: 10 * 60))   // source also stale
        let pump = snapshot(glucose: 100, ageSec: 10 * 60)
        let (snap, _) = GlucoseArbiter.merge(pumpSnapshot: pump, pumpHistory: [], source: src)
        XCTAssertEqual(snap.glucose, 100)                    // never promotes a stale source
        XCTAssertTrue(snap.isGlucoseStale)                   // shown, but flagged stale
    }

    func testNoSourceReturnsPumpUnchanged() {
        let (snap, hist) = GlucoseArbiter.merge(pumpSnapshot: snapshot(glucose: 100, ageSec: 10 * 60),
                                                pumpHistory: [GlucoseReading(date: Date(), mgdl: 100)],
                                                source: nil)
        XCTAssertEqual(snap.glucose, 100)
        XCTAssertEqual(hist.count, 1)
    }

    func testHistoryDedupByFiveMinuteBucketPumpWins() {
        let t = Date(timeIntervalSince1970: 1_700_000_000)   // fixed bucket boundary
        let pump = [GlucoseReading(date: t, mgdl: 100)]
        let source = [GlucoseReading(date: t.addingTimeInterval(60), mgdl: 150),  // same 5-min bucket
                      GlucoseReading(date: t.addingTimeInterval(600), mgdl: 160)] // a later bucket
        let merged = GlucoseArbiter.mergeHistory(pump: pump, source: source)
        XCTAssertEqual(merged.count, 2)                      // two buckets
        XCTAssertEqual(merged.first?.mgdl, 100)              // pump wins the shared bucket
        XCTAssertEqual(merged.last?.mgdl, 160)
        XCTAssertTrue(merged[0].date <= merged[1].date)      // sorted oldest→newest
    }
}
