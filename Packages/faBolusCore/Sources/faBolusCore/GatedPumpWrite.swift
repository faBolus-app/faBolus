import Foundation

/// The authoritative, enumerated set of every consequential pump-**write** entry point reachable through
/// `AppModel`, each tagged with the access gate it currently routes through. This is the declared set for
/// the single policy evaluator: every (surface × action) pair against this list, so no consequential
/// action can exist without a decided gate. `PumpWriteFunnelGuardTests` is the standing source-text proof
/// that every `source.<name>(` write in `AppModel.swift` is one of this set's reachable entry points, so
/// the enum and `AppModel`'s actual write surface cannot silently drift apart.
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

    // Child-mode + phone read-only interlock (`runControl`) — the remaining insulin-affecting /
    // operational writes reachable through AppModel: suspend/resume delivery, and the pump clock
    // sync (held together with its own capability + backend implementations, which must be removed
    // in the same commit as this case — see `hasRequiredCapability`).
    case suspendDelivery, resumeDelivery
    case syncTimeToNow

    /// The access gate an action currently routes through in `AppModel`.
    public enum Gate: String, Sendable, CaseIterable {
        case ledgeredDelivery  // runLedgeredDelivery: durable idempotency + global delivery block
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
        default: return .advancedControl  // every other .controlInterlock write
        }
    }

    /// Whether the connected pump's capability set permits this action. Capabilities are
    /// pump-derived (`PumpCapabilities.derive` reads the pump's own feature bitmask); the bitmask's
    /// own input is a BLE-name substring match, with an `ApiVersionResponse` fallback on the wire —
    /// the accepted residual is a pump whose model can't be read from either signal.
    ///
    /// The advanced-control writes require any advanced capability (`supportsAnyAdvancedControl`) —
    /// preserving today's coarse check exactly, except `syncTimeToNow`'s own dedicated capability below.
    /// Delivery and the child-only pair require no capability (Gate 5 stays a no-op for them).
    public func hasRequiredCapability(in caps: PumpCapabilities) -> Bool {
        if self == .syncTimeToNow { return caps.supportsTimeSync }
        switch gate {
        case .controlInterlock: return caps.supportsAnyAdvancedControl
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
    ///   - `.advanced` — everything else: time sync, extended (combo) bolus.
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
