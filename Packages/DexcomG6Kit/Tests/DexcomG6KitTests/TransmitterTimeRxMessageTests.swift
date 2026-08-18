import XCTest
@testable import DexcomG6Kit

/// D-12b decode-oracle for `TransmitterTimeRxMessage` (opcode 0x25) — the sensor-time anchor D-08a
/// uses to convert a glucose frame's sensor-relative timestamp into a true wall date. Mirrors
/// `GlucoseRxMessageTests`' frame-builder style (`appendingCRC()`, slice-safety).
final class TransmitterTimeRxMessageTests: XCTestCase {
    /// Layout: op(1) status(1) currentTime(4) sessionStartTime(4) [2 reserved bytes to reach 16] crc(2)
    private func makeFrame(opcode: UInt8 = 0x25, status: UInt8 = 0x00,
                           currentTime: UInt32, sessionStartTime: UInt32) -> Data {
        var body = Data()
        body.append(opcode)
        body.append(status)
        body.append(contentsOf: withUnsafeBytes(of: currentTime.littleEndian) { Array($0) })
        body.append(contentsOf: withUnsafeBytes(of: sessionStartTime.littleEndian) { Array($0) })
        body.append(contentsOf: [0x00, 0x00, 0x00, 0x00])   // pad to 14 bytes so + 2-byte CRC = 16
        return body.appendingCRC()
    }

    func testDecodesValidFrame() throws {
        let frame = makeFrame(status: 0x01, currentTime: 7200, sessionStartTime: 3600)
        XCTAssertEqual(frame.count, 16)
        let msg = try XCTUnwrap(TransmitterTimeRxMessage(data: frame))
        XCTAssertEqual(msg.status, 0x01)
        XCTAssertEqual(msg.currentTime, 7200)
        XCTAssertEqual(msg.sessionStartTime, 3600)
    }

    func testRejectsBadCRC() {
        var frame = makeFrame(currentTime: 7200, sessionStartTime: 3600)
        frame[15] = frame[15] ^ 0xff   // corrupt the trailing CRC byte
        XCTAssertFalse(frame.isCRCValid)
        XCTAssertNil(TransmitterTimeRxMessage(data: frame))
    }

    func testRejectsWrongOpcode() {
        let frame = makeFrame(opcode: 0x31, currentTime: 7200, sessionStartTime: 3600)
        XCTAssertNil(TransmitterTimeRxMessage(data: frame))
    }

    func testHasValidSensorSessionFalseWhenNoActiveSession() throws {
        let frame = makeFrame(currentTime: 7200, sessionStartTime: UInt32.max)
        let msg = try XCTUnwrap(TransmitterTimeRxMessage(data: frame))
        XCTAssertFalse(msg.hasValidSensorSession)
    }

    func testHasValidSensorSessionTrueForNormalSession() throws {
        let frame = makeFrame(currentTime: 7200, sessionStartTime: 3600)
        let msg = try XCTUnwrap(TransmitterTimeRxMessage(data: frame))
        XCTAssertTrue(msg.hasValidSensorSession)
    }

    /// Slice-safety: decoding a non-zero-based `Data` slice must produce the identical result as the
    /// same bytes at index 0 (mirrors `GlucoseRxMessageTests.testDecodesFromNonZeroBasedSlice`).
    func testDecodesFromNonZeroBasedSlice() throws {
        let frame = makeFrame(currentTime: 7200, sessionStartTime: 3600)
        let prefixed = Data([0xde, 0xad, 0xbe, 0xef, 0x01, 0x02]) + frame
        let slice = prefixed[prefixed.index(prefixed.startIndex, offsetBy: 6)...]
        XCTAssertNotEqual(slice.startIndex, 0)

        let msg = try XCTUnwrap(TransmitterTimeRxMessage(data: slice))
        XCTAssertEqual(msg.currentTime, 7200)
        XCTAssertEqual(msg.sessionStartTime, 3600)

        let zeroBased = try XCTUnwrap(TransmitterTimeRxMessage(data: frame))
        XCTAssertEqual(msg, zeroBased)
    }
}
