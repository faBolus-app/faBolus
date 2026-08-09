import Testing
import Foundation
@testable import faBolusCore

/// P13c-1: the clinical glucose bands (70/180/250 + the very-low 54) are consolidated into one
/// source-cited `GlucoseThresholds`, and the two classifiers that read them (`GlucoseRange.classify`
/// display coloring, `GlucoseStatistics` TIR breakdown) now reference it instead of bare literals.
///
/// These pin two things: (1) the constants ARE the consensus values, and (2) both classifiers use the
/// same **closed clinical convention** (owner decision 2026-08-06): display coloring and the TIR
/// breakdown agree at every integer, including the exact boundaries 180 (in-range) and 250 (high).
struct GlucoseThresholdsTests {

    // MARK: - The constants are the Battelino 2019 consensus values

    @Test func constantsAreTheConsensusValues() {
        #expect(GlucoseThresholds.veryLow == 54)
        #expect(GlucoseThresholds.low == 70)
        #expect(GlucoseThresholds.high == 180)
        #expect(GlucoseThresholds.veryHigh == 250)
    }

    // MARK: - GlucoseRange (display): closed clinical convention, agreeing with the stats

    @Test func classifyUsesClosedClinicalBoundaries() {
        // Below 70 → low (all the way down; the display enum has no very-low case).
        #expect(GlucoseRange.classify(0) == .low)
        #expect(GlucoseRange.classify(53) == .low)
        #expect(GlucoseRange.classify(69) == .low)
        // 70…180 (closed) → in-range; exactly 180 is IN range, matching the TIR stat (owner 2026-08-06).
        #expect(GlucoseRange.classify(70) == .inRange)
        #expect(GlucoseRange.classify(179) == .inRange)
        #expect(GlucoseRange.classify(180) == .inRange)
        // 181…250 → high; exactly 250 is high (not urgent), matching the stat's >250 very-high edge.
        #expect(GlucoseRange.classify(181) == .high)
        #expect(GlucoseRange.classify(250) == .high)
        // > 250 → urgent.
        #expect(GlucoseRange.classify(251) == .urgentHigh)
        #expect(GlucoseRange.classify(400) == .urgentHigh)
    }

    @Test func bandIndexMapsLowToUrgentHighAsZeroToThree() {
        #expect(GlucoseRange.low.index == 0)
        #expect(GlucoseRange.inRange.index == 1)
        #expect(GlucoseRange.high.index == 2)
        #expect(GlucoseRange.urgentHigh.index == 3)
        // The index must track classify for every band (remotes/widgets rely on this 1:1).
        for g in [40, 54, 69, 70, 120, 180, 181, 250, 251, 300] {
            #expect(GlucoseRange.classify(g).index == expectedClosedIndex(g))
        }
    }

    private func expectedClosedIndex(_ g: Int) -> Int {
        switch g { case ..<70: return 0; case 70...180: return 1; case 181...250: return 2; default: return 3 }
    }

    // MARK: - GlucoseStatistics (clinical): closed convention preserved

    /// The stats TIR uses the CLOSED convention (70…180 inclusive, >250 very-high). This is the one
    /// place the boundary differs from display, and it must stay consensus-correct: exactly-180 counts
    /// as in-range (not high), exactly-250 as high (not very-high). A single reading at each boundary
    /// lands in exactly one bucket at 100%.
    @Test func statisticsUseClosedClinicalBoundaries() {
        func onlyBucket(_ mgdl: Int) -> String {
            let s = GlucoseStatistics(readings: [GlucoseReading(date: Date(), mgdl: mgdl)])
            var hits: [String] = []
            if s.veryLowPct == 100 { hits.append("veryLow") }
            if s.lowPct == 100 { hits.append("low") }
            if s.inRangePct == 100 { hits.append("inRange") }
            if s.highPct == 100 { hits.append("high") }
            if s.veryHighPct == 100 { hits.append("veryHigh") }
            return hits.count == 1 ? hits[0] : "AMBIGUOUS(\(hits))"
        }
        #expect(onlyBucket(53) == "veryLow")
        #expect(onlyBucket(54) == "low")
        #expect(onlyBucket(69) == "low")
        #expect(onlyBucket(70) == "inRange")
        #expect(onlyBucket(180) == "inRange")   // closed upper bound — 180 is IN range for TIR
        #expect(onlyBucket(181) == "high")
        #expect(onlyBucket(250) == "high")       // 250 is high, not very-high
        #expect(onlyBucket(251) == "veryHigh")
    }

    // MARK: - F4 (A5): the non-color band redundancy channel

    /// Every band carries a distinct, non-empty label AND SF-symbol name, so the band can be conveyed
    /// without color (WCAG 1.4.1). A representative reading in each band classifies to the right label.
    @Test func everyBandHasADistinctNonColorLabelAndSymbol() {
        let bands: [GlucoseRange] = [.low, .inRange, .high, .urgentHigh]
        let labels = bands.map(\.shortLabel)
        let symbols = bands.map(\.symbolName)
        #expect(Set(labels).count == 4)            // all distinct
        #expect(Set(symbols).count == 4)
        #expect(labels.allSatisfy { !$0.isEmpty })
        #expect(symbols.allSatisfy { !$0.isEmpty })
        // The channel tracks classify, so a colorblind user reads the same band the color would show.
        #expect(GlucoseRange.classify(55).shortLabel == "Low")
        #expect(GlucoseRange.classify(120).shortLabel == "In range")
        #expect(GlucoseRange.classify(200).shortLabel == "High")
        #expect(GlucoseRange.classify(300).shortLabel == "Very high")
    }
}
