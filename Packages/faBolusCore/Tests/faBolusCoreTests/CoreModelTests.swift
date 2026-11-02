import XCTest
@testable import faBolusCore

final class CoreModelTests: XCTestCase {

    func testGlucoseRangeBoundaries() {
        // Closed clinical convention (owner 2026-08-06), agreeing with GlucoseStatistics: 180 is
        // in-range and 250 is high, so coloring matches the reported TIR at the exact boundaries.
        XCTAssertEqual(GlucoseRange.classify(69), .low)
        XCTAssertEqual(GlucoseRange.classify(70), .inRange)
        XCTAssertEqual(GlucoseRange.classify(180), .inRange)
        XCTAssertEqual(GlucoseRange.classify(181), .high)
        XCTAssertEqual(GlucoseRange.classify(250), .high)
        XCTAssertEqual(GlucoseRange.classify(251), .urgentHigh)
    }

    func testTrendTokens() {
        XCTAssertEqual(GlucoseTrend.up.token, "up")
        XCTAssertEqual(GlucoseTrend.rising.token, "up45")
        XCTAssertEqual(GlucoseTrend.downDown.token, "downdown")
        // The pump's Unicode arrow maps to its trend (PumpSession reads it this way), and from there to the
        // ASCII token remotes use.
        XCTAssertEqual(GlucoseTrend(rawValue: "↑")?.token, "up")
        XCTAssertEqual(GlucoseTrend(rawValue: "→")?.token, "flat")
        // Unknown or absent means UNKNOWN, and must stay unknown all the way to the remote. An old version
        // pinned the opposite ("unknown → flat"), which turned a pump reporting *no arrow* into a flat
        // arrow on the watch — an inferred trend shown as a reported one. Show less, never something inferred.
        XCTAssertNil(GlucoseTrend(rawValue: "garbage"))
        XCTAssertNil(GlucoseTrend(rawValue: ""))
    }

    /// The neutral PumpAlertKind raw values match TandemKit's notification kinds (reminder 0 / alert 1 /
    /// alarm 2 / cgmAlert 3), so PumpSession maps between them by raw value.
    func testAlertKindRawValuesMatchTheNotificationKinds() {
        XCTAssertEqual(PumpAlertKind.reminder.rawValue, 0)
        XCTAssertEqual(PumpAlertKind.alert.rawValue, 1)
        XCTAssertEqual(PumpAlertKind.alarm.rawValue, 2)
        XCTAssertEqual(PumpAlertKind.cgmAlert.rawValue, 3)
    }
}
