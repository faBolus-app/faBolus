import Testing
import Foundation
@testable import faBolusCore

/// RED-first (task 09.13-01/1): written before `GlucosePlotScale` exists, so this fails to
/// compile/build until the type + its math land. Covers D-01 (defaults + floor<ceiling),
/// D-02 (discrete preset sets), D-08 (symmetric clamp), D-09 (scaleUnits/recoverUnits round trip),
/// and the mmol boundLabel (Phase-4 D-08 clinical-rounding precedent).
struct GlucosePlotScaleTests {

    // MARK: - Option sets + defaults (D-01, D-02)

    @Test func optionSetsAndDefaultsMatchD01D02() {
        #expect(GlucosePlotScale.floorOptions == [40, 50])
        #expect(GlucosePlotScale.ceilingOptions == [250, 300, 350, 400])
        #expect(GlucosePlotScale.defaultFloor == 40)
        #expect(GlucosePlotScale.defaultCeiling == 300)
    }

    // MARK: - resolve() (D-01/D-02/D-10)

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

    // MARK: - clamp() — symmetric, D-08

    @Test func clampPinsAboveCeilingToCeiling() {
        #expect(GlucosePlotScale.clamp(400, floor: 40, ceiling: 300) == 300)
    }

    @Test func clampPinsBelowFloorToFloor() {
        #expect(GlucosePlotScale.clamp(30, floor: 40, ceiling: 300) == 40)
    }

    @Test func clampLeavesInRangeValueUnchanged() {
        #expect(GlucosePlotScale.clamp(120, floor: 40, ceiling: 300) == 120)
    }

    // MARK: - scaleUnits / recoverUnits round trip (D-09)

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

    // MARK: - boundLabel() — mg/dL integer, mmol clinical rounding (D-02)

    @Test func boundLabelMgdlIsPlainInteger() {
        #expect(GlucosePlotScale.boundLabel(300, unit: .mgdl) == "300")
        #expect(GlucosePlotScale.boundLabel(40, unit: .mgdl) == "40")
    }

    @Test func boundLabelMmolIsOneDecimalClinicallyRounded() {
        // Mirrors GlucoseUnit.format's 1-decimal mmol convention.
        #expect(GlucosePlotScale.boundLabel(300, unit: .mmol) == GlucoseUnit.mmol.format(mgdl: 300))
        #expect(GlucosePlotScale.boundLabel(40, unit: .mmol) == GlucoseUnit.mmol.format(mgdl: 40))
    }
}
