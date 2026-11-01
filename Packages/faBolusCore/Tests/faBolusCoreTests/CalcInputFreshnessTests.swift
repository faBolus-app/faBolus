import XCTest
@testable import faBolusCore

/// DIF-core: the calc-input freshness policy (IOB + therapy params) and the `PumpState` staleness
/// seams that gate the dose path. Mirrors `GlucoseFreshnessTests` for the glucose feed.
final class CalcInputFreshnessTests: XCTestCase {

    // MARK: - IOB threshold (default 300 s)

    func testIobStaleThresholdBoundary() {
        let now = Date()
        XCTAssertTrue(CalcInputFreshness.isIobStale(nil, thresholds: .standard, now: now))  // unknown → stale
        // 1 min → fresh
        XCTAssertFalse(CalcInputFreshness.isIobStale(now.addingTimeInterval(-60), thresholds: .standard, now: now))
        // just under 5 min
        XCTAssertFalse(CalcInputFreshness.isIobStale(now.addingTimeInterval(-299), thresholds: .standard, now: now))
        XCTAssertFalse(CalcInputFreshness.isIobStale(now, thresholds: .standard, now: now))  // at "now" → fresh
        // just over 5 min
        XCTAssertTrue(CalcInputFreshness.isIobStale(now.addingTimeInterval(-301), thresholds: .standard, now: now))
        // Exactly at the threshold is NOT stale (`>`), one second past IS.
        XCTAssertFalse(CalcInputFreshness.isIobStale(now.addingTimeInterval(-300), thresholds: .standard, now: now))
    }

    func testTherapyStaleThresholdBoundary() {
        let now = Date()
        XCTAssertTrue(CalcInputFreshness.isTherapyStale(nil, thresholds: .standard, now: now))  // unknown → stale
        // 5 min → still fresh (wider window)
        XCTAssertFalse(CalcInputFreshness.isTherapyStale(now.addingTimeInterval(-300), thresholds: .standard, now: now))
        // just under 15 min
        XCTAssertFalse(CalcInputFreshness.isTherapyStale(now.addingTimeInterval(-899), thresholds: .standard, now: now))
        // exactly at threshold
        XCTAssertFalse(CalcInputFreshness.isTherapyStale(now.addingTimeInterval(-900), thresholds: .standard, now: now))
        // just over 15 min
        XCTAssertTrue(CalcInputFreshness.isTherapyStale(now.addingTimeInterval(-901), thresholds: .standard, now: now))
    }

    func testFutureDatedIsStaleBeyondClockSkew() {
        let now = Date()
        // A read dated far in the future has an untrustworthy clock → stale, never "fresh" from a negative age.
        XCTAssertTrue(CalcInputFreshness.isIobStale(now.addingTimeInterval(30 * 60), thresholds: .standard, now: now))
        XCTAssertTrue(
            CalcInputFreshness.isTherapyStale(now.addingTimeInterval(30 * 60), thresholds: .standard, now: now))
        // Just past / just inside the skew boundary.
        XCTAssertTrue(
            CalcInputFreshness.isIobStale(
                now.addingTimeInterval(CalcInputFreshness.futureSkewTolerance + 1), thresholds: .standard, now: now))
        XCTAssertFalse(
            CalcInputFreshness.isIobStale(
                now.addingTimeInterval(CalcInputFreshness.futureSkewTolerance - 1), thresholds: .standard, now: now))
    }

    func testThresholdsAreConfigurable() {
        let now = Date()
        let t = FreshnessThresholds(insulinOnBoardStaleAfter: 120, therapyStaleAfter: 120)
        XCTAssertTrue(CalcInputFreshness.isIobStale(now.addingTimeInterval(-130), thresholds: t, now: now))
        XCTAssertFalse(CalcInputFreshness.isIobStale(now.addingTimeInterval(-110), thresholds: t, now: now))
        XCTAssertTrue(CalcInputFreshness.isTherapyStale(now.addingTimeInterval(-130), thresholds: t, now: now))
    }

    // MARK: - Three-state presentation (fresh / stale / hidden)

    func testPresentationThreeStates() {
        let now = Date()
        // no value → "--"
        XCTAssertEqual(CalcInputFreshness.iobPresentation(of: nil, thresholds: .standard, now: now), .hidden)
        XCTAssertEqual(
            CalcInputFreshness.iobPresentation(of: now.addingTimeInterval(-60), thresholds: .standard, now: now), .fresh
        )
        XCTAssertEqual(
            CalcInputFreshness.iobPresentation(of: now.addingTimeInterval(-600), thresholds: .standard, now: now),
            .stale)
        XCTAssertEqual(CalcInputFreshness.therapyPresentation(of: nil, thresholds: .standard, now: now), .hidden)
        XCTAssertEqual(
            CalcInputFreshness.therapyPresentation(of: now.addingTimeInterval(-60), thresholds: .standard, now: now),
            .fresh)
        XCTAssertEqual(
            CalcInputFreshness.therapyPresentation(of: now.addingTimeInterval(-1200), thresholds: .standard, now: now),
            .stale)
    }

    func testAgeLabel() {
        let now = Date()
        XCTAssertEqual(CalcInputFreshness.ageLabel(for: now, now: now), "now")
        XCTAssertEqual(CalcInputFreshness.ageLabel(for: now.addingTimeInterval(-180), now: now), "3 min ago")
        XCTAssertEqual(CalcInputFreshness.ageLabel(for: now.addingTimeInterval(-3600), now: now), "1h ago")
    }

    // MARK: - PumpState seams

    func testStateIobAndTherapyStale() {
        let now = Date()
        func observed<T>(_ value: T, ageSec: TimeInterval) -> Observed<T> {
            let at = now.addingTimeInterval(-ageSec)
            return Observed(value, measuredAt: at, receivedAt: at)
        }
        var s = PumpState()
        let calculator = BolusCalculatorSettings(
            carbRatio: 10, correctionFactor: 40, targetMgdl: 110, maxBolusUnits: 10)
        // Fresh readings → not stale.
        s.insulinOnBoard = observed(1.5, ageSec: 60)
        s.bolusCalculator = observed(calculator, ageSec: 60)
        XCTAssertFalse(s.isInsulinOnBoardStale(thresholds: .standard, now: now))
        XCTAssertFalse(s.isBolusCalculatorStale(thresholds: .standard, now: now))
        // Never read → stale, so the dose path prompts.
        s.insulinOnBoard = nil
        s.bolusCalculator = nil
        XCTAssertTrue(s.isInsulinOnBoardStale(thresholds: .standard, now: now))
        XCTAssertTrue(s.isBolusCalculatorStale(thresholds: .standard, now: now))
        // IOB just past its (tighter) window is stale while therapy of the same age is still fresh.
        s.insulinOnBoard = observed(1.5, ageSec: 6 * 60)
        s.bolusCalculator = observed(calculator, ageSec: 6 * 60)
        XCTAssertTrue(s.isInsulinOnBoardStale(thresholds: .standard, now: now))
        XCTAssertFalse(s.isBolusCalculatorStale(thresholds: .standard, now: now))
    }

    // MARK: - Saved thresholds

    /// Thresholds saved before the pump-status window existed read with its 15-minute default.
    func testSavedThresholdsWithoutThePumpStatusWindowReadWithItsDefault() throws {
        var saved = FreshnessThresholds(glucoseStaleAfter: 8 * 60, pumpStatusStaleAfter: 30 * 60)
        let data = try JSONEncoder().encode(saved)
        XCTAssertEqual(try JSONDecoder().decode(FreshnessThresholds.self, from: data), saved)
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        object["pumpStatusStaleAfter"] = nil
        let old = try JSONDecoder().decode(
            FreshnessThresholds.self, from: try JSONSerialization.data(withJSONObject: object))
        saved.pumpStatusStaleAfter = 15 * 60
        XCTAssertEqual(old, saved)
    }
}
