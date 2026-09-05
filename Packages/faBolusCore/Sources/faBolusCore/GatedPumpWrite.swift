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
/// pure reads (`refresh*`, `reconcile`), which mutate nothing.
public enum GatedPumpWrite: String, CaseIterable, Sendable {
    // Delivery — durable idempotency ledger + global delivery block (`runLedgeredDelivery`).
    case deliverBolus, deliverExtendedBolus

    // Child-mode ONLY — signed writes gated by child mode but deliberately NOT read-only-blocked:
    // cancelling is a safety STOP that must stay available to a read-only viewer, and clearing an alert is
    // low-risk. `BolusGate` formally reviews `cancelBolus`; recorded here so the gap isn't lost.
    case cancelBolus, dismissNotification

    // Unverified-therapy acknowledgment (`runGatedTherapy`) — IDP-CRUD + CGM-high/low, plus the
    // therapy-defining Control-IQ / max-bolus / max-basal writes (those change how the pump doses).
    case createProfile, setActiveProfile, renameProfile, deleteProfile
    case addProfileSegment, modifyProfileSegment, deleteProfileSegment, setCgmHighLowAlert
    case setControlIQ, setMaxBolus, setMaxBasal
    // The Mobi native Sleep-schedule WRITE. `flag`'s semantic meaning is undocumented and
    // only slot-0 writes were ever captured (slots 1-3 unobserved), so this stays ack-gated like the
    // other unverified-hardware writes above, even though it is NOT itself insulin-affecting.
    case setSleepSchedule

    // Child-mode + phone read-only interlock (`runControl`) — the remaining insulin-affecting /
    // operational writes reachable through AppModel: suspend/resume delivery, and the pump clock
    // sync (held together with its own capability + backend implementations, which must be removed
    // in the same commit as this case — see `hasRequiredCapability`).
    case suspendDelivery, resumeDelivery
    case syncTimeToNow

    /// The access gate an action currently routes through in `AppModel`.
    public enum Gate: String, Sendable, CaseIterable {
        case ledgeredDelivery  // runLedgeredDelivery: durable idempotency + global delivery block
        case unverifiedAck  // runGatedTherapy: one-shot untested-feature ack (wraps runControl)
        case controlInterlock  // runControl: child-mode + phone read-only
        case childOnly  // child-mode only (NOT read-only) — see the note above
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
            // Control-IQ config, max bolus, and max basal change how the pump doses, so they must be
            // ack-covered like IDP CRUD.
            .setControlIQ, .setMaxBolus, .setMaxBasal,
            // setSleepSchedule — flag semantics + slots 1-3 are unverified on hardware, so
            // it needs the same one-shot untested-feature ack as the other unverified writes above.
            .setSleepSchedule:
            return .unverifiedAck
        case .suspendDelivery, .resumeDelivery, .syncTimeToNow:
            return .controlInterlock
        }
    }

    // MARK: - Evaluator maps (single AccessPolicy). Defaults are the most-restrictive/fail-safe choice,
    // so a newly-added case is never accidentally *less* gated than intended.

    /// The child-mode feature this action requires. New control/ack cases default to `.advancedControl`
    /// (the strictest child gate) — fail-safe.
    public var requiredChildFeature: ChildFeature {
        switch self {
        case .deliverBolus, .deliverExtendedBolus: return .bolus
        case .cancelBolus: return .cancelBolus
        case .dismissNotification: return .dismissAlerts
        default: return .advancedControl  // every .controlInterlock / .unverifiedAck write
        }
    }

    /// Whether the connected pump's capability set permits this action. Capabilities are
    /// pump-derived (`PumpCapabilities.derive` reads the pump's own feature bitmask); the bitmask's
    /// own input is a BLE-name substring match, with an `ApiVersionResponse` fallback on the wire —
    /// the accepted residual is a pump whose model can't be read from either signal.
    ///
    /// The advanced-control writes require any advanced capability (`supportsAnyAdvancedControl`) —
    /// preserving today's coarse check exactly, EXCEPT for the two limit-set writes below. A finer
    /// per-action mapping is deferred so this stays behavior-preserving on every other reachable path.
    /// Delivery and the child-only pair require no capability (Gate 5 stays a no-op for them).
    public func hasRequiredCapability(in caps: PumpCapabilities) -> Bool {
        if self == .syncTimeToNow { return caps.supportsTimeSync }
        // The write's Mobi-only gate MIRRORS the pump protocol's own device scope — upstream
        // `SetSleepScheduleRequest.java`/`SetSleepScheduleResponse.java` are annotated
        // `supportedDevices=MOBI_ONLY, minApi=MOBI_API_V3_5`, identical to `SetTempRateRequest.java`. The
        // Swift port merely dropped those `MessageProps` annotation fields; this per-action arm is the
        // app-side equivalent, keyed on its own dedicated capability (not the coarse advanced-control set).
        if self == .setSleepSchedule { return caps.supportsSleepScheduleWrite }
        // `.setMaxBolus`/`.setMaxBasal` key on the dedicated `supportsLimits` bit rather than the coarse
        // advanced-control set, since a pump could plausibly advertise some other advanced capability
        // (e.g. Control-IQ settings) without also exposing the basal/bolus-limit feature. Not reachable
        // via shipped UI today (the UI already gates the limits editor on `supportsLimits`); this closes
        // the narrow backend access-control gap as defense-in-depth.
        if self == .setMaxBolus || self == .setMaxBasal { return caps.supportsLimits }
        switch gate {
        case .controlInterlock, .unverifiedAck: return caps.supportsAnyAdvancedControl
        case .ledgeredDelivery, .childOnly: return true
        }
    }

    /// The **mode axis**: the minimum `AppMode` at which this action is available. The evaluator's mode
    /// gate denies when the active mode ranks below this (`.childOnly` STOPs excepted). The default is
    /// `.advanced` — the strictest, fail-safe choice, so a newly-added case is never accidentally
    /// reachable in a lower mode than intended. Only the genuinely-Simple/Standard actions are classified
    /// explicitly:
    ///   - `.simple`   — bolus is the core function; cancel/dismiss are STOPs (their gate is carved out, so
    ///                   this value is only a fail-safe should the carve-out ever change).
    ///   - `.standard` — routine pump control that isn't full "advanced" (suspend/resume).
    ///   - `.advanced` — everything else: IDP/profile CRUD, max bolus/basal, time sync, Control-IQ
    ///                   settings, extended (combo) bolus.
    public var requiredMode: AppMode {
        switch self {
        case .deliverBolus, .cancelBolus, .dismissNotification:
            return .simple
        case .suspendDelivery, .resumeDelivery:
            return .standard
        default:
            return .advanced
        }
    }
}
