import Foundation

/// **P8 — the single access-policy evaluator.** One pure decision point that resolves whether a given
/// `GatedPumpWrite` action is permitted from a given `Surface`, folding in the five gates that used to
/// live at five layers (unverified-feature ack, child mode, phone/remote read-only, per-peer permissions,
/// pump capabilities). Every funnel — `runControl`, `runGatedTherapy`, `runLedgeredDelivery`, and the
/// remote hosts — routes through this, so a surface can't be gated on one layer and open on another
/// (the shipped A-05 widget-bypass class of bug). It is a **pure function over `AccessContext`** because
/// faBolusCore must not read app globals; the app builds the context and reports the result.
///
/// Modes (P14) fold in as one more `AccessContext` field + one more ordered check here — NOT a sixth
/// mechanism at a sixth layer. That is the whole point of consolidating.
///
/// Owner decisions baked in (2026-08-05): `remotesReadOnly` governs **all** remotes including the
/// Mac/caregiver peer path (closing the hole where it was ignored there); the pump-capability +
/// advanced-control opt-in is enforced **at the funnel** (defense-in-depth), not only in the UI.
public enum AccessPolicy {

    /// Where an action originates. Determines which read-only flag applies and whether the child-lock
    /// bypass (an authenticated peer that passed its per-peer policy) is available.
    public enum Surface: String, CaseIterable, Sendable {
        case phoneUI, quickBolusWidget, siriShortcuts      // local (this phone)
        case appleWatch, garmin                            // paired remotes governed by remotesReadOnly + child
        case macPeer, caregiverPhonePeer                   // authenticated peers (per-peer policy)

        /// Local surfaces are subject to `phoneReadOnly`.
        public var isLocal: Bool {
            switch self { case .phoneUI, .quickBolusWidget, .siriShortcuts: return true; default: return false }
        }
        /// Any non-local surface is a remote and is subject to `remotesReadOnly`.
        public var isRemote: Bool { !isLocal }
        /// Authenticated peers carry a per-peer `RemotePeerPolicy` and bypass child-mode (they are a
        /// separately-authenticated controller) — exactly the old `enforceChildLock: false` path.
        public var isAuthenticatedPeer: Bool {
            switch self { case .macPeer, .caregiverPhonePeer: return true; default: return false }
        }
    }

    /// P14 seam. Empty today; when the mode system lands it carries the active mode + per-feature toggles,
    /// and `evaluate` gains one `.modeDisallowed` check. No surface/funnel change required.
    public struct ModeGateContext: Sendable, Equatable {
        public init() {}
    }

    /// Everything the evaluator needs, snapshotted by the app from `AppSettings` / the backend / the peer
    /// policy store. Pure data — no globals, no side effects.
    public struct AccessContext: Sendable {
        // Gate 2 — child mode
        public var childModeEnabled: Bool
        public var childAllowed: Set<ChildFeature>
        // Gate 3 — read-only
        public var phoneReadOnly: Bool
        public var remotesReadOnly: Bool
        // Gate 5 — pump capability + advanced-control opt-in. P13: `isMobi` retired — capabilities are
        // now pump-derived (from the pump's own feature bitmask) and are the sole capability signal.
        public var advancedControlOptIn: Bool
        public var capabilities: PumpCapabilities
        // Gate 1 — unverified-feature acknowledgment
        public var hasRecentUnverifiedAck: Bool
        // Gate 4 — per-peer policy (nil for a non-authenticated-peer surface)
        public var peerPolicy: RemotePeerPolicy?
        // P14 seam
        public var modeContext: ModeGateContext

        public init(childModeEnabled: Bool, childAllowed: Set<ChildFeature>,
                    phoneReadOnly: Bool, remotesReadOnly: Bool,
                    advancedControlOptIn: Bool, capabilities: PumpCapabilities,
                    hasRecentUnverifiedAck: Bool, peerPolicy: RemotePeerPolicy? = nil,
                    modeContext: ModeGateContext = .init()) {
            self.childModeEnabled = childModeEnabled
            self.childAllowed = childAllowed
            self.phoneReadOnly = phoneReadOnly
            self.remotesReadOnly = remotesReadOnly
            self.advancedControlOptIn = advancedControlOptIn
            self.capabilities = capabilities
            self.hasRecentUnverifiedAck = hasRecentUnverifiedAck
            self.peerPolicy = peerPolicy
            self.modeContext = modeContext
        }
    }

    /// Why an action was denied. `userMessage` is the string the app surfaces in `lastError`.
    public enum DenialReason: Sendable, Equatable {
        case notPermittedForPeer
        case childLocked(ChildFeature)
        case phoneReadOnly
        case remotesReadOnly
        case capabilityUnavailable
        case unverifiedAckRequired

        public var userMessage: String {
            switch self {
            case .notPermittedForPeer:  return "Not permitted for this remote."
            case .childLocked(let f):   return "Locked (child mode): \(f.label.lowercased()) is disabled."
            case .phoneReadOnly:        return "This action is disabled — the app is in read-only mode."
            case .remotesReadOnly:      return "Remote control is turned off — remotes are read-only."
            case .capabilityUnavailable: return "This pump doesn't support that action, or advanced control is off."
            case .unverifiedAckRequired: return "This needs the untested-feature warning acknowledged first."
            }
        }
    }

    public struct AccessDecision: Sendable, Equatable {
        public let allowed: Bool
        public let reason: DenialReason?   // nil ⇔ allowed
        public init(allowed: Bool, reason: DenialReason?) { self.allowed = allowed; self.reason = reason }
        public static let allow = AccessDecision(allowed: true, reason: nil)
        public static func deny(_ r: DenialReason) -> AccessDecision { .init(allowed: false, reason: r) }
    }

    /// The single decision. **Fail-closed**: any gate that isn't satisfied denies; a peer with no verb for
    /// the action, or a context missing a required grant, is denied. Ordering reproduces today's precedence
    /// and messages.
    public static func evaluate(_ action: GatedPumpWrite,
                                surface: Surface,
                                context: AccessContext) -> AccessDecision {
        // Gate 4 — per-peer permission (authenticated peers only). No verb for this action ⇒ fail closed.
        if surface.isAuthenticatedPeer {
            guard let perm = action.requiredPeerPermission,
                  context.peerPolicy?.allows(perm) == true else {
                return .deny(.notPermittedForPeer)
            }
        }

        // Gate 2 — child mode. Local + watch/Garmin surfaces are subject to it; an authenticated peer
        // bypasses it (it just passed its own per-peer policy), exactly as `enforceChildLock: false` did.
        if context.childModeEnabled && !surface.isAuthenticatedPeer {
            if !context.childAllowed.contains(action.requiredChildFeature) {
                return .deny(.childLocked(action.requiredChildFeature))
            }
        }

        // Gate 3 — read-only. CARVE-OUT: `.childOnly` actions (cancel bolus, dismiss alert) are never
        // read-only-blocked — cancelling is a safety STOP that must stay available, and clearing an alert
        // is low-risk. Every other action: local ⇒ phoneReadOnly, remote ⇒ remotesReadOnly (the latter now
        // covering the Mac/caregiver peer path too — owner decision 2026-08-05).
        if action.gate != .childOnly {
            if surface.isLocal && context.phoneReadOnly { return .deny(.phoneReadOnly) }
            if surface.isRemote && context.remotesReadOnly { return .deny(.remotesReadOnly) }
        }

        // Gate 5 — pump capability + advanced-control opt-in (enforced at the funnel — owner decision
        // 2026-08-05). P13: two independent axes. The opt-in axis matches today's `advancedControlAllowed`
        // exactly; the capability axis is now driver-derived from the pump's own feature bitmask (P13-1),
        // so `isMobi` is gone. `syncTimeToNow` needs `supportsTimeSync` but NOT the opt-in — the split
        // removes the old special-case (a defense-in-depth tightening: the funnel now also refuses it on
        // a pump lacking that capability, which the UI already hides and no remote verb can reach).
        // Delivery + childOnly require neither axis, so Gate 5 stays a no-op there.
        if action.requiresAdvancedControlOptIn && !context.advancedControlOptIn {
            return .deny(.capabilityUnavailable)
        }
        if !action.hasRequiredCapability(in: context.capabilities) {
            return .deny(.capabilityUnavailable)
        }

        // Gate 1 — unverified-feature acknowledgment (the ack-gated therapy writes).
        if action.gate == .unverifiedAck && !context.hasRecentUnverifiedAck {
            return .deny(.unverifiedAckRequired)
        }

        // P14 seam: a mode check returning `.modeDisallowed` folds in here.

        return .allow
    }
}
