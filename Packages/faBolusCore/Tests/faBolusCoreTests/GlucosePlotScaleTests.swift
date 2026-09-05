import Testing
import Foundation
@testable import faBolusCore

/// Covers `GlucosePlotScale`'s defaults (always floor<ceiling), its discrete preset sets, the
/// symmetric clamp, the scaleUnits/recoverUnits round trip, and boundLabel().
struct GlucosePlotScaleTests {

    // MARK: - Option sets + defaults

    @Test func optionSetsAndDefaultsMatchD01D02() {
        #expect(GlucosePlotScale.floorOptions == [40, 50])
        #expect(GlucosePlotScale.ceilingOptions == [250, 300, 350, 400])
        #expect(GlucosePlotScale.defaultFloor == 40)
        #expect(GlucosePlotScale.defaultCeiling == 300)
    }

    // MARK: - resolve()

    @Test func resolveDefaultsWhenStoredValuesAreAbsent() {
        let r = GlucosePlotScale.resolve(storedFloor: nil, storedCeiling: nil)
        #expect(r.floor == 40)
        #expect(r.ceiling == 300)
    }

    @Test func resolveSnapsOutOfSetValuesToNearestOption() {
        // Legacy/corrupt stored ceiling 320 should snap to the nearest option (300 or 350).
        let r = GlucosePlotScale.resolve(storedFloor: 45, storedCeiling: 320)
        #expect(GlucosePlotScale.floorOptions.contains(r.floor))
        #expect(GlucosePlotScale.ceilingOptions.contains(r.ceiling))
        #expect(r.floor < r.ceiling)
    }

    @Test func resolveAlwaysReturnsFloorLessThanCeiling() {
        for f in GlucosePlotScale.floorOptions {
            for c in GlucosePlotScale.ceilingOptions {
                let r = GlucosePlotScale.resolve(storedFloor: f, storedCeiling: c)
                #expect(r.floor < r.ceiling)
                #expect(GlucosePlotScale.floorOptions.contains(r.floor))
                #expect(GlucosePlotScale.ceilingOptions.contains(r.ceiling))
            }
        }
    }

    // MARK: - clamp() — symmetric

    @Test func clampPinsAboveCeilingToCeiling() {
        #expect(GlucosePlotScale.clamp(400, floor: 40, ceiling: 300) == 300)
    }

    @Test func clampPinsBelowFloorToFloor() {
        #expect(GlucosePlotScale.clamp(30, floor: 40, ceiling: 300) == 40)
    }

    @Test func clampLeavesInRangeValueUnchanged() {
        #expect(GlucosePlotScale.clamp(120, floor: 40, ceiling: 300) == 120)
    }

    // MARK: - scaleUnits / recoverUnits round trip

    @Test func scaleUnitsMapsZeroAndUnitMaxToFloorAndCeiling() {
        #expect(GlucosePlotScale.scaleUnits(0, unitMax: 10, floor: 40, ceiling: 300) == 40)
        #expect(GlucosePlotScale.scaleUnits(10, unitMax: 10, floor: 40, ceiling: 300) == 300)
    }

    @Test func recoverUnitsIsExactInverseOfScaleUnitsAcrossCombos() {
        let combos: [(Int, Int)] = [(40, 300), (50, 250), (40, 400)]
        let unitMax = 10.0
        for (f, c) in combos {
            for u in stride(from: 0.0, through: unitMax, by: 2.5) {
                let scaled = GlucosePlotScale.scaleUnits(u, unitMax: unitMax, floor: f, ceiling: c)
                let recovered = GlucosePlotScale.recoverUnits(scaled, unitMax: unitMax, floor: f, ceiling: c)
                #expect(abs(recovered - u) < 1e-6)
            }
        }
    }

    // MARK: - boundLabel() — mg/dL integer

    @Test func boundLabelMgdlIsPlainInteger() {
        #expect(GlucosePlotScale.boundLabel(300, unit: .mgdl) == "300")
        #expect(GlucosePlotScale.boundLabel(40, unit: .mgdl) == "40")
    }
}
