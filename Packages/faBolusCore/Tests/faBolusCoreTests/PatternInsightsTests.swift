import XCTest
@testable import faBolusCore

final class PatternInsightsTests: XCTestCase {
    // Fixed anchor (2023-11-14, no DST transition in the sampled window). Both the generator below and
    // the algorithm resolve hours with Calendar.current, so an injected "low hour" lines up regardless
    // of the machine's time zone.
    private let base = Date(timeIntervalSince1970: 1_700_000_000)
    private let cal = Calendar.current

    /// Synthesize CGM points every `stepMinutes` for `days`, all in-range (120 mg/dL) except that any
    /// reading whose local hour equals `lowHour` is a low (60 mg/dL) — seeding a recurring-low cluster.
    private func series(days: Double, stepMinutes: Double, lowHour: Int?) -> [PatternInsights.CGMPoint] {
        let total = Int((days * 24 * 60) / stepMinutes)
        return (0...total).map { i in
            let date = base.addingTimeInterval(Double(i) * stepMinutes * 60)
            let h = cal.component(.hour, from: date)
            let mgdl = (lowHour != nil && h == lowHour!) ? 60.0 : 120.0
            return .init(mgdl: mgdl, date: date)
        }
    }

    func testTirInsightAlwaysPresentAboveThreshold() {
        let cgm = series(days: 4, stepMinutes: 5, lowHour: nil)  // 1153 pts over 4 days
        XCTAssertGreaterThan(cgm.count, 100)
        let out = PatternInsights().insights(cgm: cgm)
        XCTAssertTrue(
            out.contains { $0.title.hasPrefix("Time in range:") },
            "the TIR insight is appended unconditionally once past the threshold")
    }

    func testRecurringLowClusterDetectedAtInjectedHour() {
        let cgm = series(days: 4, stepMinutes: 5, lowHour: 2)  // ~48 lows in local-hour 2 across 4 days
        let out = PatternInsights().insights(cgm: cgm)
        let low = out.first { $0.title.hasPrefix("Recurring lows") }
        XCTAssertNotNil(low, "a recurring-low cluster should be flagged for the injected low hour")
        XCTAssertTrue(low?.title.contains("2am") ?? false, "cluster should name the injected 2am hour")
        XCTAssertEqual(low?.severity, 2, "recurring-low is the highest (act) severity")
        // Highest-severity insight sorts first.
        XCTAssertEqual(out.first?.severity, 2)
    }

    func testTooFewDaysReturnsEmpty() {
        // Dense sampling (289 pts > 100) but only 1 day of span < minDays(3) → guard trips.
        let cgm = series(days: 1, stepMinutes: 5, lowHour: nil)
        XCTAssertGreaterThan(cgm.count, 100)
        XCTAssertTrue(PatternInsights().insights(cgm: cgm).isEmpty)
    }

    func testTooFewPointsReturnsEmpty() {
        // Full 4-day span but hourly sampling (~97 pts, not > 100) → guard trips.
        let cgm = series(days: 4, stepMinutes: 60, lowHour: nil)
        XCTAssertLessThanOrEqual(cgm.count, 100)
        XCTAssertTrue(PatternInsights().insights(cgm: cgm).isEmpty)
    }

    // MARK: - The unit param must be display-unit-correct AND leave the pre-existing default
    // (.mgdl) text byte-identical.

    func testDefaultUnitParamIsMgdlAndTextUnchanged() {
        // No `unit:` argument at all — confirms the default-parameter call-site compatibility
        // promise: the default `.mgdl` preserves call-site compatibility.
        let cgm = series(days: 4, stepMinutes: 5, lowHour: 2)
        let out = PatternInsights().insights(cgm: cgm)
        let low = out.first { $0.title.hasPrefix("Recurring lows") }
        XCTAssertTrue(
            low?.detail.contains("70 mg/dL") ?? false,
            "unconverted default must still render the bare mg/dL literal exactly as before")
    }

    func testMmolUnitConvertsRecurringLowDetail() {
        let cgm = series(days: 4, stepMinutes: 5, lowHour: 2)
        let out = PatternInsights().insights(cgm: cgm, unit: .mmol)
        let low = out.first { $0.title.hasPrefix("Recurring lows") }
        XCTAssertNotNil(low)
        XCTAssertFalse(low?.detail.contains("mg/dL") ?? true, "mmol mode must never leak an mg/dL label")
        XCTAssertTrue(low?.detail.contains("mmol/L") ?? false)
        // 70 mg/dL == 3.9 mmol/L at 1-decimal precision (GlucoseUnit.format).
        XCTAssertTrue(low?.detail.contains("3.9 mmol/L") ?? false, "70 mg/dL must render as 3.9 mmol/L via the funnel")
    }

    func testMmolUnitConvertsHighAndTirRangeDetail() {
        let cgm = series(days: 4, stepMinutes: 5, lowHour: nil)
        let out = PatternInsights().insights(cgm: cgm, unit: .mmol)
        let tir = out.first { $0.title.hasPrefix("Time in range:") }
        XCTAssertNotNil(tir)
        XCTAssertFalse(tir?.detail.contains("mg/dL") ?? true)
        // 70–180 mg/dL range == 3.9–10.0 mmol/L.
        XCTAssertTrue(tir?.detail.contains("3.9") ?? false)
        XCTAssertTrue(tir?.detail.contains("10.0") ?? false)
        XCTAssertTrue(tir?.detail.contains("mmol/L") ?? false)
    }
}
