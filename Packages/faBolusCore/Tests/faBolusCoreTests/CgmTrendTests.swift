import XCTest
@testable import faBolusCore

final class CgmTrendTests: XCTestCase {
    func testNightscoutDirections() {
        XCTAssertEqual(CgmTrend.nightscout("DoubleUp"), .upUp)
        XCTAssertEqual(CgmTrend.nightscout("SingleUp"), .up)
        XCTAssertEqual(CgmTrend.nightscout("FortyFiveUp"), .rising)
        XCTAssertEqual(CgmTrend.nightscout("Flat"), .flat)
        XCTAssertEqual(CgmTrend.nightscout("FortyFiveDown"), .falling)
        XCTAssertEqual(CgmTrend.nightscout("SingleDown"), .down)
        XCTAssertEqual(CgmTrend.nightscout("DoubleDown"), .downDown)
        XCTAssertEqual(CgmTrend.nightscout(nil), .flat)          // unknown → flat
    }

    func testDexcomNumericAndString() {
        XCTAssertEqual(CgmTrend.dexcom(1), .upUp)
        XCTAssertEqual(CgmTrend.dexcom(4), .flat)
        XCTAssertEqual(CgmTrend.dexcom(7), .downDown)
        XCTAssertEqual(CgmTrend.dexcom(name: "FortyFiveDown"), .falling)
        XCTAssertEqual(CgmTrend.dexcom(name: "singleup"), .up)
    }

    func testLibreTrendArrow() {
        XCTAssertEqual(CgmTrend.libre(1), .down)
        XCTAssertEqual(CgmTrend.libre(3), .flat)
        XCTAssertEqual(CgmTrend.libre(5), .up)
    }

    func testDotNetDate() {
        XCTAssertEqual(CgmTrend.dotNetDate("/Date(1620000000000)/")?.timeIntervalSince1970, 1_620_000_000)
        // With a trailing timezone offset the epoch part is still used.
        XCTAssertEqual(CgmTrend.dotNetDate("/Date(1620000000000-0800)/")?.timeIntervalSince1970, 1_620_000_000)
        XCTAssertNil(CgmTrend.dotNetDate("not a date"))
    }
}
