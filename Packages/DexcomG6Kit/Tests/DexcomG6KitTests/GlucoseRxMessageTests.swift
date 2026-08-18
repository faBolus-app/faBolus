import XCTest
@testable import DexcomG6Kit

final class GlucoseRxMessageTests: XCTestCase {
    /// Build a valid 16-byte G6 glucose frame (opcode 0x4f) with a real CRC, then decode it.
    /// Layout: op(1) status(1) sequence(4) | sub: timestamp(4) glucose(2) state(1) trend(1) | crc(2)
    func testDecodesG6GlucoseMessage() throws {
        var body = Data()
        body.append(0x4f)                                              // glucoseG6Rx
        body.append(0x00)                                              // status
        body.append(contentsOf: [0x64, 0x00, 0x00, 0x00])             // sequence = 100
        body.append(contentsOf: [0x10, 0x0e, 0x00, 0x00])             // timestamp = 3600
        body.append(contentsOf: [0x78, 0x00])                         // glucose = 120 (0x0078)
        body.append(0x06)                                              // state = ok
        body.append(UInt8(bitPattern: 2))                             // trend = +2 → +0.2 mg/dL/min
        let frame = body.appendingCRC()
        XCTAssertEqual(frame.count, 16)
        XCTAssertTrue(frame.isCRCValid)
        XCTAssertTrue(frame.starts(with: .glucoseG6Rx))

        let msg = try XCTUnwrap(GlucoseRxMessage(data: frame))
        XCTAssertEqual(msg.glucoseMgdl, 120)
        XCTAssertEqual(msg.sequence, 100)
        XCTAssertEqual(msg.glucose.timestamp, 3600)
        XCTAssertFalse(msg.glucose.glucoseIsDisplayOnly)
        XCTAssertTrue(msg.hasReliableGlucose)                          // state 6 (ok) + glucose ≥ 39
        XCTAssertEqual(msg.trendRateMgDlPerMin ?? 0, 0.2, accuracy: 0.0001)
        XCTAssertEqual(msg.trendDirection, .flat)                     // |0.2| < 1.0
    }

    /// Slice-safety: `init?(data:)` is `public` and must decode a non-zero-based `Data` slice identically
    /// to the same bytes at index 0. Before the fix it indexed absolutely (`data[1]`, `data[2..<6]`,
    /// `data[6...]`) and this test would trap for `startIndex != 0`.
    func testDecodesFromNonZeroBasedSlice() throws {
        var body = Data()
        body.append(0x4f)
        body.append(0x00)
        body.append(contentsOf: [0x64, 0x00, 0x00, 0x00])             // sequence = 100
        body.append(contentsOf: [0x10, 0x0e, 0x00, 0x00])             // timestamp = 3600
        body.append(contentsOf: [0x78, 0x00])                         // glucose = 120
        body.append(0x06)                                             // state = ok
        body.append(UInt8(bitPattern: 2))                            // trend = +2
        let frame = body.appendingCRC()

        // Prepend 6 junk bytes, then take a slice whose startIndex is 6 (not 0).
        let prefixed = Data([0xde, 0xad, 0xbe, 0xef, 0x01, 0x02]) + frame
        let slice = prefixed[prefixed.index(prefixed.startIndex, offsetBy: 6)...]
        XCTAssertNotEqual(slice.startIndex, 0)                        // genuinely non-zero-based

        let msg = try XCTUnwrap(GlucoseRxMessage(data: slice))
        XCTAssertEqual(msg.glucoseMgdl, 120)
        XCTAssertEqual(msg.sequence, 100)
        XCTAssertEqual(msg.glucose.timestamp, 3600)
        XCTAssertTrue(msg.hasReliableGlucose)

        // Identical to decoding the same bytes at index 0.
        let zeroBased = try XCTUnwrap(GlucoseRxMessage(data: frame))
        XCTAssertEqual(msg, zeroBased)
    }

    func testRejectsBadCRC() {
        var frame = Data([0x4f, 0x00, 0x64, 0, 0, 0, 0x10, 0x0e, 0, 0, 0x78, 0, 0x06, 0x02, 0x00, 0x00])
        XCTAssertFalse(frame.isCRCValid)
        XCTAssertNil(GlucoseRxMessage(data: frame))
        frame[0] = 0x30   // not a glucose opcode
        XCTAssertNil(GlucoseRxMessage(data: frame))
    }

    func testWarmupIsNotReliable() throws {
        var body = Data([0x4f, 0x00, 0x01, 0, 0, 0, 0x10, 0x0e, 0, 0, 0x78, 0x00])
        body.append(0x02)                                             // state = warmup
        body.append(0x7f)                                             // trend unavailable
        let frame = body.appendingCRC()
        let msg = try XCTUnwrap(GlucoseRxMessage(data: frame))
        XCTAssertFalse(msg.hasReliableGlucose)                        // warmup
        XCTAssertNil(msg.trendRateMgDlPerMin)                         // 0x7f → unavailable
    }

    // MARK: - Task 2 (09.20-02, D-08b): physiologic-range gate — reject, never clamp (Task-1 sign-off).

    /// Builds a CRC-valid, calibration-ok (state = 0x06) G6 glucose frame carrying `glucose`.
    private func makeReliableFrame(glucose: UInt16) -> Data {
        var body = Data()
        body.append(0x4f)
        body.append(0x00)
        body.append(contentsOf: [0x01, 0, 0, 0])                     // sequence = 1
        body.append(contentsOf: [0x10, 0x0e, 0, 0])                  // timestamp = 3600
        body.append(contentsOf: withUnsafeBytes(of: glucose.littleEndian) { Array($0) })
        body.append(0x06)                                             // state = ok
        body.append(0x00)                                             // trend = 0
        return body.appendingCRC()
    }

    func testRejectsAboveMaximumRange() throws {
        let msg = try XCTUnwrap(GlucoseRxMessage(data: makeReliableFrame(glucose: 500)))
        XCTAssertTrue(msg.hasReliableGlucose, "500 passes the old >=39 floor alone")
        XCTAssertFalse(msg.hasPlausibleGlucose, "500 is above GlucoseLimits.maximum (400) — reject, don't clamp")
    }

    func testRejectsBelowMinimumRange() throws {
        let msg = try XCTUnwrap(GlucoseRxMessage(data: makeReliableFrame(glucose: 20)))
        XCTAssertFalse(msg.hasPlausibleGlucose, "20 is below both the old >=39 floor and GlucoseLimits.minimum")
    }

    func testAcceptsBoundaryMinimum() throws {
        let msg = try XCTUnwrap(GlucoseRxMessage(data: makeReliableFrame(glucose: 40)))
        XCTAssertTrue(msg.hasPlausibleGlucose, "40 == GlucoseLimits.minimum, inclusive boundary")
    }

    func testAcceptsBoundaryMaximum() throws {
        let msg = try XCTUnwrap(GlucoseRxMessage(data: makeReliableFrame(glucose: 400)))
        XCTAssertTrue(msg.hasPlausibleGlucose, "400 == GlucoseLimits.maximum, inclusive boundary")
    }

    func testRejectsJustBelowMinimumBoundary() throws {
        let msg = try XCTUnwrap(GlucoseRxMessage(data: makeReliableFrame(glucose: 39)))
        XCTAssertFalse(msg.hasPlausibleGlucose, "39 is one below GlucoseLimits.minimum (40) — the aligned floor")
    }

    func testRejectsJustAboveMaximumBoundary() throws {
        let msg = try XCTUnwrap(GlucoseRxMessage(data: makeReliableFrame(glucose: 401)))
        XCTAssertFalse(msg.hasPlausibleGlucose, "401 is one above GlucoseLimits.maximum (400)")
    }

    /// Bad CRC / wrong opcode must still decode to nil outright (unchanged, D-08b must not regress it).
    func testRangeGateDoesNotRegressBadCRCRejection() {
        var frame = Data([0x4f, 0x00, 0x01, 0, 0, 0, 0x10, 0x0e, 0, 0, 0x78, 0, 0x06, 0x00, 0x00, 0x00])
        XCTAssertFalse(frame.isCRCValid)
        XCTAssertNil(GlucoseRxMessage(data: frame))
        frame[0] = 0x30   // not a glucose opcode
        XCTAssertNil(GlucoseRxMessage(data: frame))
    }
}
