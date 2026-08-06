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

    /// P14 Slice 2 — the mode axis, folded in as one more input to the one evaluator (NOT a sixth
    /// mechanism). Carries the active experience mode and the per-feature toggles the user set within it
    /// (owner decision #4). `evaluate` gains exactly one ordered `.modeDisallowed` / `.featureDisabledInMode`
    /// check at the reserved slot; no surface or funnel signature changes.
    ///
    /// The default is `.advanced` with no toggles — a **no-op**: Advanced sees every action, so an app
    /// that has not yet wired a real mode source (or a caller that omits `modeContext`) behaves exactly as
    /// before. S3 supplies the real active mode (the Objectives ModeStore) and flips the app default to
    /// Simple together with the unlock path, so `main` never has a Simple-with-no-way-out window.
    public struct ModeGateContext: Sendable, Equatable {
        /// The active experience mode. Higher modes see strictly more (see `AppMode`'s ordering).
        public var activeMode: AppMode
        /// Features the user has explicitly turned off inside their current mode — finer-grained control
        /// than the mode alone (owner decision #4). Empty ⇒ no per-feature restriction. Never populated by
        /// a safety STOP (see `evaluate`'s carve-out).
        public var disabledFeatures: Set<GatedPumpWrite>
        public init(activeMode: AppMode = .advanced, disabledFeatures: Set<GatedPumpWrite> = []) {
            self.activeMode = activeMode
            self.disabledFeatures = disabledFeatures
        }
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
        case modeDisallowed(required: AppMode)   // P14: feature not in the active mode
        case featureDisabledInMode               // P14: user turned this feature off within the mode

        public var userMessage: String {
            switch self {
            case .notPermittedForPeer:  return "Not permitted for this remote."
            case .childLocked(let f):   return "Locked (child mode): \(f.label.lowercased()) is disabled."
            case .phoneReadOnly:        return "This action is disabled — the app is in read-only mode."
            case .remotesReadOnly:      return "Remote control is turned off — remotes are read-only."
            case .capabilityUnavailable: return "This pump doesn't support that action, or advanced control is off."
            case .unverifiedAckRequired: return "This needs the untested-feature warning acknowledged first."
            case .modeDisallowed(let m): return "Not available in your current mode — needs \(m.title) mode."
            case .featureDisabledInMode: return "This feature is turned off in your settings."
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

        // P14 (Slice 2) — the mode gate: one ordered input, evaluated last so an earlier gate's precedence
        // and message are unchanged. CARVE-OUT (OQ9): a mode NEVER restricts a safety STOP. `.childOnly`
        // (cancel bolus / dismiss alert) is skipped here exactly as Gate 3 skips it — otherwise Simple mode
        // would silently disable a cancel. The default context is `.advanced` with no toggles, so this is a
        // no-op until S3 supplies a real active mode.
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
