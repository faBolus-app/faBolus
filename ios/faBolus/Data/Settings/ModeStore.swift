import Foundation
import faBolusCore
import Observation

/// First-run onboarding tracker and the sole sanctioned writer of `AppSettings.appMode`.
/// Forces `.advanced` on every launch so a device cannot be stranded on a stale sub-Advanced value
/// with no recovery UI (`AccessPolicy` / `GatedPumpWrite` would otherwise lose pump-control).
@MainActor
@Observable
final class ModeStore {
    /// The production instance. A **singleton** because `init` has a side effect (it clamps/first-run-sets
    /// `AppSettings.appMode`): a per-view `@State = ModeStore()` would re-run that side effect on every
    /// SwiftUI struct init and repeatedly clobber the active mode. One instance ⇒ the launch reset fires
    /// exactly once. Tests construct their own via the injectable `init(defaults:settings:)`.
    static let shared = ModeStore()

    /// Whether the first-run mode onboarding has been shown (so it appears exactly once).
    private(set) var hasCompletedOnboarding: Bool
    /// Whether the first-run "Connect your pump" step has been shown (exactly once).
    private(set) var hasCompletedPumpOnboarding: Bool

    private let d: UserDefaults
    private let settings: AppSettings
    private static let onboardedKey = "modeOnboarded"
    private static let pumpOnboardedKey = "pumpConnectOnboarded"

    /// The active mode — read through `AppSettings` so the evaluator has a single source of truth.
    var activeMode: AppMode { settings.appMode }

    init(defaults: UserDefaults = .standard, settings: AppSettings = .shared) {
        self.d = defaults
        self.settings = settings
        // Force-set true — the Simple-mode first-run overlay is gone; nothing left to gate on this.
        hasCompletedOnboarding = true
        hasCompletedPumpOnboarding = d.object(forKey: Self.pumpOnboardedKey) as? Bool ?? false
        // Force `.advanced` on every launch. A stale sub-Advanced value would otherwise strand the
        // device with no recovery UI and silently lose `GatedPumpWrite`-gated pump-control.
        settings.appMode = .advanced
    }

    /// Mark the first-run onboarding shown.
    func completeOnboarding() {
        hasCompletedOnboarding = true
        d.set(true, forKey: Self.onboardedKey)
    }

    /// Mark the first-run "Connect your pump" step shown. Called from any of the step's three exits.
    func completePumpOnboarding() {
        hasCompletedPumpOnboarding = true
        d.set(true, forKey: Self.pumpOnboardedKey)
    }
}
