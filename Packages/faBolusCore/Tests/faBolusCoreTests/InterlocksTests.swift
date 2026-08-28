import Testing
@testable import faBolusCore

/// The 25 U max-bolus ceiling is a hard cap. clampMaxBolusLimit (and clampMaxBasalLimit) is the single
/// shared clamp every max-limit write must go through.
struct InterlocksTests {

    @Test func clampMaxBolusLimitEnforcesTheHardCap() {
        #expect(Interlocks.clampMaxBolusLimit(30) == 25.0)     // above the ceiling → capped
        #expect(Interlocks.clampMaxBolusLimit(1000) == 25.0)   // absurd → still capped, never a confirmation
        #expect(Interlocks.clampMaxBolusLimit(25) == 25.0)     // at the ceiling → unchanged
        #expect(Interlocks.clampMaxBolusLimit(10) == 10.0)     // mid-range → passes through
        // Floor matches TandemKit's SetMaxBolusLimitRequest throwing floor.
        #expect(Interlocks.clampMaxBolusLimit(0.5) == 1.0)     // below the new 1.0 U floor → floored
        #expect(Interlocks.clampMaxBolusLimit(-5) == 1.0)      // negative → floored, never ≤ 0
        #expect(Interlocks.clampMaxBolusLimit(1.0) == 1.0)     // at the floor → unchanged
    }

    @Test func theHardCapItselfIsUnchanged() {
        #expect(Interlocks.absoluteMaxUnits == 25.0)           // owner-locked; S10's TDD-relative confirms never touch this
        #expect(Interlocks.minMaxBolusLimitUnits == 1.0)       // matches TandemKit's throwing floor
        #expect(Interlocks.minMaxBasalLimitUnitsPerHour == 1.0)
        #expect(Interlocks.maxMaxBasalLimitUnitsPerHour == 15.0)   // kit's byte-verified ceiling
    }

    /// `setMaxBasal` clamps symmetrically with `setMaxBolus`. A value above the kit's 15.0 U/hr ceiling
    /// must clamp to 15.0 (and dispatch) rather than throw an unlocalized ValidationError.
    @Test func maxBasalLimitAcceptsAndClampsAboveCeiling() {
        #expect(Interlocks.clampMaxBasalLimit(20) == 15.0)     // above the ceiling → capped, not thrown
        #expect(Interlocks.clampMaxBasalLimit(1000) == 15.0)   // absurd → still capped
        #expect(Interlocks.clampMaxBasalLimit(15) == 15.0)     // at the ceiling → unchanged
        #expect(Interlocks.clampMaxBasalLimit(5) == 5.0)       // mid-range → passes through
        #expect(Interlocks.clampMaxBasalLimit(0.5) == 1.0)     // below the 1.0 U/hr floor → floored
        #expect(Interlocks.clampMaxBasalLimit(-5) == 1.0)      // negative → floored, never ≤ 0
        #expect(Interlocks.clampMaxBasalLimit(1.0) == 1.0)     // at the floor → unchanged
    }
}
