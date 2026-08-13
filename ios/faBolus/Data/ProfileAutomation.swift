import Foundation
import faBolusCore

/// Headless Shortcuts entry point for activating a Personal Profile (999.2, D-02), mirroring
/// `TempRateAutomation`'s injectable-seam shape (06-01: `model`/`now`/`post`/`benchVerified`) but NOT its
/// gate-and-apply symmetry — this module has a structurally different ceiling.
///
/// **The `.unverifiedAck` gate (LOCKED, §13) — do NOT weaken.** `AppModel.setActiveProfile` routes
/// through `runGatedTherapy`, which requires `AccessPolicy`'s `.unverifiedAck` gate
/// (`GatedPumpWrite.swift:56-63` → `.unverifiedAck`; `AccessPolicy.swift:229-232`, UNCONDITIONAL, no
/// `.phoneUI`-only carve-out): a live, ≤120-second-old, IN-APP acknowledgment
/// (`AppModel.swift:1567-1577`, `hasRecentUnverifiedAck`/`acknowledgeUnverifiedTherapy`). A headless
/// Shortcuts run can NEVER produce that acknowledgment — proven for `setActiveProfile` specifically by
/// `everyTherapyWriteEntryPointIsCentrallyGated` (`AppModelBehaviorTests.swift:692-729`, `idpWriteCount
/// == 0` with no ack). The owner explicitly reviewed and REJECTED weakening this gate for automation
/// (§13) — so `ActivateProfileIntent` is **Shortcuts-discoverable but honestly, permanently refuses on
/// every headless call** (D-02, owner override to include the intent now, accepting this limitation
/// rather than a policy change). This module does NOT re-implement, pre-check, or carve out the ack gate
/// itself (no `context.hasRecentUnverifiedAck`-style duplicate check here, no new `GatedPumpWrite` case)
/// — it calls the EXACT SAME `AppModel.setActiveProfile(idpId:)` every interactive UI caller uses, and
/// reports whatever the single centralized evaluator decides via `model.lastError`. The only way this
/// intent ever completes a profile switch is a Shortcut that opens the app first and lets the user
/// interactively acknowledge — a plain unattended macro can never satisfy the ack, so this module also
/// does NOT build a queue-and-drain retry for it (06-RESEARCH Pitfall 2 / D-02): retrying a request that
/// can structurally never succeed headlessly would just be a slower way to do nothing.
@MainActor
enum ProfileAutomation {
    /// D-03 Phase-11 gate: the profile-activation saline-bench line — distinct from
    /// `TempRateAutomation.benchVerifiedDefault` (which tracks the separate temp-rate bench item). Ships
    /// `false` so the intent is functionally inert regardless of capability, mirroring the temp-rate
    /// pattern; flip only after that bench line passes.
    static let profileBenchVerifiedDefault = false

    /// Entry point for `ActivateProfileIntent`. Gate order: setting off → bench-unverified →
    /// capability-unsupported → call `AppModel.setActiveProfile` and report from `model.lastError`.
    /// There is no numeric cap for profile activation (CONTEXT.md defines none) and no manual-precedence
    /// defer / pump-ready queue — see the header for why. Returns a human-readable string for the
    /// intent's dialog.
    ///
    /// Injectable seams mirror `TempRateAutomation.request` (production callers pass none of them; tests
    /// inject a model + clock + a bench flag + a capturing poster).
    static func request(idpId: Int,
                        model: AppModel? = nil,
                        now: Date = Date(),
                        benchVerified: Bool = profileBenchVerifiedDefault,
                        post: ((NotificationBroker.Message) -> Void)? = nil) async -> String {
        let model = model ?? AppModel.shared
        let post = post ?? Self.livePost

        guard AppSettings.shared.autoProfileActivation else {
            return "Auto profile activation is turned off in faBolus."
        }
        // D-03: build-inert until the Phase-11 saline-bench line for profile activation passes —
        // regardless of capability, so the intent never touches the pump ahead of the bench.
        guard benchVerified else {
            return "Activating a profile from Shortcuts isn't available yet — it's pending saline-bench validation."
        }
        // `AppModel.shared` is `weak` — nil when no live model exists (the app process isn't up). There
        // is no queue to fall back on (see the header), so this is an honest refusal, not a silently
        // dropped request.
        guard let model else {
            remind(title: "Switch profiles on your pump",
                   body: "faBolus can't switch profiles right now — open the app first.",
                   now: now, post: post)
            return "faBolus can't switch profiles — open faBolus first."
        }
        // Fine-grained capability gate (999.3-style, 06-RESEARCH Pattern 4): the coarse Gate-5
        // `supportsAnyAdvancedControl` is too permissive here — mirrors `PumpControlView.swift:137`'s
        // `caps.supportsProfiles` section gate.
        guard model.capabilities.supportsProfiles else {
            return "This pump doesn't support switching profiles."
        }
        // Pass-through to the SAME centrally-gated write every interactive caller uses (`.unverifiedAck`,
        // AccessPolicy.swift:229-232). No new GatedPumpWrite case, no ack shortcut, no `.phoneUI`
        // carve-out. A headless run has no fresh in-app ack, so this fails closed WITHOUT reaching the
        // backend — the refusal below is the DESIGNED (D-02), not accidental, outcome of every
        // unattended macro run. It only succeeds when a fresh ack is already on record (the interactive
        // "open the app and confirm first" path).
        await model.setActiveProfile(idpId: idpId)
        if let err = model.lastError {
            return "faBolus didn't switch profiles automatically — open faBolus and confirm to switch profiles. (\(err))"
        }
        return "Profile switched on your pump."
    }

    private static func remind(title: String, body: String, now: Date,
                               post: (NotificationBroker.Message) -> Void) {
        guard AppSettings.shared.modeReminders else { return }
        // Routed through the broker like every other notification — a SUPPRESSIBLE `.info`/`.modeReminder`
        // message, never a never-suppressible safety alert.
        let msg = NotificationBroker.Message(
            category: .modeReminder, severity: .info, title: title, body: body,
            dedupeKey: "profileActivationReminder-\(title)",
            episodeKey: "profileActivationReminder-\(title)-\(now.timeIntervalSince1970)")
        post(msg)
    }

    /// The production poster: route through the broker's App-Group-backed runtime (works out-of-process,
    /// e.g. an App Intent while the app isn't live). Split out so tests can inject a capturing `post`.
    static func livePost(_ message: NotificationBroker.Message) {
        NotificationPoster.post(message, runtime: NotificationRuntime())
    }
}
