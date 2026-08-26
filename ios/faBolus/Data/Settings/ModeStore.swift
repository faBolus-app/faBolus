import Foundation
import faBolusCore
import Observation

/// P14 Slice 3 — originally the mode state machine (an earned ceiling + a guided sequential unlock + an
/// expert opt-out). Phase 8 (08-01, LOCK-01), tightened by the CR-01 gap-closure (08-REVIEW.md): narrow
/// `main` is advanced-only — `init` unconditionally forces `AppSettings.appMode` to `.advanced` on EVERY
/// launch, first-run or returning, regardless of any "modeEarned" value a pre-Phase-8 build may have
/// persisted. `ModeViews.swift` (the only UI that could ever select/raise a mode) is deleted, so there is
/// no live UI path that can move `appMode` away from `.advanced`.
///
/// 17-07 (D1-02): the guided-unlock machinery (`completeNextObjective`/`expertOptOutToAdvanced`/`select`/
/// `returnTo`/`earnedMode`/the `"modeEarned"` UserDefaults key) that stayed compiled-but-unreachable per
/// 08-OWNER-FLAGS.md Flag 1 is removed outright — it can never fire (no selection UI exists) and its
/// clamp-to-ceiling logic has no live caller. `AppSettings.appMode` — the field the single access
/// evaluator (`AccessPolicy`) reads — is untouched: this store remains its sole sanctioned writer and
/// still forces `.advanced` on every launch.
///
/// What remains is the first-run onboarding-completion tracker: `hasCompletedOnboarding` (forced `true`
/// — the Simple-mode first-run overlay is deleted, so there is nothing left to gate on it) and
/// `hasCompletedPumpOnboarding` (Phase 09.4, D-01 — the still-live "Connect your pump" first-run step,
/// gated in `RootContainerView`).
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

    /// Whether the first-run mode onboarding has been shown (so it appears exactly once).
    private(set) var hasCompletedOnboarding: Bool
    /// Phase 09.4 (D-01): whether the first-run "Connect your pump" step has been shown (so it appears
    /// exactly once, mirroring `hasCompletedOnboarding` above). Gated in `RootContainerView` alongside
    /// `!model.hasStoredPairing` so it never reappears once a pump is paired.
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
        // Phase 8 (08-01, LOCK-01): `hasCompletedOnboarding` is force-set `true` unconditionally — the
        // Simple-mode first-run overlay (`ModeOnboardingView`) is deleted this phase, so there is
        // nothing left to gate on it. Forcing it true (rather than editing `RootContainerView`'s gate)
        // keeps the KEPT `ConnectPumpOnboardingView` step's `&&` condition trivially satisfied without
        // touching that file's logic at all (Pitfall 3, RESEARCH option (a)).
        hasCompletedOnboarding = true
        hasCompletedPumpOnboarding = d.object(forKey: Self.pumpOnboardedKey) as? Bool ?? false
        // CR-01 gap-closure (08-REVIEW.md), tightening Phase 8 (08-01, LOCK-01): force the active mode
        // to `.advanced` on EVERY launch — first-run OR returning — never reading (and so never clamping
        // down to) whatever "modeEarned" a pre-Phase-8 build may have persisted. `ModeViews.swift` (the
        // only UI that could ever raise the mode back to Advanced) is deleted, so a device carrying a
        // stale sub-.advanced value would otherwise be PERMANENTLY stranded below Advanced with zero
        // recovery UI — silently losing `GatedPumpWrite`-gated pump-control functionality. Narrow `main`
        // is a single-adult advanced t:slim X2 device (D-02); still does NOT read
        // `advancedControlEnabled` (no silent migration) — same posture as before. 17-07 (D1-02): the
        // earned-ceiling concept this used to clamp against (`earnedMode`, the `"modeEarned"` key) is
        // removed — there is no public way to move `appMode` away from `.advanced` anymore, so nothing
        // is left to clamp.
        settings.appMode = .advanced
    }

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
}
