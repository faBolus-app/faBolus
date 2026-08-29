import Testing
@testable import faBolusCore

/// Exhaustive matrix for the DIF-ux deliver-time gate (`CalcInputGate.decide`) — the pure extraction of the
/// branch logic that repeatedly harbored dose-path defects while it lived untested inside BolusEntryView.
/// Each row pins a safety property; a future edit that reintroduces a hole fails here.
@Suite struct CalcInputGateTests {

    // MARK: - Units mode never gates (and its dose is never a carb-calc dose — cleared on the mode switch)

    @Test func unitsModeAlwaysProceeds() {
        // Regardless of verification / staleness / therapy availability: a Units-mode dose is the dialed
        // number, not a calc dose.
        for verified in [true, false] {
            for iob in [true, false] {
                for therapy in [true, false] {
                    for avail in [true, false] {
                        #expect(
                            CalcInputGate.decide(
                                isCarbsMode: false, inputsVerified: verified,
                                iobStale: iob, therapyStale: therapy,
                                therapyAvailable: avail, overrideAccepted: false) == .proceed)
                    }
                }
            }
        }
    }

    // MARK: - Carbs mode: verified proceeds; unverified prompts (even in-window); re-entry proceeds

    @Test func carbsVerifiedProceeds() {
        #expect(
            CalcInputGate.decide(
                isCarbsMode: true, inputsVerified: true, iobStale: false,
                therapyStale: false, therapyAvailable: true, overrideAccepted: false) == .proceed)
        // Verified proceeds even if a display-staleness flag is somehow set (shouldn't happen, but the gate
        // keys on inputsVerified, not the flags).
        #expect(
            CalcInputGate.decide(
                isCarbsMode: true, inputsVerified: true, iobStale: true,
                therapyStale: true, therapyAvailable: true, overrideAccepted: false) == .proceed)
    }

    @Test func carbsUnverifiedNeitherFlagStillPrompts() {
        // The unconfirmed-but-in-window case: compose read timed out (inputsVerified=false) but both values
        // are still inside their windows (flags false). MUST still prompt — routed to .both — never silently
        // deliver. This is the exact case a window-only gate would have missed.
        #expect(
            CalcInputGate.decide(
                isCarbsMode: true, inputsVerified: false, iobStale: false,
                therapyStale: false, therapyAvailable: true, overrideAccepted: false) == .prompt(.both))
    }

    @Test func carbsUnverifiedKindSelection() {
        #expect(
            CalcInputGate.decide(
                isCarbsMode: true, inputsVerified: false, iobStale: true,
                therapyStale: false, therapyAvailable: true, overrideAccepted: false) == .prompt(.iob))
        #expect(
            CalcInputGate.decide(
                isCarbsMode: true, inputsVerified: false, iobStale: false,
                therapyStale: true, therapyAvailable: true, overrideAccepted: false) == .prompt(.therapy))
        #expect(
            CalcInputGate.decide(
                isCarbsMode: true, inputsVerified: false, iobStale: true,
                therapyStale: true, therapyAvailable: true, overrideAccepted: false) == .prompt(.both))
    }

    // MARK: - No real therapy ever read (op-115 never arrived) → BLOCK, never a deliverable guess

    @Test func carbsUnverifiedNoTherapyBlocks() {
        // A carb dose can't be sized without a real carb ratio, and there is no honest "last-known" to offer,
        // so every unverified carbs-mode compose with `therapyAvailable == false` must block (cancel-only) —
        // NEVER a `.prompt` that could deliver a dose off the hardcoded CR=10 guess. All flag combinations.
        for iob in [true, false] {
            for therapy in [true, false] {
                #expect(
                    CalcInputGate.decide(
                        isCarbsMode: true, inputsVerified: false,
                        iobStale: iob, therapyStale: therapy,
                        therapyAvailable: false, overrideAccepted: false) == .blockNoTherapy)
            }
        }
    }

    @Test func acceptedOverrideProceeds() {
        // Re-entry after the owner accepted the warned override for this attempt must NOT re-prompt.
        // (Only reachable when therapy WAS available, since the no-therapy case has no accept button.)
        for iob in [true, false] {
            for therapy in [true, false] {
                #expect(
                    CalcInputGate.decide(
                        isCarbsMode: true, inputsVerified: false,
                        iobStale: iob, therapyStale: therapy,
                        therapyAvailable: true, overrideAccepted: true) == .proceed)
            }
        }
    }

    // MARK: - Kind → override flags, and the manual-BG cap

    @Test func kindMapsToOverrideFlags() {
        #expect(CalcInputGate.Kind.iob.allowStaleIob && !CalcInputGate.Kind.iob.allowStaleTherapy)
        #expect(!CalcInputGate.Kind.therapy.allowStaleIob && CalcInputGate.Kind.therapy.allowStaleTherapy)
        #expect(CalcInputGate.Kind.both.allowStaleIob && CalcInputGate.Kind.both.allowStaleTherapy)
    }

    @Test func overrideDeliverUnitsNeverExceedsConsentOrFresh() {
        // IOB decayed → fresh recompute larger → deliver the consented baseline.
        #expect(CalcInputGate.overrideDeliverUnits(baseline: 5.0, freshRecompute: 5.9) == 5.0)
        // IOB rose / therapy tightened → fresh smaller → deliver the smaller fresh value.
        #expect(CalcInputGate.overrideDeliverUnits(baseline: 5.0, freshRecompute: 4.2) == 4.2)
        // Equal → either.
        #expect(CalcInputGate.overrideDeliverUnits(baseline: 3.0, freshRecompute: 3.0) == 3.0)
    }

    // MARK: - §13 Rule-1 (A1): DISPLAY gate — a dose sized off the hardcoded guess is never shown

    @Test func hardcodedGuessSuppressesNumericDose() {
        // op-115 never arrived → `therapyUnavailable` → the "recommendation" is sized off the hardcoded
        // CR 10 / ISF 40 / target 110 guess (uncited literals). Its number MUST NOT be displayed (Rule 1:
        // "every displayed number traces to a pump read, a user entry, or a published constant"). This is
        // the compose-time sibling of `carbsUnverifiedNoTherapyBlocks`, which blocks *delivering* the guess.
        var rec = BolusRecommendation()
        rec.recommendedUnits = 3.0
        rec.inputsVerified = false
        rec.therapyUnavailable = true
        #expect(rec.displaysNumericDose == false)
    }

    @Test func realButStaleOrVerifiedTherapyDisplays() {
        // Real CR/ISF/target were read at some point (possibly stale) → the numbers trace to real pump
        // reads, so they MAY display (the legitimate warned-override case). Only `therapyUnavailable` hides.
        var stale = BolusRecommendation()
        stale.recommendedUnits = 3.0
        stale.inputsVerified = false
        stale.therapyUnavailable = false
        stale.therapyStale = true
        #expect(stale.displaysNumericDose)
        // The verified fresh case displays too.
        var verified = BolusRecommendation()
        verified.recommendedUnits = 2.5
        verified.inputsVerified = true
        #expect(verified.displaysNumericDose)
    }
}
