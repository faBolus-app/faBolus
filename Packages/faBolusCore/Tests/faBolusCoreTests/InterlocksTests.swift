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
    }
}
