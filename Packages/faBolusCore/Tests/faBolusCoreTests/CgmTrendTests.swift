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
