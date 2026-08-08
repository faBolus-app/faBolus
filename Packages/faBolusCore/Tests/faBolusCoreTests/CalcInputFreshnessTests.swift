import XCTest
@testable import faBolusCore

/// DIF-core: the calc-input freshness policy (IOB + therapy params) and the `PumpSnapshot` staleness
/// seams that gate the dose path. Mirrors `GlucoseFreshnessTests` for the glucose feed.
final class CalcInputFreshnessTests: XCTestCase {

    // MARK: - IOB threshold (default 300 s)

    func testIobStaleThresholdBoundary() {
        let now = Date()
        XCTAssertTrue(CalcInputFreshness.isIobStale(nil, now: now))                             // unknown → stale
        XCTAssertFalse(CalcInputFreshness.isIobStale(now.addingTimeInterval(-60), now: now))    // 1 min → fresh
        XCTAssertFalse(CalcInputFreshness.isIobStale(now.addingTimeInterval(-299), now: now))   // just under 5 min
        XCTAssertFalse(CalcInputFreshness.isIobStale(now, now: now))                            // at "now" → fresh
        XCTAssertTrue(CalcInputFreshness.isIobStale(now.addingTimeInterval(-301), now: now))    // just over 5 min
        // Exactly at the threshold is NOT stale (`> staleAfter`), one second past IS.
        XCTAssertFalse(CalcInputFreshness.isIobStale(now.addingTimeInterval(-300), now: now))
    }

    func testTherapyStaleThresholdBoundary() {
        let now = Date()
        XCTAssertTrue(CalcInputFreshness.isTherapyStale(nil, now: now))                          // unknown → stale
        XCTAssertFalse(CalcInputFreshness.isTherapyStale(now.addingTimeInterval(-300), now: now))// 5 min → still fresh (wider window)
        XCTAssertFalse(CalcInputFreshness.isTherapyStale(now.addingTimeInterval(-899), now: now))// just under 15 min
        XCTAssertFalse(CalcInputFreshness.isTherapyStale(now.addingTimeInterval(-900), now: now))// exactly at threshold
        XCTAssertTrue(CalcInputFreshness.isTherapyStale(now.addingTimeInterval(-901), now: now)) // just over 15 min
    }

    func testFutureDatedIsStaleBeyondClockSkew() {
        let now = Date()
        // A read dated far in the future has an untrustworthy clock → stale, never "fresh" from a negative age.
        XCTAssertTrue(CalcInputFreshness.isIobStale(now.addingTimeInterval(30 * 60), now: now))
        XCTAssertTrue(CalcInputFreshness.isTherapyStale(now.addingTimeInterval(30 * 60), now: now))
        // Just past / just inside the skew boundary.
        XCTAssertTrue(CalcInputFreshness.isIobStale(now.addingTimeInterval(CalcInputFreshness.futureSkewTolerance + 1), now: now))
        XCTAssertFalse(CalcInputFreshness.isIobStale(now.addingTimeInterval(CalcInputFreshness.futureSkewTolerance - 1), now: now))
    }

    func testThresholdsAreConfigurable() {
        let now = Date()
        let originalIob = CalcInputFreshness.staleAfterIob
        let originalTherapy = CalcInputFreshness.staleAfterTherapy
        defer { CalcInputFreshness.staleAfterIob = originalIob; CalcInputFreshness.staleAfterTherapy = originalTherapy }
        CalcInputFreshness.staleAfterIob = 120
        CalcInputFreshness.staleAfterTherapy = 120
        XCTAssertTrue(CalcInputFreshness.isIobStale(now.addingTimeInterval(-130), now: now))
        XCTAssertFalse(CalcInputFreshness.isIobStale(now.addingTimeInterval(-110), now: now))
        XCTAssertTrue(CalcInputFreshness.isTherapyStale(now.addingTimeInterval(-130), now: now))
    }

    // MARK: - Three-state presentation (fresh / stale / hidden)

    func testPresentationThreeStates() {
        let now = Date()
        XCTAssertEqual(CalcInputFreshness.iobPresentation(of: nil, now: now), .hidden)               // no value → "--"
        XCTAssertEqual(CalcInputFreshness.iobPresentation(of: now.addingTimeInterval(-60), now: now), .fresh)
        XCTAssertEqual(CalcInputFreshness.iobPresentation(of: now.addingTimeInterval(-600), now: now), .stale)
        XCTAssertEqual(CalcInputFreshness.therapyPresentation(of: nil, now: now), .hidden)
        XCTAssertEqual(CalcInputFreshness.therapyPresentation(of: now.addingTimeInterval(-60), now: now), .fresh)
        XCTAssertEqual(CalcInputFreshness.therapyPresentation(of: now.addingTimeInterval(-1200), now: now), .stale)
    }

    func testAgeLabel() {
        let now = Date()
        XCTAssertEqual(CalcInputFreshness.ageLabel(for: now, now: now), "now")
        XCTAssertEqual(CalcInputFreshness.ageLabel(for: now.addingTimeInterval(-180), now: now), "3 min ago")
        XCTAssertEqual(CalcInputFreshness.ageLabel(for: now.addingTimeInterval(-3600), now: now), "1h ago")
    }

    // MARK: - PumpSnapshot seams

    func testSnapshotIobAndTherapyStale() {
        let now = Date()
        var s = PumpSnapshot()
        // Fresh dates → not stale.
        s.iobDate = now.addingTimeInterval(-60)
        s.therapyParamsDate = now.addingTimeInterval(-60)
        XCTAssertFalse(s.isIobStale(now: now))
        XCTAssertFalse(s.isTherapyStale(now: now))
        // Nil dates → stale (unknown age, even though iobUnits/carbRatio are numerically present).
        s.iobDate = nil; s.therapyParamsDate = nil
        XCTAssertTrue(s.isIobStale(now: now))
        XCTAssertTrue(s.isTherapyStale(now: now))
        // IOB just past its (tighter) window is stale while therapy of the same age is still fresh.
        let sixMinAgo = now.addingTimeInterval(-6 * 60)
        s.iobDate = sixMinAgo; s.therapyParamsDate = sixMinAgo
        XCTAssertTrue(s.isIobStale(now: now))
        XCTAssertFalse(s.isTherapyStale(now: now))
    }
}
