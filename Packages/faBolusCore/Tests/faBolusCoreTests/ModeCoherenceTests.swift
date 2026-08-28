import Testing
@testable import faBolusCore

/// Pins which peer-reachable pump writes sit above Simple so remotes hide those affordances instead of
/// showing a control the host would refuse. The host still enforces mode via AccessPolicy.
struct ModeCoherenceTests {

    @Test func remoteReachableActionsGatedAboveSimpleArePinned() {
        let remoteReachable = GatedPumpWrite.allCases.filter { $0.requiredPeerPermission != nil }
        let aboveSimple = Set(remoteReachable.filter { $0.requiredMode > .simple }.map(\.rawValue))
        // Exactly these peer-reachable actions would be mode-denied in a lower mode.
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
