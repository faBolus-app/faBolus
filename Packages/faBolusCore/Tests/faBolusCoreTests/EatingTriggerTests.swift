import XCTest
@testable import faBolusCore

final class EatingTriggerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: gates

    func testRecentBolusSuppresses() {
        var c = EatingTriggerConfig(); c.mode = .either; c.confirmationDelaySeconds = 0
        let e = EatingTriggerEngine(config: c)
        let s = EatingSignals(accelProb: 0.99, cgmMealScore: 0.9, minutesSinceBolus: 5)
        XCTAssertEqual(e.evaluate(s, now: t0), .suppress(reason: "bolused in the last 20 min"))
    }

    func testLocationGateSuppressesWhenNotAtMealPlace() {
        var c = EatingTriggerConfig(); c.mode = .either; c.confirmationDelaySeconds = 0; c.locationEnabled = true
        let e = EatingTriggerEngine(config: c)
        let s = EatingSignals(accelProb: 0.99, cgmMealScore: 0.9, minutesSinceBolus: 999, atMealPlace: false)
        if case .suppress = e.evaluate(s, now: t0) {} else { XCTFail("should suppress off-meal-place") }
    }

    // MARK: modes

    func testBothAlwaysRequiresBothSignals() {
        var c = EatingTriggerConfig(); c.mode = .bothAlways; c.confirmationDelaySeconds = 0
        let e = EatingTriggerEngine(config: c)
        if case .hold = e.evaluate(EatingSignals(accelProb: 0.9, cgmMealScore: 0.2, minutesSinceBolus: 999), now: t0) {}
        else { XCTFail("partial should hold") }
        XCTAssertEqual(e.evaluate(EatingSignals(accelProb: 0.9, cgmMealScore: 0.8, minutesSinceBolus: 999), now: t0), .fire)
    }

    func testCgmThenAccelRequiresCgmThenAccelConfirm() {
        var c = EatingTriggerConfig(); c.mode = .cgmThenAccel; c.confirmationDelaySeconds = 0
        let e = EatingTriggerEngine(config: c)
        // CGM alone (accel not yet sensed) → hold
        if case .hold = e.evaluate(EatingSignals(accelProb: nil, cgmMealScore: 0.8, minutesSinceBolus: 999), now: t0) {}
        else { XCTFail("CGM alone should hold until wrist confirms") }
        // CGM + wrist confirm → fire
        XCTAssertEqual(e.evaluate(EatingSignals(accelProb: 0.9, cgmMealScore: 0.8, minutesSinceBolus: 999), now: t0), .fire)
    }

    func testEitherFiresOnOneSignal() {
        var c = EatingTriggerConfig(); c.mode = .either; c.confirmationDelaySeconds = 0
        let e = EatingTriggerEngine(config: c)
        XCTAssertEqual(e.evaluate(EatingSignals(accelProb: 0.9, cgmMealScore: 0.0, minutesSinceBolus: 999), now: t0), .fire)
    }

    // MARK: confirmation delay

    func testConfirmationDelayHoldsThenFires() {
        var c = EatingTriggerConfig(); c.mode = .either; c.confirmationDelaySeconds = 60
        let e = EatingTriggerEngine(config: c)
        let s = EatingSignals(accelProb: 0.9, minutesSinceBolus: 999)
        if case .hold = e.evaluate(s, now: t0) {} else { XCTFail("should hold during confirmation") }
        if case .hold = e.evaluate(s, now: t0.addingTimeInterval(30)) {} else { XCTFail("still confirming at 30s") }
        XCTAssertEqual(e.evaluate(s, now: t0.addingTimeInterval(61)), .fire)
    }

    func testDelayResetsWhenConditionDrops() {
        var c = EatingTriggerConfig(); c.mode = .either; c.confirmationDelaySeconds = 60
        let e = EatingTriggerEngine(config: c)
        let hi = EatingSignals(accelProb: 0.9, minutesSinceBolus: 999)
        let lo = EatingSignals(accelProb: 0.1, minutesSinceBolus: 999)
        _ = e.evaluate(hi, now: t0)
        _ = e.evaluate(lo, now: t0.addingTimeInterval(30))
        if case .hold = e.evaluate(hi, now: t0.addingTimeInterval(40)) {} else { XCTFail("restarts confirmation") }
        XCTAssertEqual(e.evaluate(hi, now: t0.addingTimeInterval(101)), .fire)
    }

    // MARK: estimator

    func testEstimatorDirectionAndBattery() {
        var strict = EatingTriggerConfig(); strict.mode = .cgmThenAccel; strict.confirmationDelaySeconds = 120
        var loose = EatingTriggerConfig(); loose.mode = .either; loose.confirmationDelaySeconds = 0
        let s = EatingTriggerEstimator.estimate(strict)
        let l = EatingTriggerEstimator.estimate(loose)
        XCTAssertLessThan(s.falseAlertsPerDay, l.falseAlertsPerDay, "cgmThenAccel + delay ⇒ fewer false alerts")
        XCTAssertGreaterThan(s.typicalTimeToAlertSeconds, l.typicalTimeToAlertSeconds, "…but a later nudge")
        XCTAssertEqual(s.battery, .low, "cgmThenAccel keeps the wrist sensor off until the CGM flags a meal")
        XCTAssertEqual(l.battery, .high, "either runs the wrist sensor continuously")
    }

    func testCgmOnlyUsesNoExtraBattery() {
        var c = EatingTriggerConfig(); c.mode = .cgmOnly
        XCTAssertEqual(EatingTriggerEstimator.estimate(c).battery, EatingTriggerEstimate.Battery.none)
    }

    // MARK: accel numbers come from the model's assessment (not hardcoded guesses)

    func testAccelEstimateComesFromAssessmentOperatingPoints() {
        var c = EatingTriggerConfig(); c.mode = .accelOnly; c.accelThreshold = 0.85; c.confirmationDelaySeconds = 0
        let e = EatingTriggerEstimator.estimate(c)   // default metrics = the held-out assessment
        XCTAssertEqual(e.falseAlertsPerDay, 4.1, accuracy: 0.05, "0.85 operating point from RESULTS_SUMMARY")
        XCTAssertEqual(e.recallPercent, 62)
    }

    func testAccelMetricsInterpolateBetweenOperatingPoints() {
        let mid = EatingModelMetrics.faBolusDefault.at(0.875)  // halfway between 0.85 (4.1) and 0.90 (2.2)
        XCTAssertEqual(mid.falseAlertsPerDay, (4.1 + 2.2) / 2, accuracy: 0.05)
        XCTAssertEqual(mid.recall, (0.62 + 0.51) / 2, accuracy: 0.01)
    }

    func testCustomAccelMetricsOverrideDefault() {
        var c = EatingTriggerConfig(); c.mode = .accelOnly; c.accelThreshold = 0.9; c.confirmationDelaySeconds = 0
        let m = EatingModelMetrics(operatingPoints: [.init(threshold: 0.9, recall: 0.8, falseAlertsPerDay: 1.0)],
                                   source: "test")
        let e = EatingTriggerEstimator.estimate(c, accelMetrics: m)
        XCTAssertEqual(e.falseAlertsPerDay, 1.0, accuracy: 0.05)
        XCTAssertEqual(e.recallPercent, 80)
    }
}
