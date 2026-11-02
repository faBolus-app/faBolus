import XCTest
@testable import faBolusCore

/// Timestamp provenance. A remote once displayed a glucose value labelled ~1 minute old that was in fact
/// hours stale, while the phone correctly showed no data.
///
/// The rule these tests pin: **a glucose sample carries an immutable source timestamp, and a sample
/// whose age is unknown is stale — never fresh.** No layer may stamp, default, or infer one.
final class GlucoseProvenanceTests: XCTestCase {

    // MARK: Unknown age must mean stale

    /// The invariant every surface has to honour. iOS already did; the Garmin watch did the opposite,
    /// which is what made A1 dosable. A reading's time can't be missing any more, so the unknown age is
    /// a time that can't be trusted.
    func testStateWithAValueButAnUntrustworthyTimeIsStale() {
        var s = PumpState()
        let now = Date()
        s.glucose = Observed(
            PumpGlucose(mgdl: 120, trend: nil), measuredAt: now.addingTimeInterval(3600), receivedAt: now)
        XCTAssertTrue(
            s.isGlucoseStale(thresholds: .standard, now: now), "a value with an unknown age must never read as fresh")
        XCTAssertNil(s.glucoseIfFresh(thresholds: .standard, now: now))
    }

    func testStateWithNoValueIsNotReportedStale() {
        let s = PumpState()
        XCTAssertFalse(s.isGlucoseStale(thresholds: .standard), "no reading at all is 'no data', not 'stale'")
        XCTAssertNil(s.glucoseIfFresh(thresholds: .standard))
    }

    func testFreshAndOldTimestampsClassifyCorrectly() {
        var s = PumpState()
        let now = Date()
        s.glucose = Observed(PumpGlucose(mgdl: 120, trend: nil), measuredAt: now, receivedAt: now)
        XCTAssertFalse(s.isGlucoseStale(thresholds: .standard, now: now))
        let old = now.addingTimeInterval(-7 * 60)
        s.glucose = Observed(PumpGlucose(mgdl: 120, trend: nil), measuredAt: old, receivedAt: old)
        XCTAssertTrue(s.isGlucoseStale(thresholds: .standard, now: now))
    }
}
