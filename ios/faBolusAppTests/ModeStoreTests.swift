import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// P14 S3 — the mode state machine. Phase 8 (08-01, LOCK-01) inverted the first-run branch: a fresh
/// install starts EVERYONE directly at Advanced (no Simple/guided-unlock onboarding), and the first-run
/// onboarding flag is force-set `true` unconditionally so the KEPT `ConnectPumpOnboardingView` step stays
/// reachable. The CR-01 gap-closure (08-REVIEW.md) then tightened `init` further: it now unconditionally
/// forces the active mode to `.advanced` on EVERY launch, first-run OR returning, ignoring whatever
/// "modeEarned" a pre-Phase-8 build may have persisted — a stale sub-.advanced value can no longer strand
/// a device below Advanced, since `ModeViews.swift` (the only UI that could ever raise the mode back up)
/// is deleted.
///
/// 17-07 (D1-02): the guided-unlock state machine (`completeNextObjective`/`expertOptOutToAdvanced`/
/// `select`/`returnTo`/`earnedMode`/the `"modeEarned"` key) that used to stay compiled-but-unreachable per
/// 08-OWNER-FLAGS.md Flag 1 is removed from `ModeStore` outright, so the tests that used to exercise it
/// directly are removed too. What remains below documents the retained behavior: `AppSettings.appMode`
/// forced to `.advanced` on every launch (first-run or returning, regardless of stale disk state) and the
/// two first-run onboarding flags.
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
        AppSettings.shared.appMode = .simple  // even a poisoned/legacy "simple" value…
        let s = store(freshDefaults())
        #expect(s.activeMode == .advanced)  // …is force-set to Advanced on first run.
        #expect(s.hasCompletedOnboarding)  // no first-run overlay left to gate on
    }

    @Test func staleSubAdvancedModeEarnedCanNoLongerStrandAReturningUser() {
        // CR-01 regression (08-REVIEW.md): a user upgrading from a pre-Phase-8 build with a persisted
        // "modeEarned" = "standard" (or anything below .advanced) must NOT be clamped down on relaunch —
        // `ModeViews.swift` (the only UI that could raise the mode back to Advanced) is deleted, so a
        // clamp here would permanently strand the device below Advanced with zero recovery UI, silently
        // losing `GatedPumpWrite`-gated pump-control functionality (temp basal, profile CRUD, CGM-session
        // control, max bolus/basal, time sync, Control-IQ settings, alert config).
        let saved = AppSettings.shared.appMode
        defer { AppSettings.shared.appMode = saved }
        let d = freshDefaults()
        d.set(AppMode.standard.rawValue, forKey: "modeEarned")  // stale pre-17-07 key; no longer read
        AppSettings.shared.appMode = .standard
        let s = store(d)
        #expect(s.activeMode == .advanced)  // active mode forced to Advanced regardless
    }

    @Test func evenAPoisonedSimpleModeEarnedIsForcedToAdvancedOnRelaunch() {
        // Same CR-01 regression at the lowest tier — belt-and-suspenders across the whole enum range.
        let saved = AppSettings.shared.appMode
        defer { AppSettings.shared.appMode = saved }
        let d = freshDefaults()
        d.set(AppMode.simple.rawValue, forKey: "modeEarned")  // stale pre-17-07 key; no longer read
        AppSettings.shared.appMode = .simple
        let s = store(d)
        #expect(s.activeMode == .advanced)
    }

    @Test func onboardingCompletionIsIdempotentAndAlreadyTrueOnFreshInstall() {
        let d = freshDefaults()
        let saved = AppSettings.shared.appMode
        defer { AppSettings.shared.appMode = saved }
        let s = store(d)
        #expect(s.hasCompletedOnboarding)  // already true at init — no overlay to dismiss
        s.completeOnboarding()  // the now-dead setter stays callable, harmlessly
        #expect(s.hasCompletedOnboarding)
        #expect(store(d).hasCompletedOnboarding)  // persisted across relaunch
    }
}
