import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Every launch forces `appMode` to `.advanced` so a stale persisted sub-Advanced value cannot strand
/// the device with no recovery UI (`ModeViews` is gone).
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
        // A leftover "modeEarned" below Advanced must not clamp the device on relaunch —
        // `ModeViews` (the only UI that could raise the mode back) is gone, so a clamp would
        // permanently strand pump-control functionality with zero recovery UI.
        let saved = AppSettings.shared.appMode
        defer { AppSettings.shared.appMode = saved }
        let d = freshDefaults()
        d.set(AppMode.standard.rawValue, forKey: "modeEarned")  // stale key; no longer read
        AppSettings.shared.appMode = .standard
        let s = store(d)
        #expect(s.activeMode == .advanced)  // active mode forced to Advanced regardless
    }

    @Test func evenAPoisonedSimpleModeEarnedIsForcedToAdvancedOnRelaunch() {
        // Same stranding check at the lowest tier.
        let saved = AppSettings.shared.appMode
        defer { AppSettings.shared.appMode = saved }
        let d = freshDefaults()
        d.set(AppMode.simple.rawValue, forKey: "modeEarned")  // stale key; no longer read
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
