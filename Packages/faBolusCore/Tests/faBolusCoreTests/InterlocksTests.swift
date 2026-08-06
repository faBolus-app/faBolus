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
        #expect(Interlocks.clampMaxBolusLimit(0.01) == 0.05)   // below the 0.05 floor → floored
        #expect(Interlocks.clampMaxBolusLimit(-5) == 0.05)     // negative → floored, never ≤ 0
    }

    @Test func theHardCapItselfIsUnchanged() {
        #expect(Interlocks.absoluteMaxUnits == 25.0)           // owner-locked; S10's TDD-relative confirms never touch this
        #expect(Interlocks.minMaxBolusLimitUnits == 0.05)
    }
}
