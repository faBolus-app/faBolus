import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// P14 S3 — the mode state machine. Phase 8 (08-01, LOCK-01) inverted the first-run branch: a fresh
/// install starts EVERYONE directly at Advanced (no Simple/guided-unlock onboarding), and the first-run
/// onboarding flag is force-set `true` unconditionally so the KEPT `ConnectPumpOnboardingView` step stays
/// reachable. The CR-01 gap-closure (08-REVIEW.md) then tightened `init` further: it now unconditionally
/// forces BOTH the earned ceiling AND the active mode to `.advanced` on EVERY launch, first-run OR
/// returning, ignoring whatever "modeEarned" a pre-Phase-8 build may have persisted — a stale sub-.advanced
/// value can no longer strand a device below Advanced, since `ModeViews.swift` (the only UI that could
/// ever raise the ceiling back up) is deleted this phase. The guided-unlock state machine
/// (`completeNextObjective`/`expertOptOutToAdvanced`/`select`/`returnTo`/`earnedMode`/the `"modeEarned"`
/// key) is left compiled per 08-OWNER-FLAGS.md Flag 1 (minimal diff) but is dead code with no live caller;
/// the tests below that exercise it directly still document its own internal clamp semantics.
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

    @Test func staleSubAdvancedModeEarnedCanNoLongerStrandAReturningUser() {
        // CR-01 regression (08-REVIEW.md): a user upgrading from a pre-Phase-8 build with a persisted
        // "modeEarned" = "standard" (or anything below .advanced) must NOT be clamped down on relaunch —
        // `ModeViews.swift` (the only UI that could raise the ceiling back to Advanced) is deleted this
        // phase, so a clamp here would permanently strand the device below Advanced with zero recovery
        // UI, silently losing `GatedPumpWrite`-gated pump-control functionality (temp basal, profile
        // CRUD, CGM-session control, max bolus/basal, time sync, Control-IQ settings, alert config).
        let saved = AppSettings.shared.appMode
        defer { AppSettings.shared.appMode = saved }
        let d = freshDefaults()
        d.set(AppMode.standard.rawValue, forKey: "modeEarned")
        AppSettings.shared.appMode = .standard
        let s = store(d)
        #expect(s.earnedMode == .advanced)              // ceiling forced to Advanced despite stale disk value
        #expect(s.activeMode == .advanced)              // active mode forced to Advanced too
        #expect(d.string(forKey: "modeEarned") == AppMode.advanced.rawValue)  // rewritten on disk too
    }

    @Test func evenAPoisonedSimpleModeEarnedIsForcedToAdvancedOnRelaunch() {
        // Same CR-01 regression at the lowest tier — belt-and-suspenders across the whole enum range.
        let saved = AppSettings.shared.appMode
        defer { AppSettings.shared.appMode = saved }
        let d = freshDefaults()
        d.set(AppMode.simple.rawValue, forKey: "modeEarned")
        AppSettings.shared.appMode = .simple
        let s = store(d)
        #expect(s.earnedMode == .advanced)
        #expect(s.activeMode == .advanced)
    }

    @Test func selectStillClampsToTheEarnedCeilingWhenCalledDirectly() {
        // `select` is dead code (no live caller since `ModeViews.swift` was deleted) but stays compiled
        // per Flag 1; there is no public way to lower `earnedMode` below `.advanced` post-init anymore
        // (`init` always forces it), so this documents `select`'s own clamp against the only ceiling that
        // ever exists now — it can still move the ACTIVE mode up/down freely below that ceiling.
        let s = store(freshDefaults())                  // init always forces earned = .advanced now
        s.select(.simple)
        #expect(s.activeMode == .simple)                // select can still lower the ACTIVE mode…
        s.select(.advanced)
        #expect(s.activeMode == .advanced)              // …and raise it back, since the ceiling is Advanced
    }

    @Test func completeNextObjectiveIsANoOpAtTheAdvancedCeiling() {
        let saved = AppSettings.shared.appMode
        defer { AppSettings.shared.appMode = saved }
        let s = store(freshDefaults())                  // fresh install: earned = .advanced already
        s.completeNextObjective()
        #expect(s.earnedMode == .advanced && s.activeMode == .advanced)   // no-op at the ceiling
    }

    @Test func expertOptOutIsANoOpAtTheAdvancedCeiling() {
        let saved = AppSettings.shared.appMode
        defer { AppSettings.shared.appMode = saved }
        let s = store(freshDefaults())                  // init always forces earned = .advanced now
        s.expertOptOutToAdvanced()
        #expect(s.earnedMode == .advanced && s.activeMode == .advanced)
    }

    @Test func returnToLowersTheActiveModeWithoutLoweringTheForcedCeiling() {
        let saved = AppSettings.shared.appMode
        defer { AppSettings.shared.appMode = saved }
        let s = store(freshDefaults())                  // fresh install: earned = .advanced already
        s.returnTo(.simple)
        #expect(s.activeMode == .simple && s.earnedMode == .advanced)   // simplified UI, ceiling retained
        s.select(.advanced)
        #expect(s.activeMode == .advanced)              // still reachable — the ceiling is Advanced
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
