import XCTest
@testable import faBolusCore

final class CgmTrendTests: XCTestCase {
    func testNightscoutDirections() {
        XCTAssertEqual(CgmTrend.nightscout("DoubleUp"), .upUp)
        XCTAssertEqual(CgmTrend.nightscout("SingleUp"), .up)
        XCTAssertEqual(CgmTrend.nightscout("FortyFiveUp"), .rising)
        XCTAssertEqual(CgmTrend.nightscout("Flat"), .flat)  // explicit steady → flat (reported)
        XCTAssertEqual(CgmTrend.nightscout("FortyFiveDown"), .falling)
        XCTAssertEqual(CgmTrend.nightscout("SingleDown"), .down)
        XCTAssertEqual(CgmTrend.nightscout("DoubleDown"), .downDown)
        // C8: no trend reported → nil (renders as NO arrow), never a synthesized flat.
        XCTAssertNil(CgmTrend.nightscout(nil))
        XCTAssertNil(CgmTrend.nightscout("NONE"))
        XCTAssertNil(CgmTrend.nightscout("NOT COMPUTABLE"))
    }

    func testDexcomNumericAndString() {
        XCTAssertEqual(CgmTrend.dexcom(1), .upUp)
        XCTAssertEqual(CgmTrend.dexcom(4), .flat)  // 4 Flat → flat (reported steady)
        XCTAssertEqual(CgmTrend.dexcom(7), .downDown)
        XCTAssertEqual(CgmTrend.dexcom(name: "FortyFiveDown"), .falling)
        XCTAssertEqual(CgmTrend.dexcom(name: "singleup"), .up)
        XCTAssertEqual(CgmTrend.dexcom(name: "flat"), .flat)
        // C8: 0 None / 8 NotComputable / 9 RateOutOfRange / unknown → nil (no arrow).
        XCTAssertNil(CgmTrend.dexcom(0))
        XCTAssertNil(CgmTrend.dexcom(8))
        XCTAssertNil(CgmTrend.dexcom(9))
        XCTAssertNil(CgmTrend.dexcom(name: "none"))
    }

    func testLibreTrendArrow() {
        XCTAssertEqual(CgmTrend.libre(1), .down)
        XCTAssertEqual(CgmTrend.libre(3), .flat)  // 3 Flat → flat (reported steady)
        XCTAssertEqual(CgmTrend.libre(5), .up)
        // C8: absent / unknown arrow → nil (no arrow).
        XCTAssertNil(CgmTrend.libre(0))
    }

    func testDotNetDate() {
        XCTAssertEqual(CgmTrend.dotNetDate("/Date(1620000000000)/")?.timeIntervalSince1970, 1_620_000_000)
        // With a trailing timezone offset the epoch part is still used.
        XCTAssertEqual(CgmTrend.dotNetDate("/Date(1620000000000-0800)/")?.timeIntervalSince1970, 1_620_000_000)
        XCTAssertNil(CgmTrend.dotNetDate("not a date"))
    }
}
