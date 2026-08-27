import Testing
@testable import faBolusCore

/// P14 S9. The absolute 25 U max-bolus ceiling is a HARD cap (owner-locked, §2.1(5): never a
/// confirmation). `Interlocks.clampMaxBolusLimit` is the single shared definition the funnel and every
/// backend route a max-bolus-LIMIT write through, so the invariant no longer depends on the active backend.
struct InterlocksTests {

    @Test func clampMaxBolusLimitEnforcesTheHardCap() {
        #expect(Interlocks.clampMaxBolusLimit(30) == 25.0)     // above the ceiling → capped
        #expect(Interlocks.clampMaxBolusLimit(1000) == 25.0)   // absurd → still capped, never a confirmation
        #expect(Interlocks.clampMaxBolusLimit(25) == 25.0)     // at the ceiling → unchanged
        #expect(Interlocks.clampMaxBolusLimit(10) == 10.0)     // mid-range → passes through
        // CX-T-07 owner decision (2026-08-25, ALIGN UP): floor raised from 0.05 U to 1.0 U to match
        // TandemKit's SetMaxBolusLimitRequest throwing floor.
        #expect(Interlocks.clampMaxBolusLimit(0.5) == 1.0)     // below the new 1.0 U floor → floored
        #expect(Interlocks.clampMaxBolusLimit(-5) == 1.0)      // negative → floored, never ≤ 0
        #expect(Interlocks.clampMaxBolusLimit(1.0) == 1.0)     // at the floor → unchanged
    }

    @Test func theHardCapItselfIsUnchanged() {
        #expect(Interlocks.absoluteMaxUnits == 25.0)           // owner-locked; S10's TDD-relative confirms never touch this
        #expect(Interlocks.minMaxBolusLimitUnits == 1.0)       // CX-T-07 ALIGN UP (2026-08-25)
        #expect(Interlocks.minMaxBasalLimitUnitsPerHour == 1.0)
        #expect(Interlocks.maxMaxBasalLimitUnitsPerHour == 15.0)   // WR-02: kit's byte-verified ceiling
    }

    /// WR-02 (closes 15-GAP-01): `setMaxBasal` now clamps symmetrically with `setMaxBolus`. A value above
    /// the kit's byte-verified 15.0 U/hr throwing ceiling must CLAMP to 15.0 (and dispatch) rather than
    /// throw a raw, unlocalized `ValidationError`; a sub-floor value clamps up to the 1.0 U/hr floor.
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
