import XCTest
@testable import faBolusCore

final class GlucoseFreshnessTests: XCTestCase {
    func testIsStaleThreshold() {
        let now = Date()
        XCTAssertTrue(GlucoseFreshness.isStale(nil, thresholds: .standard, now: now))  // unknown → stale
        // 1 min → fresh
        XCTAssertFalse(GlucoseFreshness.isStale(now.addingTimeInterval(-60), thresholds: .standard, now: now))
        // just under 6 min
        XCTAssertFalse(GlucoseFreshness.isStale(now.addingTimeInterval(-359), thresholds: .standard, now: now))
        // just over 6 min
        XCTAssertTrue(GlucoseFreshness.isStale(now.addingTimeInterval(-361), thresholds: .standard, now: now))
    }

    func testFutureDatedReadingIsStaleBeyondClockSkew() {
        let now = Date()
        // Well beyond the 5 min skew → stale (would previously read fresh forever: negative age
        // clamped to 0). Both the boolean gate and the on-screen presentation agree.
        XCTAssertTrue(GlucoseFreshness.isStale(now.addingTimeInterval(30 * 60), thresholds: .standard, now: now))
        XCTAssertEqual(
            GlucoseFreshness.presentation(of: now.addingTimeInterval(30 * 60), thresholds: .standard, now: now), .stale)
        // Just past the skew boundary → stale; just inside it → fresh (ordinary jitter tolerated).
        XCTAssertTrue(
            GlucoseFreshness.isStale(
                now.addingTimeInterval(GlucoseFreshness.futureSkewTolerance + 1), thresholds: .standard, now: now))
        XCTAssertFalse(
            GlucoseFreshness.isStale(
                now.addingTimeInterval(GlucoseFreshness.futureSkewTolerance - 1), thresholds: .standard, now: now))
        XCTAssertEqual(
            GlucoseFreshness.presentation(of: now.addingTimeInterval(5), thresholds: .standard, now: now), .fresh)
    }

    func testThresholdIsConfigurable() {
        let now = Date()
        let t = FreshnessThresholds(glucoseStaleAfter: 120)
        XCTAssertTrue(GlucoseFreshness.isStale(now.addingTimeInterval(-130), thresholds: t, now: now))
        XCTAssertFalse(GlucoseFreshness.isStale(now.addingTimeInterval(-110), thresholds: t, now: now))
    }

    func testPresentationThreeStages() {
        let now = Date()
        let t = FreshnessThresholds(glucoseStaleAfter: 360, glucoseHideAfter: 1200)
        func p(_ ageSec: TimeInterval) -> GlucosePresentation {
            GlucoseFreshness.presentation(of: now.addingTimeInterval(-ageSec), thresholds: t, now: now)
        }
        XCTAssertEqual(p(60), .fresh)
        XCTAssertEqual(p(600), .stale)  // between stale and hide
        XCTAssertEqual(p(1300), .hidden)  // past hide
    }

    func testNeverHideAlwaysStale() {
        let now = Date()
        let t = FreshnessThresholds(glucoseStaleAfter: 360, glucoseHideAfter: nil)  // never hide
        XCTAssertEqual(
            GlucoseFreshness.presentation(of: now.addingTimeInterval(-99999), thresholds: t, now: now), .stale)
    }

    func testHideImmediatelySkipsGrey() {
        let now = Date()
        let t = FreshnessThresholds(glucoseStaleAfter: 360, glucoseHideAfter: 360)  // hide == stale → no grey
        XCTAssertEqual(GlucoseFreshness.presentation(of: now.addingTimeInterval(-100), thresholds: t, now: now), .fresh)
        XCTAssertEqual(
            GlucoseFreshness.presentation(of: now.addingTimeInterval(-400), thresholds: t, now: now), .hidden)
    }

    func testAgeLabel() {
        let now = Date()
        XCTAssertEqual(GlucoseFreshness.ageLabel(for: now, now: now), "now")
        XCTAssertEqual(GlucoseFreshness.ageLabel(for: now.addingTimeInterval(-180), now: now), "3 min ago")
        XCTAssertEqual(GlucoseFreshness.ageLabel(for: now.addingTimeInterval(-3600), now: now), "1h ago")
        XCTAssertEqual(GlucoseFreshness.ageLabel(for: now.addingTimeInterval(-3900), now: now), "1h 5m ago")
    }
}

/// A window that isn't a usable number fails closed: every reading is stale, never current forever.
final class NonFiniteFreshnessWindowTests: XCTestCase {
    func testANonFiniteWindowMakesEveryReadingStale() {
        let now = Date()
        let justNow = now.addingTimeInterval(-1)
        for bad in [TimeInterval.nan, .infinity, -1] {
            let t = FreshnessThresholds(
                glucoseStaleAfter: bad, insulinOnBoardStaleAfter: bad, therapyStaleAfter: bad)
            XCTAssertTrue(GlucoseFreshness.isStale(justNow, thresholds: t, now: now), "\(bad)")
            XCTAssertTrue(CalcInputFreshness.isIobStale(justNow, thresholds: t, now: now), "\(bad)")
            XCTAssertTrue(CalcInputFreshness.isTherapyStale(justNow, thresholds: t, now: now), "\(bad)")
            XCTAssertNotEqual(GlucoseFreshness.presentation(of: justNow, thresholds: t, now: now), .fresh)
            var s = PumpState()
            s.glucose = Observed(PumpGlucose(mgdl: 120, trend: nil), measuredAt: justNow, receivedAt: justNow)
            s.insulinOnBoard = Observed(1, measuredAt: justNow, receivedAt: justNow)
            XCTAssertNil(s.glucoseIfFresh(thresholds: t, now: now), "\(bad)")
            XCTAssertNil(s.insulinOnBoardIfFresh(thresholds: t, now: now), "\(bad)")
        }
    }

    func testANonFiniteIncludableAgeOffersNoInclude() {
        let now = Date()
        let t = FreshnessThresholds(maxIncludableGlucoseAge: .infinity)
        XCTAssertFalse(
            GlucoseFreshness.withinIncludableStaleness(now.addingTimeInterval(-3600), thresholds: t, now: now))
    }
}
