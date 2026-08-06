import Testing
@testable import faBolusCore

/// P14 S4 (mode coherence): the mode axis vs the remote-reachable surfaces.
///
/// FINDING (documented; owner decision pending — NO behavior change in this slice): `AppModel`
/// `.accessDecision` applies the phone's active mode to EVERY surface (S2: "modes gate every surface
/// identically"). Three peer-reachable actions are gated ABOVE Simple —
/// `deliverExtendedBolus` (advanced) and `suspendDelivery` / `resumeDelivery` (standard) — so when the
/// phone is in a lower mode an authenticated peer (e.g. the Mac's combo-bolus + suspend/resume controls)
/// is denied with `.modeDisallowed`, yet the peer UI still offers it. The peer can't reflect the phone's
/// mode (it isn't published to remotes), so this is a narrow show-then-fail on a remote whose user can't
/// even change the phone's mode. Delivery + cancel/dismiss are Simple (and cancel/dismiss are
/// `.childOnly`-carved), so they stay coherent on every surface in every mode — which is why the
/// widget / watch / Garmin bolus path (Simple-only) has NO coherence gap.
///
/// This test PINS that coherence surface so any change to `requiredMode` / peer permissions surfaces
/// here. The recommended resolution — scope the mode gate to phone-owned surfaces (`Surface.isLocal`),
/// leaving authenticated peers governed by their per-peer policy (Gate 4) rather than the phone's
/// progressive-disclosure mode — is deliberately NOT implemented: it LOOSENS a (non-safety) gate and
/// revises S2's "every surface" statement, so it awaits owner sign-off. (The alternative — publish the
/// active mode to the remotes so they hide the affordance — is the heavier 9-artifact wire path.)
struct ModeCoherenceTests {

    @Test func remoteReachableActionsGatedAboveSimpleArePinned() {
        let remoteReachable = GatedPumpWrite.allCases.filter { $0.requiredPeerPermission != nil }
        let aboveSimple = Set(remoteReachable.filter { $0.requiredMode > .simple }.map(\.rawValue))
        // Exactly these peer-reachable actions would be mode-denied in a lower mode → the S4 gap surface.
        #expect(aboveSimple == ["deliverExtendedBolus", "suspendDelivery", "resumeDelivery"])
    }

    @Test func deliveryAndStopsStayCoherentInEveryMode() {
        // The always-remote/widget affordances never rise above Simple, so no mode hides them on one
        // surface while another offers them.
        #expect(GatedPumpWrite.deliverBolus.requiredMode == .simple)
        #expect(GatedPumpWrite.cancelBolus.requiredMode == .simple)
        #expect(GatedPumpWrite.dismissNotification.requiredMode == .simple)
        // …and the two STOPs are `.childOnly`, carved out of the mode gate entirely (never mode-denied).
        #expect(GatedPumpWrite.cancelBolus.gate == .childOnly)
        #expect(GatedPumpWrite.dismissNotification.gate == .childOnly)
    }
}
