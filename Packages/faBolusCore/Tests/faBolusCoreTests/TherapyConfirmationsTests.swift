import Testing
@testable import faBolusCore

/// P14 S10 (§2.1(5)): the TDD-relative max-bolus-limit CONFIRM tier — warns, never blocks, and is
/// strictly separate from the absolute 25 U HARD cap (`Interlocks.clampMaxBolusLimit`).
struct TherapyConfirmationsTests {

    @Test func noConfirmWhenTddUnknown() {
        // No TDD ⇒ no relative bound can be computed ⇒ never a confirm (the hard cap still applies).
        #expect(TherapyConfirmations.maxBolusLimitConfirm(proposedUnits: 25, totalDailyInsulinUnits: 0) == nil)
    }

    @Test func confirmsOnlyStrictlyAboveTheTddFraction() {
        // TDD 40 ⇒ threshold 20 U. At the threshold → no confirm; strictly above → confirm.
        #expect(TherapyConfirmations.maxBolusLimitConfirm(proposedUnits: 20, totalDailyInsulinUnits: 40) == nil)
        #expect(TherapyConfirmations.maxBolusLimitConfirm(proposedUnits: 20.5, totalDailyInsulinUnits: 40) != nil)
    }

    @Test func neverFiresWhenTheCeilingIsSmallRelativeToTdd() {
        // TDD 60 ⇒ threshold 30 U, above the 25 U hard cap — so nothing reachable in the editor confirms.
        #expect(TherapyConfirmations.maxBolusLimitConfirm(proposedUnits: Interlocks.absoluteMaxUnits,
                                                          totalDailyInsulinUnits: 60) == nil)
    }

    @Test func confirmIsAdviceNotAClamp() {
        // It returns a message for a large-but-legal edit and names the user's OWN TDD; it does not bound
        // the value. The 25 U hard cap is enforced separately by `Interlocks`, unaffected by this.
        let msg = TherapyConfirmations.maxBolusLimitConfirm(proposedUnits: 24, totalDailyInsulinUnits: 20)
        #expect(msg != nil)
        #expect(msg?.contains("20 U") == true)                 // names the user's own TDD
        // The proposed amount renders correctly ONCE — `formatUnits` already carries " U" (guards against
        // a doubled "U U" suffix in this user-facing safety dialog).
        #expect(msg?.contains("24.0 U ") == true)
        #expect(msg?.contains("U U") == false)
        // The clamp tier is independent and still hard-caps at 25 regardless of any confirmation.
        #expect(Interlocks.clampMaxBolusLimit(1000) == Interlocks.absoluteMaxUnits)
    }
}
