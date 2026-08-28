import Foundation

/// The authoritative, enumerated set of every consequential pump-**write** entry point reachable through
/// `AppModel`, each tagged with the access gate it currently routes through. This is the declared set for
/// the single policy evaluator: every (surface × action) pair against this list, so no consequential
/// action can exist without a decided gate, and `everyTherapyWriteEntryPointIsCentrallyGated` derives
/// its ack-gated coverage from it (so the test and the declared set cannot silently drift).
///
/// `rawValue` is the `AppModel` method name. This records the **current** routing, not an aspiration —
/// where the present gate is weaker than one might expect it is called out below, not hidden.
///
/// **Not included:** `setPumpSounds` — a signed `PumpBackend` method with **no `AppModel` entry point**
/// today (nothing surfaces it, so it is not a reachable action; add a case when it is surfaced) — and the
/// pure reads (`refresh*`, `reconcile`, `readG6TransmitterId`), which mutate nothing.
public enum GatedPumpWrite: String, CaseIterable, Sendable {
    // Delivery — durable idempotency ledger + global delivery block (`runLedgeredDelivery`).
    case deliverBolus, deliverExtendedBolus

    // Child-mode ONLY — signed writes gated by child mode but deliberately NOT read-only-blocked:
    // cancelling is a safety STOP that must stay available to a read-only viewer, and clearing an alert is
    // low-risk. `BolusGate` formally reviews `cancelBolus`; recorded here so the gap isn't lost.
    case cancelBolus, dismissNotification

    // Unverified-therapy acknowledgment (`runGatedTherapy`) — IDP-CRUD + CGM-high/low, plus (P14 S6) the
    // therapy-defining Control-IQ / max-bolus / max-basal writes that previously bypassed the ack.
    case createProfile, setActiveProfile, renameProfile, deleteProfile
    case addProfileSegment, modifyProfileSegment, deleteProfileSegment, setCgmHighLowAlert
    case setControlIQ, setMaxBolus, setMaxBasal
    // The Mobi native Sleep-schedule WRITE. `flag`'s semantic meaning is undocumented and
    // only slot-0 writes were ever captured (slots 1-3 unobserved), so this stays ack-gated like the
    // other unverified-hardware writes above, even though it is NOT itself insulin-affecting (L7).
    case setSleepSchedule

    // Child-mode + phone read-only interlock (`runControl`) — the remaining insulin-affecting / operational
    // writes (suspend/resume, temp basal, modes, cartridge/fill, CGM session, clock, alert reminders).
    case suspendDelivery, resumeDelivery, setTempBasal, stopTempBasal, setMode, playFindMyPump
    case startG6Session, startG7Session, setSensorType, stopCgmSession
    case enterChangeCartridgeMode, exitChangeCartridgeMode, enterFillTubingMode, exitFillTubingMode, fillCannula
    case syncTimeToNow
    case setLowInsulinAlert, setAutoOffAlert, setSiteChangeReminder, setAlertSnooze
    case setCgmOutOfRangeAlert, setCgmRiseFallAlert

    /// The access gate an action currently routes through in `AppModel`.
    public enum Gate: String, Sendable, CaseIterable {
        case ledgeredDelivery   // runLedgeredDelivery: durable idempotency + global delivery block
        case unverifiedAck      // runGatedTherapy: one-shot untested-feature ack (wraps runControl)
        case controlInterlock   // runControl: child-mode + phone read-only
        case childOnly          // child-mode only (NOT read-only) — see the note above
    }

    /// The gate this action currently routes through. The `switch` is exhaustive, so adding a case without
    /// classifying it is a compile error — the enumeration and its gating cannot drift apart.
    public var gate: Gate {
        switch self {
        case .deliverBolus, .deliverExtendedBolus:
            return .ledgeredDelivery
        case .cancelBolus, .dismissNotification:
            return .childOnly
        case .createProfile, .setActiveProfile, .renameProfile, .deleteProfile,
             .addProfileSegment, .modifyProfileSegment, .deleteProfileSegment, .setCgmHighLowAlert,
             // The therapy-DEFINING writes that used to bypass the acknowledgment gate.
             // Control-IQ config, max bolus, and max basal change how the pump doses, so they must be
             // ack-covered like IDP CRUD. (The ack LIFETIME by tier — one-time clinician for these — is
             // S8's refinement; here they gain the same coverage the IDP writes have.)
             .setControlIQ, .setMaxBolus, .setMaxBasal,
             // setSleepSchedule — flag semantics + slots 1-3 are unverified on hardware, so
             // it needs the same one-shot untested-feature ack as the other unverified writes above.
             .setSleepSchedule:
            return .unverifiedAck
        case .suspendDelivery, .resumeDelivery, .setTempBasal, .stopTempBasal, .setMode, .playFindMyPump,
             .startG6Session, .startG7Session, .setSensorType, .stopCgmSession,
             .enterChangeCartridgeMode, .exitChangeCartridgeMode, .enterFillTubingMode, .exitFillTubingMode, .fillCannula,
             .syncTimeToNow,
             // Operational alert reminders are self-tier (no therapy-edit ack): they configure WHEN the
             // pump warns, not how it doses. `setCgmHighLowAlert` is the exception — a glucose threshold —
             // and stays ack-gated above. `syncTimeToNow` is a clock sync (its auto-path can't prompt).
             .setLowInsulinAlert, .setAutoOffAlert, .setSiteChangeReminder, .setAlertSnooze,
             .setCgmOutOfRangeAlert, .setCgmRiseFallAlert:
            return .controlInterlock
        }
    }

    // MARK: - Evaluator maps (single AccessPolicy). Defaults are the most-restrictive/fail-safe choice,
    // so a newly-added case is never accidentally *less* gated than intended.

    /// The child-mode feature this action requires (matches the `childBlocked(...)` argument each
    /// AppModel entry point passes today). New control/ack cases default to `.advancedControl` (the
    /// strictest child gate) — fail-safe.
    public var requiredChildFeature: ChildFeature {
        switch self {
        case .deliverBolus, .deliverExtendedBolus: return .bolus
        case .cancelBolus: return .cancelBolus
        case .dismissNotification: return .dismissAlerts
        default: return .advancedControl   // every .controlInterlock / .unverifiedAck write
        }
    }

    /// The peer permission an authenticated remote needs to drive this action (matches
    /// `PeerRemoteHost`'s current switch). `nil` = there is no remote verb for it, so a peer surface
    /// fails closed — fail-safe.
    public var requiredPeerPermission: RemotePermission? {
        switch self {
        case .deliverBolus: return .bolus
        case .deliverExtendedBolus: return .extendedBolus
        case .cancelBolus: return .cancelBolus
        case .dismissNotification: return .dismissAlerts
        case .suspendDelivery, .resumeDelivery: return .suspendResume
        default: return nil
        }
    }

    /// The **opt-in axis** (P13 split): whether this action needs the user's advanced-control opt-in
    /// (`advancedControlEnabled`) at the funnel. This is the former `requiresAdvancedControl`, unchanged
    /// — the set of writes the app reaches ONLY behind `advancedControlAllowed` (verified against the
    /// live UI 2026-08-05). Delivery (`.ledgeredDelivery`) and the child-only pair (`.childOnly`) never
    /// need the opt-in; neither does `syncTimeToNow` — it is reachable on a Mobi from Settings → "Pump
    /// clock" WITHOUT the opt-in, gated only by its own `supportsTimeSync` capability (see
    /// `hasRequiredCapability`). Requiring the opt-in for it would tighten shipped Mobi behavior.
    public var requiresAdvancedControlOptIn: Bool {
        if self == .syncTimeToNow { return false }
        switch gate {
        case .controlInterlock, .unverifiedAck: return true
        case .ledgeredDelivery, .childOnly: return false
        }
    }

    /// The **capability axis** (P13 split): whether the connected pump's capability set permits this
    /// action, independent of the opt-in. Splitting this out of `requiresAdvancedControl` removes the
    /// old hand-carved `if self == .syncTimeToNow` special-case — a Mobi-only-BY-CAPABILITY action can
    /// now declare its capability (`supportsTimeSync`) cleanly instead of masquerading as "not advanced".
    /// Capabilities are now pump-derived (P13-1 `PumpCapabilities.derive` reads the pump's own feature
    /// bitmask), so this axis no longer leans on `isMobi`.
    ///
    /// The advanced-control writes require any advanced capability (`supportsAnyAdvancedControl`) —
    /// preserving today's coarse check exactly, EXCEPT for the two limit-set writes below. A finer
    /// per-action mapping (e.g. `setMode → supportsModes`) is a deliberate follow-up, now feasible because
    /// P13-1 can produce non-uniform capability sets; it is deferred (still coarse) for the rest of the set
    /// so this increment stays behavior-preserving on every other reachable path. Delivery and the
    /// child-only pair require no capability (Gate 5 stays a no-op for them).
    public func hasRequiredCapability(in caps: PumpCapabilities) -> Bool {
        if self == .syncTimeToNow { return caps.supportsTimeSync }
        // The write's Mobi-only gate MIRRORS the pump protocol's own device scope — upstream
        // `SetSleepScheduleRequest.java`/`SetSleepScheduleResponse.java` are annotated
        // `supportedDevices=MOBI_ONLY, minApi=MOBI_API_V3_5`, identical to `SetTempRateRequest.java`. The
        // Swift port merely dropped those `MessageProps` annotation fields; this per-action arm is the
        // app-side equivalent, keyed on its own dedicated capability (not the coarse advanced-control set).
        if self == .setSleepSchedule { return caps.supportsSleepScheduleWrite }
        // The per-action refinement is now APPLIED for the two
        // limit-set writes — `.setMaxBolus`/`.setMaxBasal` key on the dedicated `supportsLimits` bit rather
        // than the coarse advanced-control set, since a pump could plausibly advertise some other advanced
        // capability (e.g. Control-IQ settings) without also exposing the basal/bolus-limit feature. Not
        // reachable via shipped UI today (the UI already gates the limits editor on `supportsLimits`); this
        // closes the narrow backend access-control gap as defense-in-depth.
        if self == .setMaxBolus || self == .setMaxBasal { return caps.supportsLimits }
        switch gate {
        case .controlInterlock, .unverifiedAck: return caps.supportsAnyAdvancedControl
        case .ledgeredDelivery, .childOnly: return true
        }
    }

    /// P14 (Slice 2) — the **mode axis**: the minimum `AppMode` at which this action is available. The
    /// evaluator's mode gate denies when the active mode ranks below this (`.childOnly` STOPs excepted).
    /// The default is `.advanced` — the strictest, fail-safe choice, so a newly-added case is never
    /// accidentally reachable in a lower mode than intended. Only the genuinely-Simple/Standard actions are
    /// classified explicitly:
    ///   - `.simple`   — bolus is the core function; cancel/dismiss are STOPs (their gate is carved out, so
    ///                   this value is only a fail-safe should the carve-out ever change).
    ///   - `.standard` — routine pump control that isn't full "advanced" (suspend/resume, activity modes,
    ///                   Find-My-Pump).
    ///   - `.advanced` — everything else: temp basal, IDP/profile CRUD, CGM-session control, cartridge/fill,
    ///                   max bolus/basal, time sync, Control-IQ settings, alert config, extended (combo) bolus.
    /// These are the initial conservative mapping; the S3 Objectives taxonomy refines them (owner review).
    public var requiredMode: AppMode {
        switch self {
        case .deliverBolus, .cancelBolus, .dismissNotification:
            return .simple
        case .suspendDelivery, .resumeDelivery, .setMode, .playFindMyPump:
            return .standard
        default:
            return .advanced
        }
    }
}
