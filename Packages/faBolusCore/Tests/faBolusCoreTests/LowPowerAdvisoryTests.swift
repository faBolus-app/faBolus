import Testing
import Foundation
@testable import faBolusCore

/// P16 F3 — the shared Low Power Mode advisory predicate. Pins that the banner shows ONLY when Low
/// Power Mode is on AND a live source is connected AND it hasn't been dismissed this episode, and that
/// the copy stays advisory (never implies a dosing action). WARN-only: nothing here can alter cadence
/// or gate a dose.
struct LowPowerAdvisoryTests {

    /// On only for lpm + connected + not-dismissed.
    @Test func warnsOnlyWhenLpmAndConnectedAndNotDismissed() {
        #expect(LowPowerAdvisory.shouldWarn(lpmActive: true, sourceConnected: true, dismissedEpisode: false))
    }

    /// Off when idle (no source connected), even with Low Power Mode on.
    @Test func silentWhenIdle() {
        #expect(!LowPowerAdvisory.shouldWarn(lpmActive: true, sourceConnected: false, dismissedEpisode: false))
    }

    /// Off once dismissed for this episode.
    @Test func silentWhenDismissedThisEpisode() {
        #expect(!LowPowerAdvisory.shouldWarn(lpmActive: true, sourceConnected: true, dismissedEpisode: true))
    }

    /// Off whenever Low Power Mode is off, regardless of connection/dismissal.
    @Test func silentWhenLowPowerModeOff() {
        #expect(!LowPowerAdvisory.shouldWarn(lpmActive: false, sourceConnected: true, dismissedEpisode: false))
        #expect(!LowPowerAdvisory.shouldWarn(lpmActive: false, sourceConnected: false, dismissedEpisode: true))
    }

    /// Exhaustive truth table — the predicate is exactly the AND of (lpm, connected, not-dismissed).
    @Test func fullTruthTable() {
        for lpm in [false, true] {
            for connected in [false, true] {
                for dismissed in [false, true] {
                    let expected = lpm && connected && !dismissed
                    #expect(
                        LowPowerAdvisory.shouldWarn(
                            lpmActive: lpm, sourceConnected: connected,
                            dismissedEpisode: dismissed) == expected)
                }
            }
        }
    }

    /// Copy is factual and advisory — mentions Low Power Mode and never uses a dosing verb. Matched as
    /// whole words (the app name "faBolus" legitimately contains "bolus", which is not a dosing action).
    @Test func copyIsAdvisoryNeverDosing() {
        let lower = LowPowerAdvisory.message.lowercased()
        #expect(lower.contains("low power mode"))
        let words = Set(lower.split { !$0.isLetter }.map(String.init))
        for dosing in ["bolus", "deliver", "dose", "suspend", "insulin", "units"] {
            #expect(!words.contains(dosing))
        }
    }
}
