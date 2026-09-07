import XCTest
@testable import faBolusCore

/// A-07: validated decoding rejects malformed/oversized/out-of-range commands before the backend clamp.
final class RemoteCommandValidationTests: XCTestCase {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    func testValidBolusRequestPasses() throws {
        var cmd = RemoteCommand(kind: .bolusRequest, carbsGrams: 30, bgMgdl: 120)
        cmd.remoteEstimateUnits = 3.0
        let back = try RemoteCommand.decodeValidated(try cmd.encoded())
        XCTAssertEqual(back.carbsGrams, 30)
    }

    func testWrongSchemaVersionRejected() {
        let json = #"{"version":2,"kind":"bolusRequest","requestId":"r1","units":2}"#
        XCTAssertThrowsError(try RemoteCommand.decodeValidated(data(json))) {
            XCTAssertEqual($0 as? RemoteCommand.ValidationError, .badVersion(2))
        }
    }

    func testEmptyRequestIdRejected() {
        let json = #"{"version":1,"kind":"bolusRequest","requestId":"","units":2}"#
        XCTAssertThrowsError(try RemoteCommand.decodeValidated(data(json))) {
            XCTAssertEqual($0 as? RemoteCommand.ValidationError, .badRequestId)
        }
    }

    func testNegativeUnitsRejected() {
        let json = #"{"version":1,"kind":"bolusRequest","requestId":"r1","units":-5}"#
        XCTAssertThrowsError(try RemoteCommand.decodeValidated(data(json))) {
            XCTAssertEqual($0 as? RemoteCommand.ValidationError, .outOfRange("units"))
        }
    }

    func testAbsurdlyLargeDoseRejected() {
        let json = #"{"version":1,"kind":"bolusRequest","requestId":"r1","units":100000}"#
        XCTAssertThrowsError(try RemoteCommand.decodeValidated(data(json))) {
            XCTAssertEqual($0 as? RemoteCommand.ValidationError, .outOfRange("units"))
        }
    }

    func testHugeExtendedDurationRejected() {
        let json = #"{"version":1,"kind":"bolusRequest","requestId":"r1","units":2,"extendedMinutes":9999999}"#
        XCTAssertThrowsError(try RemoteCommand.decodeValidated(data(json))) {
            XCTAssertEqual($0 as? RemoteCommand.ValidationError, .outOfRange("extendedMinutes"))
        }
    }

    func testOversizedRequestIdRejected() {
        let bigId = String(repeating: "x", count: 200)
        let json = #"{"version":1,"kind":"bolusRequest","requestId":"\#(bigId)","units":2}"#
        XCTAssertThrowsError(try RemoteCommand.decodeValidated(data(json)))
    }

    func testTooManyHistoryElementsRejected() {
        let arr = (0..<2000).map { _ in "100" }.joined(separator: ",")
        let json = #"{"version":1,"kind":"bolusStatus","requestId":"r1","history":[\#(arr)]}"#
        XCTAssertThrowsError(try RemoteCommand.decodeValidated(data(json))) {
            XCTAssertEqual($0 as? RemoteCommand.ValidationError, .tooManyElements("history"))
        }
    }

    func testOverByteCapRejected() {
        // A payload larger than maxEncodedBytes is rejected before decoding.
        let filler = String(repeating: "a", count: RemoteCommand.maxEncodedBytes + 100)
        let json = #"{"version":1,"kind":"bolusStatus","requestId":"r1","message":"\#(filler)"}"#
        XCTAssertThrowsError(try RemoteCommand.decodeValidated(data(json))) {
            if case .tooLarge = ($0 as? RemoteCommand.ValidationError) {} else { XCTFail("expected tooLarge") }
        }
    }

    // MARK: - Kind-specific cross-field rules

    func testZeroDurationExtendedRejected() {
        let json =
            #"{"version":1,"kind":"bolusRequest","requestId":"r1","units":2,"extendedMinutes":0,"extendedNowUnits":1}"#
        XCTAssertThrowsError(try RemoteCommand.decodeValidated(data(json))) {
            XCTAssertEqual($0 as? RemoteCommand.ValidationError, .crossField("extended bolus with zero duration"))
        }
    }

    func testExtendedNowExceedingTotalRejected() {
        let json =
            #"{"version":1,"kind":"bolusRequest","requestId":"r1","units":2,"extendedMinutes":120,"extendedNowUnits":3}"#
        XCTAssertThrowsError(try RemoteCommand.decodeValidated(data(json))) {
            if case .crossField = ($0 as? RemoteCommand.ValidationError) {} else { XCTFail("expected crossField") }
        }
    }

    func testAmbiguousUnitsAndCarbsRejected() {
        let json = #"{"version":1,"kind":"bolusRequest","requestId":"r1","units":2,"carbsGrams":30}"#
        XCTAssertThrowsError(try RemoteCommand.decodeValidated(data(json))) {
            if case .crossField = ($0 as? RemoteCommand.ValidationError) {} else { XCTFail("expected crossField") }
        }
    }

    func testWellFormedExtendedPasses() throws {
        let json =
            #"{"version":1,"kind":"bolusRequest","requestId":"r1","units":3,"extendedMinutes":120,"extendedNowUnits":1.5}"#
        let back = try RemoteCommand.decodeValidated(data(json))
        XCTAssertEqual(back.extendedMinutes, 120)
    }

    func testValidStatusReplyWithHistoryPasses() throws {
        var cmd = RemoteCommand(kind: .bolusStatus, requestId: "r1")
        cmd.history = Array(repeating: 100, count: 288)  // a day of 5-min points
        cmd.historyEpochs = Array(repeating: 1_700_000_000, count: 288)
        let back = try RemoteCommand.decodeValidated(try cmd.encoded())
        XCTAssertEqual(back.history?.count, 288)
    }

    // MARK: - Plot bound validation

    /// Absent is fine (⇒ receiver's own default/shared fallback); a present in-range pair passes.
    func testGlucosePlotBoundsAbsentOrInRangePasses() throws {
        var cmd = RemoteCommand(kind: .bolusStatus, requestId: "r1")
        let bare = try RemoteCommand.decodeValidated(try cmd.encoded())
        XCTAssertNil(bare.glucosePlotFloor)

        cmd.glucosePlotFloor = 40
        cmd.glucosePlotCeiling = 300
        cmd.glucosePlotFloorSmall = 50
        cmd.glucosePlotCeilingSmall = 400
        let back = try RemoteCommand.decodeValidated(try cmd.encoded())
        XCTAssertEqual(back.glucosePlotFloor, 40)
        XCTAssertEqual(back.glucosePlotCeilingSmall, 400)
    }

    /// A hostile/garbled out-of-range value on any of the four fields fails closed rather than driving
    /// an invalid remote axis.
    func testGlucosePlotBoundOutOfRangeRejected() {
        for field in ["glucosePlotFloor", "glucosePlotCeiling", "glucosePlotFloorSmall", "glucosePlotCeilingSmall"] {
            let json = #"{"version":1,"kind":"bolusStatus","requestId":"r1","\#(field)":5000}"#
            XCTAssertThrowsError(try RemoteCommand.decodeValidated(data(json)), field) {
                XCTAssertEqual($0 as? RemoteCommand.ValidationError, .outOfRange(field))
            }
        }
        let zeroJSON = #"{"version":1,"kind":"bolusStatus","requestId":"r1","glucosePlotFloor":0}"#
        XCTAssertThrowsError(try RemoteCommand.decodeValidated(data(zeroJSON))) {
            XCTAssertEqual($0 as? RemoteCommand.ValidationError, .outOfRange("glucosePlotFloor"))
        }
    }

    // MARK: - dismissAck cross-field rule
    //
    // A dismissAck reuses alertId/alertKind, so the JSON schema cannot require them — this Swift-only
    // rule is the only enforcement.

    func testDismissAckMissingBothAlertFieldsRejected() {
        let json = #"{"version":1,"kind":"dismissAck","requestId":"r1"}"#
        XCTAssertThrowsError(try RemoteCommand.decodeValidated(data(json))) {
            XCTAssertEqual($0 as? RemoteCommand.ValidationError, .crossField("dismissAck missing alertId/alertKind"))
        }
    }

    func testDismissAckMissingAlertKindRejected() {
        let json = #"{"version":1,"kind":"dismissAck","requestId":"r1","alertId":3}"#
        XCTAssertThrowsError(try RemoteCommand.decodeValidated(data(json))) {
            XCTAssertEqual($0 as? RemoteCommand.ValidationError, .crossField("dismissAck missing alertId/alertKind"))
        }
    }

    func testDismissAckMissingAlertIdRejected() {
        let json = #"{"version":1,"kind":"dismissAck","requestId":"r1","alertKind":1}"#
        XCTAssertThrowsError(try RemoteCommand.decodeValidated(data(json))) {
            XCTAssertEqual($0 as? RemoteCommand.ValidationError, .crossField("dismissAck missing alertId/alertKind"))
        }
    }

    func testWellFormedDismissAckWithBothFieldsPasses() throws {
        let json = #"{"version":1,"kind":"dismissAck","requestId":"r1","alertId":3,"alertKind":1}"#
        let back = try RemoteCommand.decodeValidated(data(json))
        XCTAssertEqual(back.alertId, 3)
        XCTAssertEqual(back.alertKind, 1)
    }

    // MARK: - App-own alert + watch-intent field caps (additive validation)
    //
    // The two watch-facing fields carrying untrusted per-item strings must fail closed on element count
    // and per-item string length like their length-validated siblings — previously they were bounded only
    // by the 32 KB envelope. Count caps are checked against validate() directly so the element bound (not
    // the byte cap) is the assertion under test.

    func testTooManyAppOwnAlertsRejected() {
        var cmd = RemoteCommand(kind: .bolusStatus, requestId: "r1")
        cmd.appOwnAlerts = (0...RemoteCommand.maxArrayCount).map {
            RemoteCommand.AppOwnAlert(key: "appOwn:c\($0)", title: "t")
        }
        XCTAssertThrowsError(try cmd.validate()) {
            XCTAssertEqual($0 as? RemoteCommand.ValidationError, .tooManyElements("appOwnAlerts"))
        }
    }

    func testTooManyWatchNotificationIntentsRejected() {
        var cmd = RemoteCommand(kind: .bolusStatus, requestId: "r1")
        var intents: [String: String] = [:]
        for i in 0...RemoteCommand.maxArrayCount { intents["k\(i)"] = "alert" }
        cmd.watchNotificationIntents = intents
        XCTAssertThrowsError(try cmd.validate()) {
            XCTAssertEqual($0 as? RemoteCommand.ValidationError, .tooManyElements("watchNotificationIntents"))
        }
    }

    func testOversizedAppOwnAlertKeyOrTitleRejected() {
        let big = String(repeating: "x", count: RemoteCommand.maxStringLength + 1)
        var keyCmd = RemoteCommand(kind: .bolusStatus, requestId: "r1")
        keyCmd.appOwnAlerts = [RemoteCommand.AppOwnAlert(key: big, title: "t")]
        XCTAssertThrowsError(try keyCmd.validate()) {
            XCTAssertEqual($0 as? RemoteCommand.ValidationError, .oversizedString("appOwnAlerts"))
        }
        var titleCmd = RemoteCommand(kind: .bolusStatus, requestId: "r1")
        titleCmd.appOwnAlerts = [RemoteCommand.AppOwnAlert(key: "appOwn:c", title: big)]
        XCTAssertThrowsError(try titleCmd.validate()) {
            XCTAssertEqual($0 as? RemoteCommand.ValidationError, .oversizedString("appOwnAlerts"))
        }
    }

    func testOversizedWatchNotificationIntentKeyOrValueRejected() {
        let big = String(repeating: "x", count: RemoteCommand.maxStringLength + 1)
        var valueCmd = RemoteCommand(kind: .bolusStatus, requestId: "r1")
        valueCmd.watchNotificationIntents = ["appOwn:c": big]
        XCTAssertThrowsError(try valueCmd.validate()) {
            XCTAssertEqual($0 as? RemoteCommand.ValidationError, .oversizedString("watchNotificationIntents"))
        }
        var keyCmd = RemoteCommand(kind: .bolusStatus, requestId: "r1")
        keyCmd.watchNotificationIntents = [big: "alert"]
        XCTAssertThrowsError(try keyCmd.validate()) {
            XCTAssertEqual($0 as? RemoteCommand.ValidationError, .oversizedString("watchNotificationIntents"))
        }
    }

    func testWithinCapsAppOwnAndWatchIntentFieldsValidate() throws {
        var cmd = RemoteCommand(kind: .bolusStatus, requestId: "r1")
        cmd.appOwnAlerts = [
            RemoteCommand.AppOwnAlert(key: "appOwn:bolusIndeterminate", title: "Bolus outcome unknown")
        ]
        cmd.watchNotificationIntents = ["appOwn:bolusIndeterminate": "alert", "pumpMirror:alarm:2": "alert"]
        let back = try RemoteCommand.decodeValidated(try cmd.encoded())
        XCTAssertEqual(back.appOwnAlerts?.count, 1)
        XCTAssertEqual(back.watchNotificationIntents?.count, 2)
    }

    /// Both fields absent still validates — the caps are additive and never require the fields.
    func testAppOwnAndWatchIntentFieldsAbsentValidate() throws {
        let cmd = RemoteCommand(kind: .bolusStatus, requestId: "r1")
        let back = try RemoteCommand.decodeValidated(try cmd.encoded())
        XCTAssertNil(back.appOwnAlerts)
        XCTAssertNil(back.watchNotificationIntents)
    }
}
