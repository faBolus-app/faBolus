import XCTest
@testable import G7SensorKit

final class G7GlucoseMessageTests: XCTestCase {
    /// Known real-time glucose message from the G7SensorKit decoder docs.
    /// 4e 00 d5070000 0900 00 01 0500 6100 06 01 ffff 0e
    func testDecodesGlucoseMessage() throws {
        let data = Data([0x4e, 0x00, 0xd5, 0x07, 0x00, 0x00, 0x09, 0x00, 0x00, 0x01,
                         0x05, 0x00, 0x61, 0x00, 0x06, 0x01, 0xff, 0xff, 0x0e])
        XCTAssertTrue(data.starts(with: .glucoseTx))
        let msg = try XCTUnwrap(G7GlucoseMessage(data: data))
        XCTAssertEqual(msg.glucose, 97)
        XCTAssertEqual(msg.messageTimestamp, 2005)
        XCTAssertEqual(msg.age, 5)
        XCTAssertEqual(msg.glucoseTimestamp, 2000)        // messageTimestamp - age
        XCTAssertEqual(msg.trend ?? 0, 0.1, accuracy: 0.0001)  // 0x01 / 10
        XCTAssertEqual(msg.trendDirection, .flat)         // |rate| < 1.0
        XCTAssertTrue(msg.hasReliableGlucose)             // state 0x06 == .ok
        XCTAssertFalse(msg.glucoseIsDisplayOnly)
    }

    /// Known backfill message (9 bytes): 45a100 00 9600 06 0f fc
    func testDecodesBackfillMessage() throws {
        let data = Data([0x45, 0xa1, 0x00, 0x00, 0x96, 0x00, 0x06, 0x0f, 0xfc])
        let msg = try XCTUnwrap(G7BackfillMessage(data: data))
        XCTAssertEqual(msg.glucose, 150)                  // 0x0096
        XCTAssertEqual(msg.timestamp, 41285)              // 0x00a145
        XCTAssertTrue(msg.hasReliableGlucose)             // 0x06 == .ok
        XCTAssertEqual(msg.trend ?? 0, -0.4, accuracy: 0.0001) // 0xfc = -4 → -0.4
        XCTAssertEqual(msg.trendDirection, .flat)         // |rate| < 1.0
    }

    // MARK: - D-03 decode-time physiologic-range gate (hasPlausibleGlucose, REJECT posture)

    /// Real-time glucose frame (opcode 0x4e) with an arbitrary in-band glucose + algorithm state.
    private func glucoseFrame(glucose: UInt16, state: UInt8 = 0x06) -> Data {
        var d = [UInt8](repeating: 0, count: 19)
        d[0] = 0x4e; d[1] = 0x00
        d[2] = 0xd5; d[3] = 0x07                  // messageTimestamp = 2005 (arbitrary)
        d[9] = 0x01
        d[10] = 0x05                              // age = 5
        let gl = withUnsafeBytes(of: glucose.littleEndian) { Array($0) }
        d[12] = gl[0]; d[13] = gl[1]
        d[14] = state
        d[15] = 0x01                              // trend 0.1
        d[16] = 0xff; d[17] = 0xff                // predicted nil
        d[18] = 0x00
        return Data(d)
    }

    /// Backfill frame (9 bytes) with an arbitrary in-band glucose + algorithm state.
    private func backfillFrame(glucose: UInt16, state: UInt8 = 0x06) -> Data {
        var d = [UInt8](repeating: 0, count: 9)
        d[0] = 0x45; d[1] = 0xa1; d[2] = 0x00     // timestamp (arbitrary)
        let gl = withUnsafeBytes(of: glucose.littleEndian) { Array($0) }
        d[4] = gl[0]; d[5] = gl[1]
        d[6] = state
        d[7] = 0x00
        d[8] = 0xfc                               // trend
        return Data(d)
    }

    /// The gate finally consumes the vendored GlucoseLimits (40/400): boundaries accepted, out-of-range
    /// (500 / 20) rejected — REJECT posture, mirroring DexcomG6Kit.GlucoseRxMessage.hasPlausibleGlucose.
    func testGlucoseMessageHasPlausibleGlucoseRangeCeiling() throws {
        XCTAssertEqual(G7GlucoseMessage(data: glucoseFrame(glucose: 40))?.hasPlausibleGlucose, true)
        XCTAssertEqual(G7GlucoseMessage(data: glucoseFrame(glucose: 400))?.hasPlausibleGlucose, true)
        XCTAssertEqual(G7GlucoseMessage(data: glucoseFrame(glucose: 120))?.hasPlausibleGlucose, true)
        XCTAssertEqual(G7GlucoseMessage(data: glucoseFrame(glucose: 500))?.hasPlausibleGlucose, false)
        XCTAssertEqual(G7GlucoseMessage(data: glucoseFrame(glucose: 20))?.hasPlausibleGlucose, false)
    }

    /// hasPlausibleGlucose also requires reliability — an in-range but non-.ok frame is unusable.
    func testGlucoseMessageHasPlausibleGlucoseFalseWhenUnreliable() throws {
        XCTAssertEqual(G7GlucoseMessage(data: glucoseFrame(glucose: 120, state: 0x02))?.hasPlausibleGlucose, false)
    }

    func testBackfillMessageHasPlausibleGlucoseRangeCeiling() throws {
        XCTAssertEqual(G7BackfillMessage(data: backfillFrame(glucose: 40))?.hasPlausibleGlucose, true)
        XCTAssertEqual(G7BackfillMessage(data: backfillFrame(glucose: 400))?.hasPlausibleGlucose, true)
        XCTAssertEqual(G7BackfillMessage(data: backfillFrame(glucose: 500))?.hasPlausibleGlucose, false)
        XCTAssertEqual(G7BackfillMessage(data: backfillFrame(glucose: 20))?.hasPlausibleGlucose, false)
    }

    func testBackfillMessageHasPlausibleGlucoseFalseWhenUnreliable() throws {
        XCTAssertEqual(G7BackfillMessage(data: backfillFrame(glucose: 120, state: 0x02))?.hasPlausibleGlucose, false)
    }
}
