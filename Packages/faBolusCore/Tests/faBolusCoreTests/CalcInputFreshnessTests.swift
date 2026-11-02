import XCTest
@testable import faBolusCore

/// The calc-input freshness policy (IOB + therapy params) and the `PumpState` staleness
/// seams that gate the dose path. Mirrors `GlucoseFreshnessTests` for the glucose feed.
final class CalcInputFreshnessTests: XCTestCase {

    private let iob = FreshnessThresholds.standard.insulinOnBoardStaleAfter
    private let therapy = FreshnessThresholds.standard.therapyStaleAfter

    private func stale(_ ago: TimeInterval?, _ window: TimeInterval, now: Date) -> Bool {
        CalcInputFreshness.isStale(ago.map { now.addingTimeInterval(-$0) }, staleAfter: window, now: now)
    }

    // MARK: - IOB threshold (default 300 s)

    func testIobStaleThresholdBoundary() {
        let now = Date()
        XCTAssertTrue(stale(nil, iob, now: now))  // unknown → stale
        XCTAssertFalse(stale(60, iob, now: now))  // 1 min → fresh
        XCTAssertFalse(stale(299, iob, now: now))  // just under 5 min
        XCTAssertFalse(stale(0, iob, now: now))  // at "now" → fresh
        XCTAssertTrue(stale(301, iob, now: now))  // just over 5 min
        // Exactly at the threshold is NOT stale (`>`), one second past IS.
        XCTAssertFalse(stale(300, iob, now: now))
    }

    func testTherapyStaleThresholdBoundary() {
        let now = Date()
        XCTAssertTrue(stale(nil, therapy, now: now))  // unknown → stale
        XCTAssertFalse(stale(300, therapy, now: now))  // 5 min → still fresh (wider window)
        XCTAssertFalse(stale(899, therapy, now: now))  // just under 15 min
        XCTAssertFalse(stale(900, therapy, now: now))  // exactly at threshold
        XCTAssertTrue(stale(901, therapy, now: now))  // just over 15 min
    }

    func testFutureDatedIsStaleBeyondClockSkew() {
        let now = Date()
        // A read dated far in the future has an untrustworthy clock → stale, never "fresh" from a negative age.
        XCTAssertTrue(stale(-30 * 60, iob, now: now))
        XCTAssertTrue(stale(-30 * 60, therapy, now: now))
        // Just past / just inside the skew boundary.
        XCTAssertTrue(stale(-(CalcInputFreshness.futureSkewTolerance + 1), iob, now: now))
        XCTAssertFalse(stale(-(CalcInputFreshness.futureSkewTolerance - 1), iob, now: now))
    }

    func testThresholdsAreConfigurable() {
        let now = Date()
        let t = FreshnessThresholds(insulinOnBoardStaleAfter: 120, therapyStaleAfter: 120)
        XCTAssertTrue(stale(130, t.insulinOnBoardStaleAfter, now: now))
        XCTAssertFalse(stale(110, t.insulinOnBoardStaleAfter, now: now))
        XCTAssertTrue(stale(130, t.therapyStaleAfter, now: now))
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
