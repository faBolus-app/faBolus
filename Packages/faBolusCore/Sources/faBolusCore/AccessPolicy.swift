import Foundation

/// Single access-policy evaluator: whether a `GatedPumpWrite` is permitted from a `Surface`.
/// Folds phone/remote read-only, the remote bolus settings and pump capabilities into one ordered check.
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
        case garmin  // paired remote governed by remotesReadOnly

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

    /// Everything the evaluator needs, snapshotted by the app from `AppSettings` / the backend. Pure
    /// data — no globals, no side effects.
    public struct AccessContext: Sendable {
        // Read-only
        public var phoneReadOnly: Bool
        public var remotesReadOnly: Bool
        // Pump capability: the connected model's capability set, never a raw model check.
        public var capabilities: PumpCapabilities
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
            phoneReadOnly: Bool, remotesReadOnly: Bool,
            capabilities: PumpCapabilities,
            // Fail-closed default: a caller that forgets to thread the per-surface remote
            // bolus enable must NOT silently arm Garmin bolusing. The one production call site
            // (AppModel) always passes the real persisted value; this default only guards a future
            // second call site.
            garminBolusEnabled: Bool = false,
            // Fail-closed defaults: `required=false` (no passcode ⇒ no extra gate, today's
            // behavior) but `satisfied=false`, so a required-but-unsatisfied pair always denies.
            bolusPasscodeRequired: Bool = false, bolusPasscodeSatisfied: Bool = false
        ) {
            self.phoneReadOnly = phoneReadOnly
            self.remotesReadOnly = remotesReadOnly
            self.capabilities = capabilities
            self.garminBolusEnabled = garminBolusEnabled
            self.bolusPasscodeRequired = bolusPasscodeRequired
            self.bolusPasscodeSatisfied = bolusPasscodeSatisfied
        }
    }

    /// Why an action was denied. `userMessage` is the string the app surfaces in `lastError`.
    public enum DenialReason: Sendable, Equatable {
        case phoneReadOnly
        case remotesReadOnly
        case capabilityUnavailable
        case remoteBolusDisabled  // bolusing from this remote is turned off
        case remoteBolusPasscodeRequired  // Garmin bolus needs the correct passcode

        public var userMessage: String {
            switch self {
            case .phoneReadOnly: return "This action is disabled — the app is in read-only mode."
            case .remotesReadOnly: return "Remote control is turned off — remotes are read-only."
            case .capabilityUnavailable: return "This pump doesn't support that action."
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
        // Read-only. `.alwaysAllowed` actions (cancel bolus, dismiss alert) are never read-only-blocked:
        // cancelling is a safety stop that must stay available, and clearing an alert is low-risk.
        // Every other action: local ⇒ phoneReadOnly, remote ⇒ remotesReadOnly.
        if action.gate != .alwaysAllowed {
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

        // Pump capability, enforced at the funnel and not only in the UI: only a model that can take a
        // dose receives one, and an action never needs a capability to be cancelled or dismissed.
        if !action.hasRequiredCapability(in: context.capabilities) {
            return .deny(.capabilityUnavailable)
        }

        return .allow
    }
}
