import XCTest
@testable import faBolusCore

/// D-05: the shared physiologic plausibility gate + the `GlucoseSample` failable init that enforces it.
/// REJECT posture (fail-closed) — an out-of-[40,400] value returns `nil`, it is NEVER clamped into
/// range (clamping is fail-open: it silently substitutes a dose input). Boundaries 40 and 400 are
/// accepted; 39 and 401 (and the classic garbage 900 / 20) are rejected.
final class GlucosePlausibilityTests: XCTestCase {

    // MARK: - GlucosePlausibility.isPlausible

    func testIsPlausibleAcceptsRangeInclusive() {
        XCTAssertTrue(GlucosePlausibility.isPlausible(mgdl: 40))
        XCTAssertTrue(GlucosePlausibility.isPlausible(mgdl: 400))
        XCTAssertTrue(GlucosePlausibility.isPlausible(mgdl: 120))
    }

    func testIsPlausibleRejectsOutsideRange() {
        XCTAssertFalse(GlucosePlausibility.isPlausible(mgdl: 39))
        XCTAssertFalse(GlucosePlausibility.isPlausible(mgdl: 401))
        XCTAssertFalse(GlucosePlausibility.isPlausible(mgdl: 900))
        XCTAssertFalse(GlucosePlausibility.isPlausible(mgdl: 20))
    }

    /// One source of truth for the range — matches the values vendored in G7SensorKit.GlucoseLimits /
    /// DexcomG6Kit.GlucoseLimits (do not invent a third value).
    func testSharedRangeMatchesVendoredLimits() {
        XCTAssertEqual(GlucosePlausibility.minimum, 40)
        XCTAssertEqual(GlucosePlausibility.maximum, 400)
    }

    // MARK: - GlucoseSample failable init — REJECT, not clamp

    func testSampleInitRejectsOutOfRangeAsNil() {
        XCTAssertNil(GlucoseSample(mgdl: 39, date: Date(), sourceID: "t"))
        XCTAssertNil(GlucoseSample(mgdl: 401, date: Date(), sourceID: "t"))
        XCTAssertNil(GlucoseSample(mgdl: 900, date: Date(), sourceID: "t"))
        XCTAssertNil(GlucoseSample(mgdl: 20, date: Date(), sourceID: "t"))
    }

    func testSampleInitAcceptsBoundaries() {
        XCTAssertNotNil(GlucoseSample(mgdl: 40, date: Date(), sourceID: "t"))
        XCTAssertNotNil(GlucoseSample(mgdl: 400, date: Date(), sourceID: "t"))
    }

    /// An in-range value preserves every memberwise field (no behavior change for plausible readings).
    func testSampleInitPreservesFieldsForInRangeValue() {
        let d = Date()
        let s = GlucoseSample(mgdl: 120, date: d, trend: .up, sourceID: "src")
        XCTAssertEqual(s?.mgdl, 120)
        XCTAssertEqual(s?.date, d)
        XCTAssertEqual(s?.trend, .up)
        XCTAssertEqual(s?.sourceID, "src")
    }
}
