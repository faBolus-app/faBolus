import Foundation
import faBolusCore
import Observation

/// First-run onboarding tracker.
@MainActor
@Observable
final class ModeStore {
    /// The production instance. A **singleton** so tests can construct their own isolated instance via
    /// the injectable `init(defaults:settings:)` without sharing state with `ModeStore.shared`.
    static let shared = ModeStore()

    /// Whether the first-run "Connect your pump" step has been shown (exactly once).
    private(set) var hasCompletedPumpOnboarding: Bool

    /// Force-true: the first-run mode-onboarding overlay is gone; nothing left to gate on this. Kept
    /// (rather than deleted) because `RootContainerView` still reads it to gate the pump-connect cover.
    private(set) var hasCompletedOnboarding: Bool

    private let d: UserDefaults
    private let settings: AppSettings
    private static let pumpOnboardedKey = "pumpConnectOnboarded"

    init(defaults: UserDefaults = .standard, settings: AppSettings = .shared) {
        self.d = defaults
        self.settings = settings
        hasCompletedOnboarding = true
        hasCompletedPumpOnboarding = d.object(forKey: Self.pumpOnboardedKey) as? Bool ?? false
    }

    /// Mark the first-run "Connect your pump" step shown. Called from any of the step's three exits.
    func completePumpOnboarding() {
        hasCompletedPumpOnboarding = true
        d.set(true, forKey: Self.pumpOnboardedKey)
    }
}
