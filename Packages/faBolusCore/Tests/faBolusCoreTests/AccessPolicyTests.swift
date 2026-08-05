import Testing
@testable import faBolusCore

/// P8: the pure single-evaluator matrix. Iterates `GatedPumpWrite.allCases × Surface.allCases` to prove
/// fail-closed behavior, the cancel/dismiss read-only carve-out, that the child-lock bypass is available
/// ONLY to authenticated peers (the old `enforceChildLock` hole), and the capability + ack gates.
@Suite struct AccessPolicyTests {
    typealias P = AccessPolicy
    typealias A = GatedPumpWrite
    typealias S = AccessPolicy.Surface

    /// Fully locked: child on with nothing allowed, both read-only flags on, no ack, no advanced control,
    /// a view-only peer. Nothing consequential may happen on any surface.
    private var locked: P.AccessContext {
        P.AccessContext(childModeEnabled: true, childAllowed: [],
                        phoneReadOnly: true, remotesReadOnly: true,
                        advancedControlOptIn: false, isMobi: false, capabilities: PumpCapabilities(),
                        hasRecentUnverifiedAck: false, peerPolicy: .viewOnly)
    }
    /// Fully permissive: child off, no read-only, advanced control available, ack present, full peer policy.
    private func openCtx(peer: RemotePeerPolicy? = .fullControl) -> P.AccessContext {
        P.AccessContext(childModeEnabled: false, childAllowed: Set(ChildFeature.allCases),
                        phoneReadOnly: false, remotesReadOnly: false,
                        advancedControlOptIn: true, isMobi: true, capabilities: .mobiAdvanced,
                        hasRecentUnverifiedAck: true, peerPolicy: peer)
    }

    @Test func fullyLockedDeniesEveryActionOnEverySurface() {
        for a in A.allCases {
            for s in S.allCases {
                #expect(!P.evaluate(a, surface: s, context: locked).allowed,
                        "\(a.rawValue) on \(s.rawValue) must be denied when fully locked")
            }
        }
    }

    @Test func fullyOpenAllowsEveryActionOnItsLocalSurface() {
        // Sanity: not an always-deny. Every action passes from the phone UI when everything is permitted.
        for a in A.allCases {
            #expect(P.evaluate(a, surface: .phoneUI, context: openCtx()).allowed,
                    "\(a.rawValue) should be allowed on phoneUI when fully open")
        }
    }

    @Test func cancelAndDismissBypassReadOnlyOnEverySurface() {
        var ctx = openCtx(); ctx.phoneReadOnly = true; ctx.remotesReadOnly = true   // child OFF
        for a in [A.cancelBolus, A.dismissNotification] {
            for s in S.allCases {
                #expect(P.evaluate(a, surface: s, context: ctx).allowed,
                        "\(a.rawValue) (safety STOP / clear) must stay available under read-only on \(s.rawValue)")
            }
        }
        // …but a real delivery IS blocked by the same read-only, per surface.
        #expect(P.evaluate(.deliverBolus, surface: .phoneUI, context: ctx).reason == .phoneReadOnly)
        #expect(P.evaluate(.deliverBolus, surface: .appleWatch, context: ctx).reason == .remotesReadOnly)
        #expect(P.evaluate(.deliverBolus, surface: .macPeer, context: ctx).reason == .remotesReadOnly)   // owner decision: peers too
    }

    @Test func childModeStillGovernsCancelAndDismissWhenDisallowed() {
        var ctx = openCtx(); ctx.childModeEnabled = true; ctx.childAllowed = []
        #expect(P.evaluate(.cancelBolus, surface: .phoneUI, context: ctx).reason == .childLocked(.cancelBolus))
        #expect(P.evaluate(.dismissNotification, surface: .phoneUI, context: ctx).reason == .childLocked(.dismissAlerts))
    }

    @Test func childBypassIsAuthenticatedPeerOnly() {
        // Child mode ON, nothing allowed. A macPeer granted .bolus still delivers (bypass); the widget does
        // NOT — the old enforceChildLock:false hole is now closed to every non-peer surface.
        var ctx = openCtx(peer: RemotePeerPolicy(permissions: [.bolus]))
        ctx.childModeEnabled = true; ctx.childAllowed = []
        #expect(P.evaluate(.deliverBolus, surface: .macPeer, context: ctx).allowed)
        #expect(P.evaluate(.deliverBolus, surface: .quickBolusWidget, context: ctx).reason == .childLocked(.bolus))
    }

    @Test func peerFailsClosedWithoutPermissionOrVerb() {
        let ctx = openCtx(peer: .viewOnly)
        #expect(P.evaluate(.deliverBolus, surface: .macPeer, context: ctx).reason == .notPermittedForPeer)
        // An action with no remote verb (setTempBasal) is denied on a peer surface even with full policy.
        #expect(P.evaluate(.setTempBasal, surface: .macPeer, context: openCtx(peer: .fullControl)).reason == .notPermittedForPeer)
    }

    @Test func advancedControlRequiresCapabilityAndOptIn() {
        var noOptIn = openCtx(); noOptIn.advancedControlOptIn = false
        #expect(P.evaluate(.setTempBasal, surface: .phoneUI, context: noOptIn).reason == .capabilityUnavailable)
        var notMobi = openCtx(); notMobi.isMobi = false
        #expect(P.evaluate(.suspendDelivery, surface: .phoneUI, context: notMobi).reason == .capabilityUnavailable)
        // Delivery + the childOnly pair never require advanced control.
        #expect(P.evaluate(.deliverBolus, surface: .phoneUI, context: noOptIn).allowed)
        #expect(P.evaluate(.cancelBolus, surface: .phoneUI, context: noOptIn).allowed)
    }

    @Test func unverifiedAckGatesExactlyTheAckSet() {
        var noAck = openCtx(); noAck.hasRecentUnverifiedAck = false
        for a in A.allCases where a.gate == .unverifiedAck {
            #expect(P.evaluate(a, surface: .phoneUI, context: noAck).reason == .unverifiedAckRequired)
            var withAck = noAck; withAck.hasRecentUnverifiedAck = true
            #expect(P.evaluate(a, surface: .phoneUI, context: withAck).allowed)
        }
    }
}
