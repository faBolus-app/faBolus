import XCTest
@testable import faBolusCore

final class EatingTriggerTests: XCTestCase {
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: gates

    func testRecentBolusSuppresses() {
        var c = EatingTriggerConfig(); c.confirmationDelaySeconds = 0
        let e = EatingTriggerEngine(config: c)
        let s = EatingSignals(accelProb: 0.99, cgmMealScore: 0.9, minutesSinceBolus: 5)
        XCTAssertEqual(e.evaluate(s, now: t0), .suppress(reason: "bolused in the last 20 min"))
    }

    func testLocationGateSuppressesWhenNotAtMealPlace() {
        var c = EatingTriggerConfig(); c.confirmationDelaySeconds = 0; c.locationEnabled = true
        let e = EatingTriggerEngine(config: c)
        let s = EatingSignals(accelProb: 0.99, cgmMealScore: 0.9, minutesSinceBolus: 999, atMealPlace: false)
        if case .suppress = e.evaluate(s, now: t0) {} else { XCTFail("should suppress off-meal-place") }
    }

    // MARK: combine modes

    func testAllRequiresEverySignal() {
        var c = EatingTriggerConfig(); c.confirmationDelaySeconds = 0; c.combine = .all
        let e = EatingTriggerEngine(config: c)
        // accel positive, cgm below threshold → not met
        if case .hold = e.evaluate(EatingSignals(accelProb: 0.9, cgmMealScore: 0.2, minutesSinceBolus: 999), now: t0) {}
        else { XCTFail("all: partial should hold") }
        // both positive → fire (delay 0)
        XCTAssertEqual(e.evaluate(EatingSignals(accelProb: 0.9, cgmMealScore: 0.8, minutesSinceBolus: 999), now: t0), .fire)
    }

    func testAnyFiresOnOneSignal() {
        var c = EatingTriggerConfig(); c.confirmationDelaySeconds = 0; c.combine = .any
        let e = EatingTriggerEngine(config: c)
        XCTAssertEqual(e.evaluate(EatingSignals(accelProb: 0.9, cgmMealScore: 0.0, minutesSinceBolus: 999), now: t0), .fire)
    }

    // MARK: confirmation delay

    func testConfirmationDelayHoldsThenFires() {
        var c = EatingTriggerConfig(); c.combine = .any; c.confirmationDelaySeconds = 60
        let e = EatingTriggerEngine(config: c)
        let s = EatingSignals(accelProb: 0.9, minutesSinceBolus: 999)
        if case .hold = e.evaluate(s, now: t0) {} else { XCTFail("should hold during confirmation") }
        if case .hold = e.evaluate(s, now: t0.addingTimeInterval(30)) {} else { XCTFail("still confirming at 30s") }
        XCTAssertEqual(e.evaluate(s, now: t0.addingTimeInterval(61)), .fire, "fires once the delay elapses")
    }

    func testDelayResetsWhenConditionDrops() {
        var c = EatingTriggerConfig(); c.combine = .any; c.confirmationDelaySeconds = 60
        let e = EatingTriggerEngine(config: c)
        let hi = EatingSignals(accelProb: 0.9, minutesSinceBolus: 999)
        let lo = EatingSignals(accelProb: 0.1, minutesSinceBolus: 999)
        _ = e.evaluate(hi, now: t0)
        _ = e.evaluate(lo, now: t0.addingTimeInterval(30))     // drops → timer resets
        if case .hold = e.evaluate(hi, now: t0.addingTimeInterval(40)) {} else { XCTFail("restarts confirmation") }
        XCTAssertEqual(e.evaluate(hi, now: t0.addingTimeInterval(101)), .fire)
    }

    // MARK: estimator direction

    func testEstimatorDirection() {
        var strict = EatingTriggerConfig(); strict.combine = .all; strict.confirmationDelaySeconds = 120
        var loose = EatingTriggerConfig(); loose.combine = .any; loose.confirmationDelaySeconds = 0
        let s = EatingTriggerEstimator.estimate(strict)
        let l = EatingTriggerEstimator.estimate(loose)
        XCTAssertLessThan(s.falseAlertsPerDay, l.falseAlertsPerDay, "AND + long delay ⇒ fewer false alerts")
        XCTAssertGreaterThan(s.typicalTimeToAlertSeconds, l.typicalTimeToAlertSeconds, "…but a later nudge")
        XCTAssertGreaterThan(l.recallPercent, 0)
    }
}
