import XCTest
@testable import faBolusCore

final class GlucoseStatisticsTests: XCTestCase {
    private func readings(_ vals: [Int], startAgoHours: Double = 2) -> [GlucoseReading] {
        let base = Date(timeIntervalSince1970: 1_700_000_000)
        let step = (startAgoHours * 3600) / Double(max(1, vals.count - 1))
        return vals.enumerated().map { i, v in GlucoseReading(date: base.addingTimeInterval(Double(i) * step), mgdl: v) }
    }

    func testEmptyIsAllZeros() {
        let s = GlucoseStatistics(readings: [])
        XCTAssertEqual(s, .empty)
        XCTAssertEqual(s.count, 0)
    }

    func testMeanAndGmi() {
        let s = GlucoseStatistics(readings: readings([100, 100, 100, 100]))
        XCTAssertEqual(s.mean, 100, accuracy: 0.001)
        XCTAssertEqual(s.gmi, 3.31 + 0.02392 * 100, accuracy: 0.0001)  // 5.702%
        XCTAssertEqual(s.cv, 0, accuracy: 0.001)                        // no spread
    }

    func testTimeInRangeAndBands() {
        // 10 readings: one each very-low/very-high, two low, four in-range, two high.
        let s = GlucoseStatistics(readings: readings([40, 60, 60, 120, 120, 120, 120, 200, 200, 300]))
        XCTAssertEqual(s.veryLowPct, 10, accuracy: 0.001)   // 40
        XCTAssertEqual(s.lowPct, 20, accuracy: 0.001)       // 60, 60
        XCTAssertEqual(s.inRangePct, 40, accuracy: 0.001)   // 120 x4
        XCTAssertEqual(s.highPct, 20, accuracy: 0.001)      // 200 x2
        XCTAssertEqual(s.veryHighPct, 10, accuracy: 0.001)  // 300
        XCTAssertEqual(s.timeInRangePct, 40, accuracy: 0.001)
        // bands sum to 100
        XCTAssertEqual(s.veryLowPct + s.lowPct + s.inRangePct + s.highPct + s.veryHighPct, 100, accuracy: 0.001)
    }

    func testBoundariesInclusiveAt70And180() {
        let s = GlucoseStatistics(readings: readings([70, 180]))
        XCTAssertEqual(s.inRangePct, 100, accuracy: 0.001)  // both endpoints count as in-range
    }

    func testCvIsPositiveWithSpread() {
        let s = GlucoseStatistics(readings: readings([80, 120]))
        XCTAssertEqual(s.mean, 100, accuracy: 0.001)
        XCTAssertGreaterThan(s.cv, 0)
    }
}
