import Testing
import Foundation
@testable import faBolusCore

/// RED-first (task 09.13-01/1): written before `GlucosePlotScale.allBandMarksWithinDomain` exists.
/// D-10 — the §13 band (70..180) and the four threshold marks (54/70/180/250) must stay within the
/// plotted domain for EVERY floor×ceiling preset combo (8 combos: floorOptions × ceilingOptions), and
/// the guard must NOT be vacuous — it must correctly reject a deliberately-too-narrow domain.
struct GlucosePlotBandIntegrityTests {

    @Test func allBandMarksWithinDomainIsTrueForEveryPresetCombo() {
        for f in GlucosePlotScale.floorOptions {
            for c in GlucosePlotScale.ceilingOptions {
                #expect(
                    GlucosePlotScale.allBandMarksWithinDomain(floor: f, ceiling: c),
                    "floor \(f) / ceiling \(c) should keep all §13 marks within-domain"
                )
            }
        }
    }

    @Test func allBandMarksWithinDomainIsFalseForATooNarrowDomain() {
        // floor 60 clips veryLow (54); ceiling 240 clips veryHigh (250) — deliberately invalid,
        // proving the guard is not vacuously true.
        #expect(GlucosePlotScale.allBandMarksWithinDomain(floor: 60, ceiling: 240) == false)
    }
}
