import XCTest
@testable import faBolusCore

/// The phone↔remote contract must round-trip losslessly (JSON Data and [String:Any]) so the Apple
/// Watch, Garmin, and host all agree. If a field is added to RemoteCommand, add it here too.
final class RemoteCommandTests: XCTestCase {

    func testVersionMatchesSchema() {
        XCTAssertEqual(RemoteCommand(kind: .statusRead).version, RemoteCommand.schemaVersion)
    }

    func testStatusReadRoundTripData() throws {
        let cmd = RemoteCommand(kind: .statusRead, units: 1.25,
                                bgMgdl: 142, message: "Connected", trend: "up45",
                                carbRatio: 10, isf: 40, targetBg: 110, maxBolusUnits: 25,
                                reservoirUnits: 142, batteryPercent: 80, lastBolusUnits: 2.0,
                                glucoseAgeSec: 120, history: [110, 120, 130],
                                alerts: [.init(id: 2, kind: 3, title: "High glucose")],
                                bolusMode: "carbs", bolusIncrement: 0.05, carbIncrement: 5,
                                screenOrder: ["glance", "alerts"], defaultScreen: "glance")
        let decoded = try RemoteCommand.decode(try cmd.encoded())
        XCTAssertEqual(decoded, cmd)
        XCTAssertEqual(decoded.history, [110, 120, 130])
        XCTAssertEqual(decoded.alerts?.first?.kind, 3)
        XCTAssertEqual(decoded.trend, "up45")
    }

    func testDictionaryRoundTrip() throws {
        // Transport for WatchConnectivity + Connect IQ is [String:Any].
        let cmd = RemoteCommand(kind: .bolusRequest, carbsGrams: 30, bgMgdl: 150)
        let back = try RemoteCommand.from(try cmd.asDictionary())
        XCTAssertEqual(back, cmd)
        XCTAssertEqual(back.kind, .bolusRequest)
        XCTAssertEqual(back.carbsGrams, 30)
    }

    func testBolusStatusEcho() throws {
        let cmd = RemoteCommand(kind: .bolusStatus, requestId: "abc",
                                status: .cancelled, deliveredUnits: 0.8, message: "Cancelled · 0.80 U")
        let decoded = try RemoteCommand.decode(try cmd.encoded())
        XCTAssertEqual(decoded.status, .cancelled)
        XCTAssertEqual(decoded.deliveredUnits, 0.8)
        XCTAssertEqual(decoded.requestId, "abc")
    }

    func testDismissAlertCommand() throws {
        let cmd = RemoteCommand(kind: .dismissAlert, alertId: 2, alertKind: 3)
        let decoded = try RemoteCommand.decode(try cmd.encoded())
        XCTAssertEqual(decoded.alertId, 2)
        XCTAssertEqual(decoded.alertKind, 3)
    }
}
