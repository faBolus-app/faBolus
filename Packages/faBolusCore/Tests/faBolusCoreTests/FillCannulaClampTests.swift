import Testing
@testable import faBolusCore

/// CX-T-07 / Pitfall 4: `FillLimits.clampPrimeSize` is the app-side secondary defense against 0 (upstream-
/// invalid — pumpX2's `FillCannulaRequest` throws on `primeSizeMilliUnits <= 0`) reaching the wire as a
/// "valid" no-op fill. The kit init (`FillCannulaRequest(primeSize:)`, now throwing) is the primary
/// boundary; this clamp is the secondary one so `TandemBackend.fillCannula(milliunits: 0)` never even
/// attempts a 0 mU wire write. The deliberate 1.0U `maxCannulaMilliunits` cap must stay unchanged — NOT
/// raised alongside the kit's 3000 mU ceiling.
struct FillCannulaClampTests {

    @Test func clampNeverYieldsZeroOrNegative() {
        #expect(FillLimits.clampPrimeSize(0) == 1)  // 0 is upstream-invalid → floored to 1, never 0
        #expect(FillLimits.clampPrimeSize(-5) == 1)  // negative → floored, never ≤ 0
    }

    @Test func clampPassesThroughMidRangeValues() {
        #expect(FillLimits.clampPrimeSize(300) == 300)
        #expect(FillLimits.clampPrimeSize(1) == 1)  // floor itself is a valid pass-through
    }

    @Test func clampCapsAtTheDeliberateOneUnitCeilingUnraised() {
        // The 1.0U cap (maxCannulaMilliunits = 1000) is a deliberate app ceiling BELOW the kit's 3000 mU
        // upstream ceiling — this task raises only the FLOOR (Pitfall 4), never this cap.
        #expect(FillLimits.clampPrimeSize(9999) == 1000)
        #expect(FillLimits.clampPrimeSize(3000) == 1000)  // even the kit's own ceiling is still capped here
    }

    @Test func maxCannulaMilliunitsCapItselfIsUnchanged() {
        #expect(FillLimits.maxCannulaMilliunits == 1000)  // 1.0 U — unraised (CX-T-07 explicitly keeps this)
        #expect(FillLimits.minCannulaMilliunits == 1)
    }
}
