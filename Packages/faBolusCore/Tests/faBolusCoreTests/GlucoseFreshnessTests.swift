import XCTest
@testable import faBolusCore

final class GlucoseFreshnessTests: XCTestCase {
    func testIsStaleThreshold() {
        let now = Date()
        XCTAssertTrue(GlucoseFreshness.isStale(nil, now: now))                              // unknown → stale
        XCTAssertFalse(GlucoseFreshness.isStale(now.addingTimeInterval(-60), now: now))     // 1 min → fresh
        XCTAssertFalse(GlucoseFreshness.isStale(now.addingTimeInterval(-359), now: now))    // just under 6 min
        XCTAssertTrue(GlucoseFreshness.isStale(now.addingTimeInterval(-361), now: now))     // just over 6 min
    }

    func testThresholdIsConfigurable() {
        let now = Date()
        let original = GlucoseFreshness.staleAfter
        defer { GlucoseFreshness.staleAfter = original }
        GlucoseFreshness.staleAfter = 120
        XCTAssertTrue(GlucoseFreshness.isStale(now.addingTimeInterval(-130), now: now))
        XCTAssertFalse(GlucoseFreshness.isStale(now.addingTimeInterval(-110), now: now))
    }

    func testAgeLabel() {
        let now = Date()
        XCTAssertEqual(GlucoseFreshness.ageLabel(for: now, now: now), "now")
        XCTAssertEqual(GlucoseFreshness.ageLabel(for: now.addingTimeInterval(-180), now: now), "3 min ago")
        XCTAssertEqual(GlucoseFreshness.ageLabel(for: now.addingTimeInterval(-3600), now: now), "1h ago")
        XCTAssertEqual(GlucoseFreshness.ageLabel(for: now.addingTimeInterval(-3900), now: now), "1h 5m ago")
    }
}
