import Foundation
import faBolusCore

/// Headless Shortcuts entry point for setting a temporary basal rate (999.2, D-01), mirroring
/// `ModeAutomation`'s injectable-seam / gate-ordering shape (see that file's header) but deliberately
/// NOT its queue-and-drain persistence — see the no-queue decision below.
///
/// **D-04 REVISED (2026-08-13, owner)** — the safety envelope this module enforces is EXACTLY the range
/// the official Tandem Mobi app offers: `PumpControlBounds.tempRateMin/MaxPercent` (0-250%) and
/// `.tempRateMin/MaxMinutes` (15 min-72h) — the SAME firmware bounds the in-app manual slider
/// (`PumpControlView.swift:61-71`) already uses. faBolus mints NO cap of its own (the earlier plan to
/// mint a 150%/8h "clinician-tier" headless constant pair is REMOVED — it was an invented therapy
/// threshold, contrary to C3/C4). An out-of-range value is refused outright — never
/// clamped; `PumpControlBounds.clampTempRate*` exist but MUST NOT be called here. An in-range value is
/// passed straight through to `AppModel.setTempBasal`; the pump's OWN Basal Limit (Delivery Limits,
/// "Max Basal Alert 56T") is the real ceiling, surfaced honestly via `model.lastError` — faBolus is never
/// more restrictive than the official app.
///
/// **NO-QUEUE DECISION (Claude's discretion, 06-RESEARCH Pitfall 3):** unlike `ModeAutomation`'s
/// queue+15-min-TTL+drain-on-reconnect pattern (fine for an on/off mode switch), a temp rate is
/// time-boxed — draining a queued request several minutes late would apply the ORIGINALLY-requested
/// duration starting late, landing the wrong window (e.g. "150% for the next 60 minutes of my run"
/// landing with only 46 minutes of run left). So when the pump isn't ready, this module
/// REFUSES-AND-REMINDS instead of queuing: there is no pending store, no `applyPendingIfDue`, and no
/// drain-on-reconnect for temp rate.
///
/// **D-03a assumption/threat (firmware-version gap — do NOT overturn here):** current Tandem
/// Control-IQ+ docs say a temp rate CAN be set while Control-IQ+ is ON, but the repo's LOCKED constraint
/// (`.planning/intel/constraints.md:29`, from PumpX2Kit `TempRateRequests.swift`) says the pump rejects
/// temp-rate-while-CIQ-on. `AppModel.setTempBasal` already encodes the locked constraint as a pre-flight
/// refusal (`ControlIQPrecondition.tempRateBlockReason`) — this module does NOT add its own CIQ-off gate
/// (that would re-hardcode the locked constraint at a new layer and pre-empt the Phase-11 bench). It
/// simply passes the request through and reports whatever `setTempBasal` returns via `model.lastError`;
/// the build-inert bench gate below is where the CIQ+ discrepancy resolves on the bench.
@MainActor
enum TempRateAutomation {
    /// D-03 Phase-11 gate: the general "CIQ-off temp-rate write matches the pump's history log on
    /// saline" bench item (NOT SG3b/CIQ-on — see 06-RESEARCH Pitfall 5, which is a separate, still-open
    /// question about whether a temp rate can EVER be set while CIQ is ON). Flip to `true` only after
    /// that bench line passes. Ships `false` so the intent is functionally inert regardless of capability.
    static let benchVerifiedDefault = false

    /// Entry point for `SetTempRateIntent`. Evaluates gates in this fixed order so each case is
    /// deterministic: setting off → bench-unverified → capability-unsupported → firmware-range
    /// validation (refuse, never clamp) → P16-S3 manual precedence → pump-ready (apply) / not-ready
    /// (refuse-and-remind, no queue). Returns a human-readable string for the intent's dialog.
    ///
    /// Injectable seams mirror `ModeAutomation.request` (production callers pass none of them; tests
    /// inject a model + clock + a bench flag + a capturing poster).
    static func request(percent: Int, duration: Int,
                        model: AppModel? = nil,
                        now: Date = Date(),
                        benchVerified: Bool = benchVerifiedDefault,
                        post: ((NotificationBroker.Message) -> Void)? = nil) async -> String {
        let model = model ?? AppModel.shared
        let post = post ?? Self.livePost

        guard AppSettings.shared.autoTempRate else {
            return "Auto temp rate is turned off in faBolus."
        }
        // D-03: build-inert until the Phase-11 saline-bench line for a CIQ-off temp-rate write passes —
        // regardless of capability, so the intent never touches the pump ahead of the bench.
        guard benchVerified else {
            return "Setting a temp rate from Shortcuts isn't available yet — it's pending saline-bench validation."
        }
        // `AppModel.shared` is `weak` — nil when no live model exists (the app process isn't up). There
        // is no queue to fall back on (see the no-queue decision above), so this is an honest refusal,
        // not a silently-dropped request.
        guard let model else {
            remind(title: "Set temp rate on your pump",
                   body: "faBolus can't set a temp rate right now — open the app first.",
                   now: now, post: post)
            return "faBolus can't set the temp rate — open faBolus first."
        }
        // Fine-grained capability gate (999.3-style, 06-RESEARCH Pattern 4): the coarse Gate-5
        // `supportsAnyAdvancedControl` is too permissive here — mirrors `PumpControlView.swift:61`'s
        // `caps.supportsTempBasal` section gate.
        guard model.capabilities.supportsTempBasal else {
            return "This pump doesn't support setting a temp rate."
        }
        // D-04 REVISED — the firmware request bounds, mirroring the manual slider exactly. Refuse
        // outright on an out-of-range value; NEVER clamp into range (that would silently apply a
        // different request than the one asked for).
        guard percent >= PumpControlBounds.tempRateMinPercent, percent <= PumpControlBounds.tempRateMaxPercent else {
            return "Temp rate must be \(PumpControlBounds.tempRateMinPercent)-\(PumpControlBounds.tempRateMaxPercent)% "
                + "— faBolus didn't set it."
        }
        guard duration >= PumpControlBounds.tempRateMinMinutes, duration <= PumpControlBounds.tempRateMaxMinutes else {
            return "Temp rate duration must be \(PumpControlBounds.tempRateMinMinutes)-\(PumpControlBounds.tempRateMaxMinutes) minutes "
                + "— faBolus didn't set it."
        }
        // P16 S3: a scheduled/macro-driven temp rate must DEFER to a recent hands-on change — prompt,
        // don't silently apply. No queue (see the no-queue decision above): just a suppressible
        // informational reminder, mirroring `ModeAutomation`'s S3 handling in spirit.
        if ManualPrecedence.shouldDeferAutomation(lastManualActionAt: model.lastManualTherapyActionAt, now: now) {
            remind(title: "faBolus",
                   body: "A temp rate wasn't set automatically because you made a manual change recently. Open faBolus to set it.",
                   now: now, post: post)
            return "faBolus didn't set the temp rate automatically — you made a manual change recently. Open faBolus to set it."
        }
        guard model.pumpReady else {
            remind(title: "Set temp rate on your pump",
                   body: "faBolus can't set a temp rate right now — the pump isn't connected.",
                   now: now, post: post)
            return "faBolus can't set the temp rate — your pump isn't connected."
        }
        // Pass-through to the existing gated write (`.controlInterlock`, no ack, works headlessly). No
        // new `GatedPumpWrite` case (D-01). `setTempBasal` itself pre-flight-refuses on Control-IQ ON
        // (D-03a) — that precondition is NOT duplicated here.
        await model.setTempBasal(percent: percent, durationMinutes: duration)
        if let err = model.lastError { return "Couldn't set the temp rate: \(err)" }
        return "\(percent)% temp rate set for \(duration) minutes."
    }

    /// The production poster: route through the broker's App-Group-backed runtime (works out-of-process,
    /// e.g. an App Intent while the app isn't live). Split out so tests can inject a capturing `post`.
    static func livePost(_ message: NotificationBroker.Message) {
        NotificationPoster.post(message, runtime: NotificationRuntime())
    }

    private static func remind(title: String, body: String, now: Date,
                               post: (NotificationBroker.Message) -> Void) {
        guard AppSettings.shared.modeReminders else { return }
        // Routed through the broker like every other notification — a SUPPRESSIBLE `.info`/`.modeReminder`
        // message, never a never-suppressible safety alert.
        let msg = NotificationBroker.Message(
            category: .modeReminder, severity: .info, title: title, body: body,
            dedupeKey: "tempRateReminder-\(title)",
            episodeKey: "tempRateReminder-\(title)-\(now.timeIntervalSince1970)")
        post(msg)
    }
}
