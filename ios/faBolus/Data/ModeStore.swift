import Foundation
import faBolusCore
import Observation

/// P14 Slice 3 — the mode state machine: the **earned ceiling**, the guided **sequential unlock**, and
/// the **expert opt-out**, with all clamping IN the store (never the UI) — modeled on
/// `RemotePeerPolicyStore.setPolicy`, which clamps a requested grant down rather than trusting the caller.
///
/// `AppSettings.appMode` is the ACTIVE mode the single access evaluator reads (S2). This store is the sole
/// sanctioned writer of it and keeps the active mode ≤ the earned ceiling, so no UI path can activate a
/// mode the user hasn't unlocked. Owner decision (2026-08-06): everyone — fresh installs AND existing
/// upgraded users — starts in **Simple** and re-earns Advanced via the guided Objectives sequence; the
/// expert opt-out is a warned fast path straight to Advanced (not a fourth mode). No silent migration from
/// `advancedControlEnabled`.
///
/// §13: the Objectives COPY is experimental-distribution surface and needs clinical review before an
/// `experimental` build is distributed. The mechanism here is copy-agnostic; the shipped strings are draft.
@MainActor
@Observable
final class ModeStore {
    /// The production instance. A **singleton** because `init` has a side effect (it clamps/first-run-sets
    /// `AppSettings.appMode`): a per-view `@State = ModeStore()` would re-run that side effect on every
    /// SwiftUI struct init and repeatedly clobber the active mode. One instance ⇒ the launch reset fires
    /// exactly once. Tests construct their own via the injectable `init(defaults:settings:)`.
    static let shared = ModeStore()

    /// The highest mode the user has unlocked. The active mode is always clamped to this.
    private(set) var earnedMode: AppMode
    /// Whether the first-run mode onboarding has been shown (so it appears exactly once).
    private(set) var hasCompletedOnboarding: Bool

    private let d: UserDefaults
    private let settings: AppSettings
    private static let earnedKey = "modeEarned"
    private static let onboardedKey = "modeOnboarded"

    /// The active mode — read through `AppSettings` so the evaluator has a single source of truth.
    var activeMode: AppMode { settings.appMode }

    init(defaults: UserDefaults = .standard, settings: AppSettings = .shared) {
        self.d = defaults
        self.settings = settings
        hasCompletedOnboarding = d.object(forKey: Self.onboardedKey) as? Bool ?? false
        if let raw = d.string(forKey: Self.earnedKey), let m = AppMode(rawValue: raw) {
            // Returning user: keep the earned ceiling and clamp the (possibly stale/over-high) persisted
            // active mode down to it, so a lowered ceiling can never leave a higher mode active.
            earnedMode = m
            if settings.appMode > m { settings.appMode = m }
        } else {
            // First run of a mode-aware build (owner-locked): EVERYONE starts at Simple and re-earns
            // Advanced. Deliberately does NOT read `advancedControlEnabled` (no silent migration).
            earnedMode = .simple
            settings.appMode = .simple
            d.set(AppMode.simple.rawValue, forKey: Self.earnedKey)
        }
    }

    /// Select an active mode. **Clamped to the earned ceiling in the store** — the UI may offer a higher
    /// mode, but the store refuses to activate one the user hasn't unlocked.
    func select(_ mode: AppMode) {
        settings.appMode = min(mode, earnedMode)
    }

    /// Advance the guided Objectives sequence by one tier (simple → standard → advanced) and activate it.
    /// A no-op at the ceiling. This and the expert opt-out are the ONLY ways the earned ceiling rises.
    func completeNextObjective() {
        switch earnedMode {
        case .simple:   raise(to: .standard)
        case .standard: raise(to: .advanced)
        case .advanced: break
        }
    }

    /// Expert opt-out: jump straight to Advanced (the UI gates this behind an explicit warning). Not a
    /// fourth mode — a fast path to the same `.advanced` earned tier.
    func expertOptOutToAdvanced() { raise(to: .advanced) }

    /// Lower the active mode without changing what's earned (a user choosing to simplify their UI). Never
    /// raises — `select`'s clamp guarantees that.
    func returnTo(_ mode: AppMode) { select(mode) }

    /// Mark the first-run onboarding shown.
    func completeOnboarding() {
        hasCompletedOnboarding = true
        d.set(true, forKey: Self.onboardedKey)
    }

    private func raise(to mode: AppMode) {
        if mode > earnedMode {
            earnedMode = mode
            d.set(mode.rawValue, forKey: Self.earnedKey)
        }
        settings.appMode = mode   // activate the newly-earned mode
    }
}
