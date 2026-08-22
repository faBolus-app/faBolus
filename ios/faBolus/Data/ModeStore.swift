import Foundation
import faBolusCore
import Observation

/// P14 Slice 3 — originally the mode state machine: the **earned ceiling**, the guided **sequential
/// unlock**, and the **expert opt-out**, with all clamping IN the store (never the UI) — modeled on
/// `RemotePeerPolicyStore.setPolicy`, which clamps a requested grant down rather than trusting the caller.
///
/// `AppSettings.appMode` is the ACTIVE mode the single access evaluator reads (S2). This store is the sole
/// sanctioned writer of it. Phase 8 (08-01, LOCK-01), tightened by the CR-01 gap-closure (08-REVIEW.md):
/// narrow `main` is advanced-only — `init` unconditionally forces BOTH the earned ceiling AND the active
/// mode to `.advanced` on EVERY launch, first-run or returning, regardless of any "modeEarned" value a
/// pre-Phase-8 build may have persisted. `ModeViews.swift` (the only UI that could ever raise the ceiling)
/// is deleted this phase, so there is no live UI path that can lower `appMode` below `.advanced` either —
/// the guided-unlock methods below (`completeNextObjective`/`expertOptOutToAdvanced`/`select`/`returnTo`)
/// stay compiled per 08-OWNER-FLAGS.md Flag 1 but are unreachable dead code, exercised only by tests that
/// seed the returning-user path directly.
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
    /// Phase 09.4 (D-01): whether the first-run "Connect your pump" step has been shown (so it appears
    /// exactly once, mirroring `hasCompletedOnboarding` above). Gated in `RootContainerView` alongside
    /// `!model.hasStoredPairing` so it never reappears once a pump is paired.
    private(set) var hasCompletedPumpOnboarding: Bool

    private let d: UserDefaults
    private let settings: AppSettings
    private static let earnedKey = "modeEarned"
    private static let onboardedKey = "modeOnboarded"
    private static let pumpOnboardedKey = "pumpConnectOnboarded"

    /// The active mode — read through `AppSettings` so the evaluator has a single source of truth.
    var activeMode: AppMode { settings.appMode }

    init(defaults: UserDefaults = .standard, settings: AppSettings = .shared) {
        self.d = defaults
        self.settings = settings
        // Phase 8 (08-01, LOCK-01): `hasCompletedOnboarding` is force-set `true` unconditionally — the
        // Simple-mode first-run overlay (`ModeOnboardingView`) is deleted this phase, so there is
        // nothing left to gate on it. Forcing it true (rather than editing `RootContainerView`'s gate)
        // keeps the KEPT `ConnectPumpOnboardingView` step's `&&` condition trivially satisfied without
        // touching that file's logic at all (Pitfall 3, RESEARCH option (a)).
        hasCompletedOnboarding = true
        hasCompletedPumpOnboarding = d.object(forKey: Self.pumpOnboardedKey) as? Bool ?? false
        // CR-01 gap-closure (08-REVIEW.md), tightening Phase 8 (08-01, LOCK-01): force BOTH the earned
        // ceiling AND the active mode to `.advanced` on EVERY launch — first-run OR returning — never
        // reading (and so never clamping down to) whatever "modeEarned" a pre-Phase-8 build may have
        // persisted. The prior returning-user branch only clamped the ACTIVE mode DOWN to that stale
        // ceiling and otherwise left it in place; since `ModeViews.swift` (the only UI that could ever
        // raise the ceiling back to Advanced) is deleted this phase, a device carrying a stale
        // sub-.advanced value was PERMANENTLY stranded below Advanced with zero recovery UI — silently
        // losing `GatedPumpWrite`-gated pump-control functionality. Narrow `main` is a single-adult
        // advanced t:slim X2 device (D-02); still does NOT read `advancedControlEnabled` (no silent
        // migration) — same posture as before.
        earnedMode = .advanced
        settings.appMode = .advanced
        d.set(AppMode.advanced.rawValue, forKey: Self.earnedKey)
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

    /// Phase 09.4 (D-01): mark the first-run "Connect your pump" step shown — mirrors `completeOnboarding()`
    /// exactly. Called from any of the step's three exits (connect / demo pump / skip), so all three
    /// dismiss the step equally (no confirmation, no extra tap).
    func completePumpOnboarding() {
        hasCompletedPumpOnboarding = true
        d.set(true, forKey: Self.pumpOnboardedKey)
    }

    private func raise(to mode: AppMode) {
        if mode > earnedMode {
            earnedMode = mode
            d.set(mode.rawValue, forKey: Self.earnedKey)
        }
        settings.appMode = mode   // activate the newly-earned mode
    }
}
