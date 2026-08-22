import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// P14 S3 — the mode state machine. Phase 8 (08-01, LOCK-01) inverts the first-run branch: a fresh
/// install now starts EVERYONE directly at Advanced (no Simple/guided-unlock onboarding), and the
/// first-run onboarding flag is force-set `true` unconditionally so the KEPT `ConnectPumpOnboardingView`
/// step stays reachable. The guided-unlock state machine (`completeNextObjective`/`expertOptOutToAdvanced`/
/// `select`/`returnTo`/`earnedMode`/the `"modeEarned"` key) is left compiled per 08-OWNER-FLAGS.md Flag 1
/// (minimal diff) — it stays reachable for a RETURNING user upgrading from a pre-Phase-8 build that
/// persisted a lower earned ceiling; the tests below that exercise it seed that returning-user state
/// directly via the injected `UserDefaults` rather than relying on the (now-Advanced) fresh-install default.
@Suite(.serialized) @MainActor
struct ModeStoreTests {

    /// A private UserDefaults suite for the earned/onboarded keys, cleaned up after.
    private func freshDefaults() -> UserDefaults {
        let name = "modestore-test-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }
    private func store(_ d: UserDefaults) -> ModeStore { ModeStore(defaults: d, settings: .shared) }

    @Test func freshInstallStartsAtAdvancedWithOnboardingAlreadyComplete() {
        let saved = AppSettings.shared.appMode
        defer { AppSettings.shared.appMode = saved }
        AppSettings.shared.appMode = .simple            // even a poisoned/legacy "simple" value…
        let s = store(freshDefaults())
        #expect(s.earnedMode == .advanced)              // …is force-set to Advanced on first run.
        #expect(s.activeMode == .advanced)
        #expect(s.hasCompletedOnboarding)                // no first-run overlay left to gate on
    }

    @Test func returningUserWithAPriorLowerEarnedCeilingIsStillClampedOnRelaunch() {
        // Simulates a user upgrading from a pre-Phase-8 build that persisted "modeEarned" = "standard"
        // (the returning-user branch — `if let raw = d.string(forKey: earnedKey)` — is UNCHANGED by
        // this phase; only the else/first-run branch was inverted).
        let saved = AppSettings.shared.appMode
        defer { AppSettings.shared.appMode = saved }
        let d = freshDefaults()
        d.set(AppMode.standard.rawValue, forKey: "modeEarned")
        AppSettings.shared.appMode = .advanced          // a stale/over-high persisted active mode…
        let s = store(d)
        #expect(s.earnedMode == .standard)              // …the earned ceiling from disk is honored…
        #expect(s.activeMode == .standard)              // …and the stale Advanced is clamped down to it.
    }

    @Test func selectStillClampsToTheEarnedCeilingForAReturningUser() {
        let saved = AppSettings.shared.appMode
        defer { AppSettings.shared.appMode = saved }
        let d = freshDefaults()
        d.set(AppMode.simple.rawValue, forKey: "modeEarned")
        let s = store(d)                                // earned = .simple (returning-user branch)
        s.select(.advanced)
        #expect(s.activeMode == .simple)                // can't activate above the ceiling
        s.completeNextObjective()                       // earn Standard
        s.select(.advanced)
        #expect(s.activeMode == .standard)              // still clamped to the new ceiling
        s.select(.standard)
        #expect(s.activeMode == .standard)              // …but Standard is now selectable
    }

    @Test func completeNextObjectiveIsANoOpAtTheAdvancedCeiling() {
        let saved = AppSettings.shared.appMode
        defer { AppSettings.shared.appMode = saved }
        let s = store(freshDefaults())                  // fresh install: earned = .advanced already
        s.completeNextObjective()
        #expect(s.earnedMode == .advanced && s.activeMode == .advanced)   // no-op at the ceiling
    }

    @Test func expertOptOutJumpsStraightToAdvancedForAReturningUser() {
        let saved = AppSettings.shared.appMode
        defer { AppSettings.shared.appMode = saved }
        let d = freshDefaults()
        d.set(AppMode.simple.rawValue, forKey: "modeEarned")
        let s = store(d)                                // earned = .simple (returning-user branch)
        s.expertOptOutToAdvanced()
        #expect(s.earnedMode == .advanced && s.activeMode == .advanced)
    }

    @Test func returnToLowersWithoutLosingWhatIsEarned() {
        let saved = AppSettings.shared.appMode
        defer { AppSettings.shared.appMode = saved }
        let s = store(freshDefaults())                  // fresh install: earned = .advanced already
        s.returnTo(.simple)
        #expect(s.activeMode == .simple && s.earnedMode == .advanced)   // simplified UI, ceiling retained
        s.select(.advanced)
        #expect(s.activeMode == .advanced)              // still reachable — it was earned
    }

    @Test func onboardingCompletionIsIdempotentAndAlreadyTrueOnFreshInstall() {
        let d = freshDefaults()
        let saved = AppSettings.shared.appMode
        defer { AppSettings.shared.appMode = saved }
        let s = store(d)
        #expect(s.hasCompletedOnboarding)               // already true at init — no overlay to dismiss
        s.completeOnboarding()                          // the now-dead setter stays callable, harmlessly
        #expect(s.hasCompletedOnboarding)
        #expect(store(d).hasCompletedOnboarding)        // persisted across relaunch
    }
}
