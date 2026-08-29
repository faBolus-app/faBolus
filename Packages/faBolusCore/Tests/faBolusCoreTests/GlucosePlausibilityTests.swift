import XCTest
@testable import faBolusCore

/// The shared physiologic plausibility gate + the `GlucoseSample` failable init that enforces it.
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

    // MARK: - ageLabel explicit future/clock-mismatch label (never "now")

    /// A reading dated more than `futureSkewTolerance` in the future must render an EXPLICIT
    /// future/clock-mismatch label — NEVER "now" (the `age(of:)` `max(0,…)` clamp would otherwise
    /// collapse the negative elapsed time to 0, making `s < 30` true and mislabeling it "now"). A
    /// genuinely-fresh reading still labels "now"; a reading just inside the skew tolerance (ordinary
    /// phone/sensor clock jitter) still labels "now" too — only a reading BEYOND the tolerance is
    /// flagged.
    func testAgeLabelIsExplicitForFutureDatedReadingNeverNow() {
        let now = Date()
        XCTAssertEqual(GlucoseFreshness.ageLabel(for: now, now: now), "now")
        let justInsideSkew = now.addingTimeInterval(GlucoseFreshness.futureSkewTolerance - 1)
        XCTAssertEqual(GlucoseFreshness.ageLabel(for: justInsideSkew, now: now), "now")
        let wellBeyondSkew = now.addingTimeInterval(30 * 60)
        let label = GlucoseFreshness.ageLabel(for: wellBeyondSkew, now: now)
        XCTAssertNotEqual(label, "now")
        XCTAssertNotEqual(label, "just now")
        XCTAssertFalse(label.isEmpty)
    }

    // MARK: - Regression: the plausibility gate is BYTE-UNCHANGED by the sub-40 sentinel fix

    /// The sub-40 urgent-low sentinel (at the `PollingGlucoseSource` ingest boundary in
    /// the app target) must NOT relax this shared gate: an in-range value still constructs a
    /// `GlucoseSample`, and an above-400 value still returns nil — exactly as before.
    func testD05GateUnchangedByC205SentinelFix() {
        XCTAssertNotNil(GlucoseSample(mgdl: 120, date: Date(), sourceID: "t"))
        XCTAssertNil(GlucoseSample(mgdl: 401, date: Date(), sourceID: "t"))
        XCTAssertNil(GlucoseSample(mgdl: 39, date: Date(), sourceID: "t"))
    }
}
