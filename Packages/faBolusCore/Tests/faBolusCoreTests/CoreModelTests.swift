import XCTest
@testable import faBolusCore

final class CoreModelTests: XCTestCase {

    func testGlucoseStaleness() {
        var s = PumpSnapshot()
        XCTAssertFalse(s.isGlucoseStale)                 // no glucose at all → not "stale" per rule
        s.glucose = 120; s.glucoseDate = nil
        XCTAssertTrue(s.isGlucoseStale)                  // have a value but unknown age → stale
        s.glucoseDate = Date()
        XCTAssertFalse(s.isGlucoseStale)                 // fresh
        s.glucoseDate = Date().addingTimeInterval(-7 * 60)
        XCTAssertTrue(s.isGlucoseStale)                  // older than 6 min
    }

    func testGlucoseRangeBoundaries() {
        XCTAssertEqual(GlucoseRange.classify(69), .low)
        XCTAssertEqual(GlucoseRange.classify(70), .inRange)
        XCTAssertEqual(GlucoseRange.classify(179), .inRange)
        XCTAssertEqual(GlucoseRange.classify(180), .high)
        XCTAssertEqual(GlucoseRange.classify(249), .high)
        XCTAssertEqual(GlucoseRange.classify(250), .urgentHigh)
    }

    func testTrendTokens() {
        XCTAssertEqual(GlucoseTrend.up.token, "up")
        XCTAssertEqual(GlucoseTrend.rising.token, "up45")
        XCTAssertEqual(GlucoseTrend.downDown.token, "downdown")
        // token(from:) maps a raw unicode arrow → the stable ASCII token remotes use.
        XCTAssertEqual(GlucoseTrend.token(from: "↑"), "up")
        XCTAssertEqual(GlucoseTrend.token(from: "→"), "flat")
        XCTAssertEqual(GlucoseTrend.token(from: "garbage"), "flat")   // unknown → flat
    }

    /// The neutral PumpAlertKind raw values MUST match the remote-protocol alert kinds
    /// (reminder 0 / alert 1 / alarm 2 / cgmAlert 3) so the RemoteCommand mapping is a passthrough.
    func testAlertKindRawValuesMatchRemoteProtocol() {
        XCTAssertEqual(PumpAlertKind.reminder.rawValue, 0)
        XCTAssertEqual(PumpAlertKind.alert.rawValue, 1)
        XCTAssertEqual(PumpAlertKind.alarm.rawValue, 2)
        XCTAssertEqual(PumpAlertKind.cgmAlert.rawValue, 3)
        let a = PumpAlert(id: 2, kind: .cgmAlert, title: "High glucose")
        let remote = RemoteCommand.RemoteAlert(id: a.id, kind: a.kind.rawValue, title: a.title)
        XCTAssertEqual(remote.kind, 3)
        XCTAssertEqual(PumpAlertKind(rawValue: remote.kind), .cgmAlert)
    }

    func testCapabilitiesFullDefaults() {
        let c = PumpCapabilities.full
        XCTAssertTrue(c.supportsCarbEntry && c.supportsBolusCancel && c.supportsAlertClear
                      && c.supportsHistoryBackfill && c.supportsPairing)
        let limited = PumpCapabilities(supportsCarbEntry: false)
        XCTAssertFalse(limited.supportsCarbEntry)
        XCTAssertTrue(limited.supportsBolusCancel)   // others default true
    }
}
