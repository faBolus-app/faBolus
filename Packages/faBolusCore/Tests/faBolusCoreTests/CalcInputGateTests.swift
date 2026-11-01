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

    // MARK: - §13 no-zero-IOB-override shape: exactly three kinds, none named drop/zero/ignore

    @Test func kindIsExactlyThreeCasesNeverADropZeroOrIgnoreVariant() {
        // The frozen owner decision: the override is always a warned two-way choice (include-last-known vs
        // cancel per input, or both) — never a "drop / zero the IOB" case. `DoseComposer.composePhone` calls
        // `decide()`, so this is where that shape invariant is pinned.
        #expect(CalcInputGate.Kind.allCases == [.iob, .therapy, .both])
        #expect(CalcInputGate.Kind.allCases.count == 3)
        for kind in CalcInputGate.Kind.allCases {
            let name = kind.rawValue.lowercased()
            #expect(!name.contains("drop"))
            #expect(!name.contains("zero"))
            #expect(!name.contains("ignore"))
        }
    }
}
