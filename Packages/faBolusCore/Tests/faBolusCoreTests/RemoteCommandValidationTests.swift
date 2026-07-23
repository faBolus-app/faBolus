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

    func testValidStatusReplyWithHistoryPasses() throws {
        var cmd = RemoteCommand(kind: .bolusStatus, requestId: "r1")
        cmd.history = Array(repeating: 100, count: 288)     // a day of 5-min points
        cmd.historyEpochs = Array(repeating: 1_700_000_000, count: 288)
        let back = try RemoteCommand.decodeValidated(try cmd.encoded())
        XCTAssertEqual(back.history?.count, 288)
    }
}
