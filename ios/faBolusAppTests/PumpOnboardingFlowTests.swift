import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// The one-time "Connect your pump" flag on `ModeStore`: defaults false, flips + persists on
/// `completePumpOnboarding()`, and survives relaunch (a fresh `ModeStore` reading the same
/// `UserDefaults` suite).
@Suite(.serialized) @MainActor
struct PumpOnboardingFlowTests {

    /// A private UserDefaults suite for the pump-onboarded key, isolated per test.
    private func freshDefaults() -> UserDefaults {
        let name = "pumponboarding-test-\(UUID().uuidString)"
        return UserDefaults(suiteName: name)!
    }
    private func store(_ d: UserDefaults) -> ModeStore { ModeStore(defaults: d, settings: .shared) }

    @Test func pumpOnboardingStartsFalse() {
        let s = store(freshDefaults())
        #expect(!s.hasCompletedPumpOnboarding)
    }

    @Test func completePumpOnboardingFlipsAndPersists() {
        let d = freshDefaults()
        let s = store(d)
        #expect(!s.hasCompletedPumpOnboarding)
        s.completePumpOnboarding()
        #expect(s.hasCompletedPumpOnboarding)
        #expect(store(d).hasCompletedPumpOnboarding)  // persisted across relaunch
    }

    @Test func pumpOnboardingFlagIsIndependentOfModeOnboardingFlag() {
        let d = freshDefaults()
        let s = store(d)
        // `hasCompletedOnboarding` is force-true from init (the mode-onboarding overlay is gone);
        // the pump-connect flag is the separate one-time flag this test actually pins.
        #expect(s.hasCompletedOnboarding)
        #expect(!s.hasCompletedPumpOnboarding)
        s.completePumpOnboarding()
        #expect(s.hasCompletedOnboarding && s.hasCompletedPumpOnboarding)
    }
}
