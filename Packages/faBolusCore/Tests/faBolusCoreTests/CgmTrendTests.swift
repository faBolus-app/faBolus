import Testing
import XCTest
@testable import faBolusCore

final class CgmTrendTests: XCTestCase {
    func testDexcomNumericAndString() {
        XCTAssertEqual(CgmTrend.dexcom(1), .upUp)
        XCTAssertEqual(CgmTrend.dexcom(4), .flat)  // 4 Flat → flat (reported steady)
        XCTAssertEqual(CgmTrend.dexcom(7), .downDown)
        // C8: 0 None / 8 NotComputable / 9 RateOutOfRange / unknown → nil (no arrow).
        XCTAssertNil(CgmTrend.dexcom(0))
        XCTAssertNil(CgmTrend.dexcom(8))
        XCTAssertNil(CgmTrend.dexcom(9))
    }
}

@Suite("Dexcom rate to arrow")
struct CgmTrendRateTests {
    @Test("the Bluetooth rate maps to the same arrow Share would report")
    func rateBuckets() {
        let cases: [(Double?, GlucoseTrend?)] = [
            (-3.5, .downDown), (-3, .downDown), (-2.9, .down), (-2, .down), (-1.5, .falling), (-1, .falling),
            (-0.9, .flat), (0, .flat), (0.9, .flat), (1, .rising), (1.9, .rising), (2, .up), (2.9, .up), (3, .upUp),
            (nil, nil), (.nan, nil)
        ]
        for (rate, arrow) in cases { #expect(CgmTrend.dexcom(rate: rate) == arrow, "rate \(String(describing: rate))") }
    }
}
