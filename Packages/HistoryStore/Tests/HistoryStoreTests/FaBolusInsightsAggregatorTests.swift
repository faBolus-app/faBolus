import XCTest
import faBolusCore
@testable import HistoryStore

/// 09.18d-01 (D-15) — the minimal faBolus insights aggregator over `GlucoseHistoryStore`, replacing
/// LoopKit's `DataAggregator` (651 lines) with a Foundation + faBolusCore re-implementation (NO
/// LoopKit, NO reference to a LoopKit-style aggregator). The tracer proves the glucose spine +
/// insufficient-history flag; carb/insulin averages + AGP-mapping coverage land in Task 2.
@MainActor
final class FaBolusInsightsAggregatorTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_700_000_000)

    private func makeStore() throws -> GlucoseHistoryStore { try GlucoseHistoryStore(inMemory: true) }

    /// The aggregator's glucose stats must EQUAL what `GlucoseStatistics(readings:)` produces over the
    /// same window — it maps, it does not recompute a second stat implementation (D-15 read_first).
    func testGlucoseSummaryMatchesGlucoseStatistics() throws {
        let store = try makeStore()
        // 8 in-range (120) + 2 low (50) over distinct 5-min slots inside a 3-day window.
        var readings: [GlucoseReading] = []
        for i in 0..<8 { readings.append(GlucoseReading(date: now.addingTimeInterval(Double(i) * 300 - 86400), mgdl: 120)) }
        for i in 8..<10 { readings.append(GlucoseReading(date: now.addingTimeInterval(Double(i) * 300 - 86400), mgdl: 50)) }
        store.ingestGlucose(readings, sourceID: "dexcomG7", priority: 100)

        let report = FaBolusInsightsAggregator(store: store).report(period: .days(3), now: now)
        let ref = GlucoseStatistics(readings: readings)

        XCTAssertTrue(report.hasSufficientHistory)
        XCTAssertEqual(report.glucose.readingCount, ref.count)
        XCTAssertEqual(report.glucose.average, ref.mean, accuracy: 0.001)
        XCTAssertEqual(report.glucose.timeInRangePct, ref.timeInRangePct, accuracy: 0.001)
        XCTAssertEqual(report.glucose.gmi, ref.gmi, accuracy: 0.001)
        // SD derives as cv*mean/100 (GlucoseStatistics stores cv, not sd).
        XCTAssertEqual(report.glucose.sd, ref.cv * ref.mean / 100, accuracy: 0.001)
    }

    /// An empty window must yield a DTO flagged insufficient (drives the "Not enough history yet"
    /// empty state) — never a crash and never a fabricated 0-based stat presented as real.
    func testEmptyWindowIsFlaggedInsufficient() throws {
        let store = try makeStore()
        let report = FaBolusInsightsAggregator(store: store).report(period: .days(14), now: now)
        XCTAssertFalse(report.hasSufficientHistory)
        XCTAssertEqual(report.glucose.readingCount, 0)
        XCTAssertEqual(report.glucose.average, 0, accuracy: 0.0001)
    }

    /// The report window matches the requested period (days back from `now`).
    func testReportWindowSpansRequestedDays() throws {
        let store = try makeStore()
        let report = FaBolusInsightsAggregator(store: store).report(period: .days(7), now: now)
        XCTAssertEqual(report.range.upperBound, now)
        XCTAssertEqual(report.range.lowerBound, now.addingTimeInterval(-7 * 86400))
    }

    // MARK: - Task 2: carb / insulin averages + AGP mapping

    /// Carb stats: daily-average == totalGrams / periodDays; per-meal-average == totalGrams / mealCount.
    func testCarbStatsDailyAndPerMealAverages() throws {
        let store = try makeStore()
        store.ingestCarbs([(date: now.addingTimeInterval(-1 * 86400), grams: 30),
                           (date: now.addingTimeInterval(-2 * 86400), grams: 40),
                           (date: now.addingTimeInterval(-3 * 86400), grams: 50)],
                          sourceID: "fabolus")   // total 120, N=3
        let report = FaBolusInsightsAggregator(store: store).report(period: .days(4), now: now)
        XCTAssertEqual(report.carbs.totalGrams, 120, accuracy: 0.001)
        XCTAssertEqual(report.carbs.mealCount, 3)
        XCTAssertEqual(report.carbs.dailyAverageGrams, 120.0 / 4.0, accuracy: 0.001)
        XCTAssertEqual(report.carbs.perMealAverageGrams, 120.0 / 3.0, accuracy: 0.001)
    }

    /// Zero carbs must not divide by zero — averages are 0.
    func testZeroCarbsNoDivideByZero() throws {
        let store = try makeStore()
        let report = FaBolusInsightsAggregator(store: store).report(period: .days(7), now: now)
        XCTAssertEqual(report.carbs.mealCount, 0)
        XCTAssertEqual(report.carbs.dailyAverageGrams, 0, accuracy: 0.0001)
        XCTAssertEqual(report.carbs.perMealAverageGrams, 0, accuracy: 0.0001)
    }

    /// Insulin stats: total == sum of boluses; daily-average TDD == total / periodDays.
    func testInsulinTotalsAndDailyAverage() throws {
        let store = try makeStore()
        store.ingestBoluses([BolusMarker(date: now.addingTimeInterval(-1 * 86400), units: 2.0),
                             BolusMarker(date: now.addingTimeInterval(-2 * 86400), units: 3.0),
                             BolusMarker(date: now.addingTimeInterval(-3 * 86400), units: 5.0)],
                            sourceID: "pump")   // total 10 over 5 days
        let report = FaBolusInsightsAggregator(store: store).report(period: .days(5), now: now)
        XCTAssertEqual(report.insulin.totalUnits, 10, accuracy: 0.001)
        XCTAssertEqual(report.insulin.dailyAverageUnits, 10.0 / 5.0, accuracy: 0.001)
    }

    /// The AGP breakdown maps straight from GlucoseStatistics and sums to ~100% within rounding.
    func testAGPBreakdownSumsToHundred() throws {
        let store = try makeStore()
        var readings: [GlucoseReading] = []
        let vals = [40, 60, 120, 200, 300, 120, 120, 65, 190, 130]  // spans every band
        for (i, v) in vals.enumerated() {
            readings.append(GlucoseReading(date: now.addingTimeInterval(Double(i) * 300 - 86400), mgdl: v))
        }
        store.ingestGlucose(readings, sourceID: "dexcomG7", priority: 100)
        let g = FaBolusInsightsAggregator(store: store).report(period: .days(3), now: now).glucose
        let sum = g.veryLowPct + g.lowPct + g.inRangePct + g.highPct + g.veryHighPct
        XCTAssertEqual(sum, 100, accuracy: 0.5)
    }
}
