import Testing
@testable import faBolusCore

/// Pins that the always-remote/widget affordances (deliver, cancel, dismiss) never rise above
/// Simple, so no mode hides them on one surface while another offers them. The host still enforces
/// mode via AccessPolicy.
struct ModeCoherenceTests {

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
