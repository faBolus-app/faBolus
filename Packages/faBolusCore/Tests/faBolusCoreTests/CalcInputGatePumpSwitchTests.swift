import Testing
@testable import faBolusCore

/// Pins the two `CalcInputGate` classifications either side of a pump switch. Companion to
/// `PumpSwitchSnapshotFreshnessTests` (`faBolusApp`), which drives the REAL `TandemBackend` input
/// (`calcSnapshot`) into this same gate via `recommendBolus` and is where the actual regression is caught —
/// `decide` itself is a pure, already-correct function; this file exists so the switch scenario's two
/// classifications are pinned at the gate level too, independent of any backend.
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
