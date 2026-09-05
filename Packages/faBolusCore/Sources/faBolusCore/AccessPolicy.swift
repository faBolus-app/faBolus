import Foundation

/// Single access-policy evaluator: whether a `GatedPumpWrite` is permitted from a `Surface`.
/// Folds child mode, phone/remote read-only, pump capabilities, and modes into one ordered check.
/// Every funnel (`runControl`, `runLedgeredDelivery`, remote hosts) must go through this so a
/// surface cannot be gated on one layer and open on another. Pure over `AccessContext` —
/// faBolusCore must not read app globals.
///
/// `remotesReadOnly` governs all remotes. Pump capability is enforced at this funnel, not only in
/// the UI.
public enum AccessPolicy {

    /// Where an action originates. Determines which read-only flag applies.
    public enum Surface: String, CaseIterable, Sendable {
        case phoneUI, quickBolusWidget, siriShortcuts  // local (this phone)
        case garmin  // paired remote governed by remotesReadOnly + child

        /// Local surfaces are subject to `phoneReadOnly`.
        public var isLocal: Bool {
            switch self {
            case .phoneUI, .quickBolusWidget, .siriShortcuts: return true
            default: return false
            }
        }
        /// Any non-local surface is a remote and is subject to `remotesReadOnly`.
        public var isRemote: Bool { !isLocal }
    }

    /// The mode axis, folded in as one more input to the one evaluator (NOT a sixth mechanism).
    /// Carries the active experience mode and the per-feature toggles the user set within it.
    /// `evaluate` gains exactly one ordered `.modeDisallowed` / `.featureDisabledInMode` check at the
    /// reserved slot; no surface or funnel signature changes.
    ///
    /// The default is `.advanced` with no toggles — a **no-op**: Advanced sees every action, so an app
    /// that has not yet wired a real mode source (or a caller that omits `modeContext`) behaves exactly as
    /// before. A real mode store must ship together with the unlock path, so `main` never has a
    /// Simple-with-no-way-out window.
    public struct ModeGateContext: Sendable, Equatable {
        /// The active experience mode. Higher modes see strictly more (see `AppMode`'s ordering).
        public var activeMode: AppMode
        /// Features the user has explicitly turned off inside their current mode — finer-grained control
        /// than the mode alone. Empty ⇒ no per-feature restriction. Never populated by a safety STOP
        /// (see `evaluate`'s carve-out).
        public var disabledFeatures: Set<GatedPumpWrite>
        public init(activeMode: AppMode = .advanced, disabledFeatures: Set<GatedPumpWrite> = []) {
            self.activeMode = activeMode
            self.disabledFeatures = disabledFeatures
        }
    }

    /// Everything the evaluator needs, snapshotted by the app from `AppSettings` / the backend. Pure
    /// data — no globals, no side effects.
    public struct AccessContext: Sendable {
        // Gate 2 — child mode
        public var childModeEnabled: Bool
        public var childAllowed: Set<ChildFeature>
        // Gate 3 — read-only
        public var phoneReadOnly: Bool
        public var remotesReadOnly: Bool
        // Gate 5 — pump capability. Capabilities are pump-derived (from the pump's own feature
        // bitmask) and are the sole capability signal — not a raw `isMobi` check.
        public var capabilities: PumpCapabilities
        // Mode seam
        public var modeContext: ModeGateContext
        // Per-surface remote bolus authorization (default true so no OTHER surface/action is
        // affected; the host passes the real default-OFF settings). Only consulted for `.deliverBolus`
        // from `.garmin`.
        public var garminBolusEnabled: Bool
        // The OPTIONAL Garmin bolus passcode. When a passcode is set on the phone
        // (`BolusPasscodeStore.isRequired`), a Garmin `.deliverBolus` must carry the correct entered code.
        // The host does the single stateful `verify()` (which arms the exp-backoff) and hands the evaluator
        // a pure `required`/`satisfied` pair — faBolusCore never touches the Keychain. `satisfied` defaults
        // FALSE (fail-closed: required-but-unthreaded denies); `required` defaults false so no other
        // surface/action is affected. Only consulted for `.deliverBolus` from `.garmin`.
        public var bolusPasscodeRequired: Bool
        public var bolusPasscodeSatisfied: Bool

        public init(
            childModeEnabled: Bool, childAllowed: Set<ChildFeature>,
            phoneReadOnly: Bool, remotesReadOnly: Bool,
            capabilities: PumpCapabilities,
            modeContext: ModeGateContext = .init(),
            // Fail-closed default: a caller that forgets to thread the per-surface remote
            // bolus enable must NOT silently arm Garmin bolusing. The one production call site
            // (AppModel) always passes the real persisted value; this default only guards a future
            // second call site.
            garminBolusEnabled: Bool = false,
            // Fail-closed defaults: `required=false` (no passcode ⇒ no extra gate, today's
            // behavior) but `satisfied=false`, so a required-but-unsatisfied pair always denies.
            bolusPasscodeRequired: Bool = false, bolusPasscodeSatisfied: Bool = false
        ) {
            self.childModeEnabled = childModeEnabled
            self.childAllowed = childAllowed
            self.phoneReadOnly = phoneReadOnly
            self.remotesReadOnly = remotesReadOnly
            self.capabilities = capabilities
            self.modeContext = modeContext
            self.garminBolusEnabled = garminBolusEnabled
            self.bolusPasscodeRequired = bolusPasscodeRequired
            self.bolusPasscodeSatisfied = bolusPasscodeSatisfied
        }
    }

    /// Why an action was denied. `userMessage` is the string the app surfaces in `lastError`.
    public enum DenialReason: Sendable, Equatable {
        case childLocked(ChildFeature)
        case phoneReadOnly
        case remotesReadOnly
        case capabilityUnavailable
        case modeDisallowed(required: AppMode)  // feature not in the active mode
        case featureDisabledInMode  // user turned this feature off within the mode
        case remoteBolusDisabled  // bolusing from this remote is turned off
        case remoteBolusPasscodeRequired  // Garmin bolus needs the correct passcode

        public var userMessage: String {
            switch self {
            case .childLocked(let f): return "Locked (child mode): \(f.label.lowercased()) is disabled."
            case .phoneReadOnly: return "This action is disabled — the app is in read-only mode."
            case .remotesReadOnly: return "Remote control is turned off — remotes are read-only."
            case .capabilityUnavailable: return "This pump doesn't support that action."
            case .modeDisallowed(let m): return "Not available in your current mode — needs \(m.title) mode."
            case .featureDisabledInMode: return "This feature is turned off in your settings."
            case .remoteBolusDisabled:
                return "Bolusing from this device is turned off — enable it in faBolus on the phone."
            case .remoteBolusPasscodeRequired:
                return "Enter the bolus passcode set in faBolus on your phone to bolus from this device."
            }
        }
    }

    public struct AccessDecision: Sendable, Equatable {
        public let allowed: Bool
        public let reason: DenialReason?  // nil ⇔ allowed
        public init(allowed: Bool, reason: DenialReason?) {
            self.allowed = allowed
            self.reason = reason
        }
        public static let allow = AccessDecision(allowed: true, reason: nil)
        public static func deny(_ r: DenialReason) -> AccessDecision { .init(allowed: false, reason: r) }
    }

    /// The single decision. **Fail-closed**: any gate that isn't satisfied denies. Ordering reproduces
    /// today's precedence and messages.
    public static func evaluate(
        _ action: GatedPumpWrite,
        surface: Surface,
        context: AccessContext
    ) -> AccessDecision {
        // Gate 2 — child mode. Local + Garmin surfaces are subject to it.
        if context.childModeEnabled {
            if !context.childAllowed.contains(action.requiredChildFeature) {
                return .deny(.childLocked(action.requiredChildFeature))
            }
        }

        // Gate 3 — read-only. CARVE-OUT: `.childOnly` actions (cancel bolus, dismiss alert) are never
        // read-only-blocked — cancelling is a safety STOP that must stay available, and clearing an alert
        // is low-risk. Every other action: local ⇒ phoneReadOnly, remote ⇒ remotesReadOnly.
        if action.gate != .childOnly {
            if surface.isLocal && context.phoneReadOnly { return .deny(.phoneReadOnly) }
            if surface.isRemote && context.remotesReadOnly { return .deny(.remotesReadOnly) }
        }

        // Per-surface remote bolus authorization. Bolusing from Garmin is an explicit, default-OFF
        // opt-in on the phone, INDEPENDENT of `remotesReadOnly` (which already denied above if set).
        // Only the actual deliver from that paired remote is gated — every other surface/action is
        // unaffected. Fail-closed: a phone that never enabled the surface denies here regardless of
        // what the remote UI showed.
        // Gate BOTH ledgered deliveries (normal AND extended bolus). Keying on `.deliverBolus`
        // alone left `.deliverExtendedBolus` from a paired remote ungated by the per-surface enable —
        // latent today (extended bolus isn't Garmin-reachable) but exactly the drift this single
        // evaluator exists to prevent.
        if action == .deliverBolus || action == .deliverExtendedBolus {
            if surface == .garmin && !context.garminBolusEnabled { return .deny(.remoteBolusDisabled) }
        }

        // The OPTIONAL Garmin bolus passcode. When a passcode is set on the phone, a Garmin
        // `.deliverBolus` must carry the correct entered code (the host verifies it against the salted hash
        // and passes the result as `bolusPasscodeSatisfied`; the evaluator stays pure). Fail-closed:
        // required-but-unsatisfied (absent OR wrong OR backing off) denies. Every other surface/action is
        // unaffected (`required` defaults false). Ordered after the enable gate so "bolusing off" still
        // takes precedence over "needs a passcode".
        if (action == .deliverBolus || action == .deliverExtendedBolus) && surface == .garmin
            && context.bolusPasscodeRequired && !context.bolusPasscodeSatisfied
        {
            return .deny(.remoteBolusPasscodeRequired)
        }

        // Gate 5 — pump capability, enforced at the funnel. One axis: the capability set is
        // driver-derived from the connected pump's own feature bitmask (`PumpCapabilities.derive`),
        // whose own input is a BLE-name substring match with an `ApiVersionResponse` fallback on the
        // wire. `syncTimeToNow` needs `supportsTimeSync`; delivery + childOnly require no capability,
        // so Gate 5 stays a no-op there.
        if !action.hasRequiredCapability(in: context.capabilities) {
            return .deny(.capabilityUnavailable)
        }

        // Mode gate: one ordered input, evaluated last so an earlier gate's precedence and message are
        // unchanged. CARVE-OUT: a mode NEVER restricts a safety STOP. `.childOnly` (cancel bolus /
        // dismiss alert) is skipped here exactly as Gate 3 skips it — otherwise Simple mode would
        // silently disable a cancel. The default context is `.advanced` with no toggles, so this is a
        // no-op until a real active mode is supplied.
        if action.gate != .childOnly {
            if context.modeContext.activeMode < action.requiredMode {
                return .deny(.modeDisallowed(required: action.requiredMode))
            }
            if context.modeContext.disabledFeatures.contains(action) {
                return .deny(.featureDisabledInMode)
            }
        }

        return .allow
    }
}
