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
}
