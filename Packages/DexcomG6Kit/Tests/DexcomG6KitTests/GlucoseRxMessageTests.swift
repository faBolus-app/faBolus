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
}
