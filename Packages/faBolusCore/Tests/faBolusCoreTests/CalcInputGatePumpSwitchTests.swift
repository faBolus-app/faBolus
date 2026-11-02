import Testing
@testable import faBolusCore

/// Pins the two `CalcInputGate` classifications either side of a pump switch, at the gate level,
/// independent of the session. A new pairing clearing the old pump's readings is PumpSession's job.
@Suite struct CalcInputGatePumpSwitchTests {

    /// Before a switch reset nils the previous pump's calculator snapshot, an unverified carbs-mode compose
    /// with therapy still attributed as "available" only prompts a warned override — it never blocks. This
    /// is the shape that let a stale carb ratio/ISF/target reach the confirm UI.
    @Test func leftoverTherapyAvailablePromptsRatherThanBlocking() {
        #expect(
            CalcInputGate.decide(
                isCarbsMode: true, inputsVerified: false, iobStale: false,
                therapyStale: true, therapyAvailable: true, overrideAccepted: false) == .prompt(.therapy))
    }

    /// Once therapy is genuinely unattributed (the post-switch state), the gate blocks outright — no dose
    /// can be sized off the previous pump's settings — for every staleness-flag combination.
    @Test func noAttributedTherapyBlocksForEveryFlagCombination() {
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
}
