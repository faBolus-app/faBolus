import Testing
import Foundation
@testable import faBolusCore

/// RED-first (task 09.18b-01/1, the phase TRACER): written before `GraphDetailReadout` exists, so this
/// fails to compile/build until the pure resolver + its math land. Covers the scrub x→Date→nearest-sample
/// domain math (D-05/D-06):
///   - the generic `nearest(to:in:key:within:)` over any `[T]` keyed by a `Date` KeyPath + a tolerance,
///   - empty input, within/beyond tolerance, strictly-closest across both sides, and the deterministic
///     tie rule (earlier sample wins),
///   - the SAME generic shape resolving `GlucoseReading` / `IOBSample` / `BolusMarker` (so 09.18b-02's
///     rows reuse it without a second implementation).
///
/// Mirrors `GlucosePlotScaleTests`' Swift-Testing `#expect` idiom and its display-only discipline:
/// `GraphDetailReadout` imports Foundation only and references no dose/delivery/signed-path type.
struct GraphDetailReadoutTests {

    // A fixed reference instant so every case is deterministic regardless of wall-clock time.
    private let t0 = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - Empty input

    @Test func nearestReturnsNilForEmptyArray() {
        let empty: [GlucoseReading] = []
        #expect(GraphDetailReadout.nearest(to: t0, in: empty, key: \.date, within: 600) == nil)
    }

    // MARK: - Within / beyond tolerance

    @Test func nearestReturnsClosestSampleWhenWithinTolerance() {
        let readings = [
            GlucoseReading(date: t0.addingTimeInterval(-300), mgdl: 90),   // 5 min before
            GlucoseReading(date: t0.addingTimeInterval(-60), mgdl: 110),   // 1 min before  ← closest
            GlucoseReading(date: t0.addingTimeInterval(240), mgdl: 130),   // 4 min after
        ]
        let hit = GraphDetailReadout.nearest(to: t0, in: readings, key: \.date, within: 600)
        #expect(hit?.mgdl == 110)
    }

    @Test func nearestReturnsNilWhenClosestSampleIsBeyondTolerance() {
        let readings = [
            GlucoseReading(date: t0.addingTimeInterval(-900), mgdl: 90),   // 15 min before
            GlucoseReading(date: t0.addingTimeInterval(1200), mgdl: 130),  // 20 min after
        ]
        // Nearest is 15 min away; a 5-min tolerance rejects it → the row renders an em dash.
        #expect(GraphDetailReadout.nearest(to: t0, in: readings, key: \.date, within: 300) == nil)
    }

    @Test func nearestAcceptsSampleExactlyAtTolerance() {
        let readings = [GlucoseReading(date: t0.addingTimeInterval(300), mgdl: 120)]
        // Inclusive boundary: a sample exactly `tolerance` away is still a hit.
        #expect(GraphDetailReadout.nearest(to: t0, in: readings, key: \.date, within: 300)?.mgdl == 120)
    }

    // MARK: - Strictly-closest across both sides

    @Test func nearestReturnsStrictlyClosestWhenSamplesOnBothSides() {
        let readings = [
            GlucoseReading(date: t0.addingTimeInterval(-120), mgdl: 100),  // 2 min before
            GlucoseReading(date: t0.addingTimeInterval(90), mgdl: 140),    // 1.5 min after ← closest
        ]
        #expect(GraphDetailReadout.nearest(to: t0, in: readings, key: \.date, within: 600)?.mgdl == 140)
    }

    // MARK: - Deterministic tie rule (earlier sample wins)

    @Test func nearestBreaksTieByPickingTheEarlierSample() {
        // Two samples equidistant (±60s) from t0 → the earlier one (t0-60) is the documented, stable pick.
        let readings = [
            GlucoseReading(date: t0.addingTimeInterval(60), mgdl: 200),    // 1 min after
            GlucoseReading(date: t0.addingTimeInterval(-60), mgdl: 80),    // 1 min before ← wins on tie
        ]
        #expect(GraphDetailReadout.nearest(to: t0, in: readings, key: \.date, within: 600)?.mgdl == 80)
    }

    // MARK: - Same generic shape resolves IOB and bolus (reused by 09.18b-02)

    @Test func nearestResolvesIOBSampleByDate() {
        let iob = [
            IOBSample(date: t0.addingTimeInterval(-400), iob: 3.2),
            IOBSample(date: t0.addingTimeInterval(-30), iob: 1.1),         // ← closest
        ]
        #expect(GraphDetailReadout.nearest(to: t0, in: iob, key: \.date, within: 600)?.iob == 1.1)
    }

    @Test func nearestResolvesBolusMarkerByDate() {
        let boluses = [
            BolusMarker(date: t0.addingTimeInterval(-200), units: 2.5),    // ← closest
            BolusMarker(date: t0.addingTimeInterval(-1800), units: 6.0),
        ]
        #expect(GraphDetailReadout.nearest(to: t0, in: boluses, key: \.date, within: 600)?.units == 2.5)
    }

    @Test func nearestRejectsBolusMarkerBeyondTolerance() {
        let boluses = [BolusMarker(date: t0.addingTimeInterval(-1800), units: 6.0)]  // 30 min before
        // No bolus within a 10-min tolerance → nil (row renders "—", never a fabricated number).
        #expect(GraphDetailReadout.nearest(to: t0, in: boluses, key: \.date, within: 600) == nil)
    }
}
