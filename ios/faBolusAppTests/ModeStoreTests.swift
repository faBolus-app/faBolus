import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// P14 S3 — the mode state machine's safety-relevant logic: everyone starts at Simple (no migration),
/// the active mode is clamped to the earned ceiling in the store (not the UI), the ceiling only rises via
/// the guided sequence or the expert opt-out, and a stale/over-high active mode is clamped down on relaunch.
@Suite(.serialized) @MainActor
struct ModeStoreTests {

    /// A private UserDefaults suite for the earned/onboarded keys, cleaned up after.
    private func freshDefaults() -> UserDefaults {
        let name = "modestore-test-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }
    private func store(_ d: UserDefaults) -> ModeStore { ModeStore(defaults: d, settings: .shared) }

    @Test func freshInstallStartsEveryoneAtSimpleWithNoMigration() {
        let saved = AppSettings.shared.appMode
        defer { AppSettings.shared.appMode = saved }
        AppSettings.shared.appMode = .advanced          // even an existing "advanced" user…
        let s = store(freshDefaults())
        #expect(s.earnedMode == .simple)                // …is reset to Simple on first mode-aware launch.
        #expect(s.activeMode == .simple)                // ModeStore.init never reads advancedControlEnabled
    }                                                   // by design — no silent migration.

    @Test func selectClampsToTheEarnedCeiling() {
        let saved = AppSettings.shared.appMode
        defer { AppSettings.shared.appMode = saved }
        let s = store(freshDefaults())                  // earned = .simple
        s.select(.advanced)
        #expect(s.activeMode == .simple)                // can't activate above the ceiling
        s.completeNextObjective()                       // earn Standard
        s.select(.advanced)
        #expect(s.activeMode == .standard)              // still clamped to the new ceiling
        s.select(.standard)
        #expect(s.activeMode == .standard)              // …but Standard is now selectable
    }

    @Test func objectivesAdvanceOneTierThenStopAtAdvanced() {
        let saved = AppSettings.shared.appMode
        defer { AppSettings.shared.appMode = saved }
        let s = store(freshDefaults())
        s.completeNextObjective(); #expect(s.earnedMode == .standard && s.activeMode == .standard)
        s.completeNextObjective(); #expect(s.earnedMode == .advanced && s.activeMode == .advanced)
        s.completeNextObjective(); #expect(s.earnedMode == .advanced)   // no-op at the ceiling
    }

    @Test func expertOptOutJumpsStraightToAdvanced() {
        let saved = AppSettings.shared.appMode
        defer { AppSettings.shared.appMode = saved }
        let s = store(freshDefaults())                  // Simple
        s.expertOptOutToAdvanced()
        #expect(s.earnedMode == .advanced && s.activeMode == .advanced)
    }

    @Test func earnedCeilingPersistsAndClampsStaleActiveOnRelaunch() {
        let saved = AppSettings.shared.appMode
        defer { AppSettings.shared.appMode = saved }
        let d = freshDefaults()
        do { let s = store(d); s.completeNextObjective() }   // earn + activate Standard, persisted in `d`
        // Simulate a stale/over-high restored active mode, then relaunch against the SAME earned ceiling.
        AppSettings.shared.appMode = .advanced
        let s2 = store(d)
        #expect(s2.earnedMode == .standard)             // ceiling survived relaunch
        #expect(s2.activeMode == .standard)             // stale Advanced clamped down to the ceiling
    }

    @Test func returnToLowersWithoutLosingWhatIsEarned() {
        let saved = AppSettings.shared.appMode
        defer { AppSettings.shared.appMode = saved }
        let s = store(freshDefaults())
        s.expertOptOutToAdvanced()                      // earned + active = Advanced
        s.returnTo(.simple)
        #expect(s.activeMode == .simple && s.earnedMode == .advanced)   // simplified UI, ceiling retained
        s.select(.advanced)
        #expect(s.activeMode == .advanced)              // still reachable — it was earned
    }

    @Test func onboardingIsShownExactlyOnce() {
        let d = freshDefaults()
        let saved = AppSettings.shared.appMode
        defer { AppSettings.shared.appMode = saved }
        let s = store(d)
        #expect(!s.hasCompletedOnboarding)
        s.completeOnboarding()
        #expect(s.hasCompletedOnboarding)
        #expect(store(d).hasCompletedOnboarding)        // persisted across relaunch
    }
}
