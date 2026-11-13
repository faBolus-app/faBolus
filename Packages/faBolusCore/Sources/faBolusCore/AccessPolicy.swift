import Foundation

/// Single access-policy evaluator: whether a `GatedPumpWrite` is permitted from a `Surface`.
/// Folds phone/remote read-only, the remote bolus settings and pump capabilities into one ordered check.
/// It is the only gate: every dose reaches it through `DoseComposer`, so a remote bridge has no check of
/// its own and a surface can't be gated on one layer and open on another. Pure over `AccessContext` —
/// faBolusCore must not read app globals.
///
/// `remotesReadOnly` governs all remotes. Pump capability is enforced at this funnel, not only in
/// the UI.
public enum AccessPolicy {

    /// Where an action originates. Determines which read-only flag applies.
    public enum Surface: String, CaseIterable, Sendable {
        case phoneUI  // this phone
        case garmin  // paired remote governed by remotesReadOnly
        /// The Live Activity's buttons. They run in the app's process, but they are reached from the Lock
        /// Screen and from the devices iOS mirrors the Live Activity to, away from the app's own screens and
        /// prompts, so they are a remote: read-only with the remotes, behind their own opt-in, under the
        /// remote size limit.
        case liveActivity

        /// Local surfaces are subject to `phoneReadOnly`.
        public var isLocal: Bool { self == .phoneUI }
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
        /// Bolusing from the Live Activity, off by default like the watch's. Only consulted for a delivery
        /// from `.liveActivity`.
        public var liveActivityBolusEnabled: Bool

        public init(
            phoneReadOnly: Bool, remotesReadOnly: Bool,
            capabilities: PumpCapabilities,
            // Fail-closed default: a caller that forgets to thread the per-surface remote
            // bolus enable must NOT silently arm Garmin bolusing. The one production call site
            // (AppModel) always passes the real persisted value; this default only guards a future
            // second call site.
            garminBolusEnabled: Bool = false,
            // The same for the Live Activity.
            liveActivityBolusEnabled: Bool = false
        ) {
            self.phoneReadOnly = phoneReadOnly
            self.remotesReadOnly = remotesReadOnly
            self.capabilities = capabilities
            self.garminBolusEnabled = garminBolusEnabled
            self.liveActivityBolusEnabled = liveActivityBolusEnabled
        }
    }

    /// Why an action was denied. `userMessage` is the string the app surfaces in `lastError`.
    public enum DenialReason: Sendable, Equatable {
        case phoneReadOnly
        case remotesReadOnly
        case capabilityUnavailable
        case remoteBolusDisabled  // bolusing from this remote is turned off

        public var userMessage: String {
            switch self {
            case .phoneReadOnly: return "This action is disabled — the app is in read-only mode."
            case .remotesReadOnly: return "Remote control is turned off — remotes are read-only."
            case .capabilityUnavailable: return "This pump doesn't support that action."
            case .remoteBolusDisabled:
                return "Bolusing from this device is turned off — enable it in faBolus on the phone."
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
        // Every other action: local ⇒ phoneReadOnly, remote ⇒ remotesReadOnly, the Live Activity ⇒ both.
        if action.gate != .alwaysAllowed {
            if surface.isLocal && context.phoneReadOnly { return .deny(.phoneReadOnly) }
            if surface.isRemote && context.remotesReadOnly { return .deny(.remotesReadOnly) }
            // The Live Activity is a remote drawn on this phone's own Lock Screen: the phone's read-only
            // stops it too, so neither switch can be undone by the other.
            if surface == .liveActivity && context.phoneReadOnly { return .deny(.phoneReadOnly) }
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
            if surface == .liveActivity && !context.liveActivityBolusEnabled { return .deny(.remoteBolusDisabled) }
        }

        // Pump capability, enforced at the funnel and not only in the UI: only a model that can take a
        // dose receives one, and an action never needs a capability to be cancelled or dismissed.
        if !action.hasRequiredCapability(in: context.capabilities) {
            return .deny(.capabilityUnavailable)
        }

        return .allow
    }
}
