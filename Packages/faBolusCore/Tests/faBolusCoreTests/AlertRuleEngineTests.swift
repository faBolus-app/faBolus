import XCTest
@testable import faBolusCore

final class AlertRuleEngineTests: XCTestCase {
    private func alert(_ kind: PumpAlertKind, id: Int = 1) -> PumpAlert {
        PumpAlert(id: id, kind: kind, title: "t", detail: "", isDismissable: true)
    }
    private func at(_ hour: Int, _ minute: Int = 0) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = 1; c.day = 1; c.hour = hour; c.minute = minute
        return Calendar(identifier: .gregorian).date(from: c)!
    }

    func testAlarmsAreNeverAutoActed() {
        let rule = AlertRule(kinds: [], action: .autoDismiss)          // matches "any eligible kind"
        XCTAssertNil(AlertRuleEngine.action(for: alert(.alarm), rules: [rule], now: at(3), glucose: nil))
    }

    func testTimeWindowMatch() {
        let rule = AlertRule(name: "overnight", kinds: [.cgmAlert],
                             startMinuteOfDay: 22 * 60, endMinuteOfDay: 7 * 60, action: .autoSnooze)  // wraps midnight
        XCTAssertEqual(AlertRuleEngine.action(for: alert(.cgmAlert), rules: [rule], now: at(3), glucose: 90), .autoSnooze)
        XCTAssertNil(AlertRuleEngine.action(for: alert(.cgmAlert), rules: [rule], now: at(12), glucose: 90))
    }

    func testKindFilter() {
        let rule = AlertRule(kinds: [.reminder], action: .autoSnooze)
        XCTAssertNil(AlertRuleEngine.action(for: alert(.cgmAlert), rules: [rule], now: at(3), glucose: nil))
        XCTAssertEqual(AlertRuleEngine.action(for: alert(.reminder), rules: [rule], now: at(3), glucose: nil), .autoSnooze)
    }

    func testAlertIdFilter() {
        let rule = AlertRule(kinds: [.alert], alertIds: [42], action: .autoDismiss)
        XCTAssertNil(AlertRuleEngine.action(for: alert(.alert, id: 7), rules: [rule], now: at(3), glucose: nil))
        XCTAssertEqual(AlertRuleEngine.action(for: alert(.alert, id: 42), rules: [rule], now: at(3), glucose: nil), .autoDismiss)
    }

    func testGlucoseGateNeedsReading() {
        let rule = AlertRule(kinds: [.cgmAlert], glucoseAbove: 250, action: .autoSnooze)
        XCTAssertNil(AlertRuleEngine.action(for: alert(.cgmAlert), rules: [rule], now: at(12), glucose: nil))  // no reading
        XCTAssertNil(AlertRuleEngine.action(for: alert(.cgmAlert), rules: [rule], now: at(12), glucose: 200))  // not above
        XCTAssertEqual(AlertRuleEngine.action(for: alert(.cgmAlert), rules: [rule], now: at(12), glucose: 300), .autoSnooze)
    }

    func testDisabledRuleIgnoredAndFirstMatchWins() {
        let off = AlertRule(enabled: false, kinds: [.reminder], action: .autoDismiss)
        let on = AlertRule(enabled: true, kinds: [.reminder], action: .autoSnooze)
        XCTAssertEqual(AlertRuleEngine.action(for: alert(.reminder), rules: [off, on], now: at(3), glucose: nil), .autoSnooze)
    }

    func testFullDayWindowAlwaysMatches() {
        let rule = AlertRule(kinds: [.reminder], startMinuteOfDay: 0, endMinuteOfDay: 0, action: .autoSnooze)
        XCTAssertEqual(AlertRuleEngine.action(for: alert(.reminder), rules: [rule], now: at(17, 30), glucose: nil), .autoSnooze)
    }
}
