import Testing
@testable import faBolusCore

/// P12 (defect group D) — the shared bolus gate + the `PumpSnapshot` link/in-flight seams that feed it.
struct BolusGateTests {

    private func gate(reachable: Bool = true, linked: Bool = true, inFlight: Bool = false,
                      cartridgeReady: Bool = true,
                      amount: Double = 2.0, minimum: Double = 0.05, maximum: Double = 25,
                      access: AccessPolicy.AccessDecision = .allow) -> (canBolus: Bool, reason: BolusBlockReason?) {
        BolusGate.evaluate(reachable: reachable, linked: linked, bolusInFlight: inFlight,
                           cartridgeReady: cartridgeReady,
                           amount: amount, minimum: minimum, maximum: maximum, access: access)
    }

    @Test func allowsWhenEverythingIsGood() {
        let r = gate()
        #expect(r.canBolus)
        #expect(r.reason == nil)
    }

    @Test func eachBlockerReportsItsReason() {
        #expect(gate(reachable: false).reason == .remoteUnreachable)
        #expect(gate(linked: false).reason == .pumpNotLinked)
        #expect(gate(inFlight: true).reason == .bolusInFlight)
        #expect(gate(cartridgeReady: false).reason == .noCartridge)
        #expect(gate(access: .deny(.remotesReadOnly)).reason == .accessDenied(.remotesReadOnly))
        #expect(gate(amount: 0).reason == .belowMinimum(0.05))
        #expect(gate(amount: 99).reason == .aboveMax(25))
        for r in [gate(reachable: false), gate(linked: false), gate(inFlight: true), gate(cartridgeReady: false),
                  gate(access: .deny(.remotesReadOnly)), gate(amount: 0), gate(amount: 99)] {
            #expect(!r.canBolus)
        }
    }

    /// Fail-safe precedence: the earliest (most fundamental) blocker wins when several are true at once.
    @Test func precedenceIsUnreachableThenLinkThenInFlightThenNoCartridgeThenAccessThenBounds() {
        // Everything wrong at once → unreachable dominates.
        #expect(gate(reachable: false, linked: false, inFlight: true, cartridgeReady: false,
                     amount: 99, access: .deny(.childLocked(.bolus))).reason == .remoteUnreachable)
        // Reachable but link down + in-flight + no-cartridge + denied + over-max → link dominates.
        #expect(gate(linked: false, inFlight: true, cartridgeReady: false, amount: 99,
                     access: .deny(.childLocked(.bolus))).reason == .pumpNotLinked)
        // Linked but in-flight + no-cartridge + denied + over-max → in-flight dominates.
        #expect(gate(inFlight: true, cartridgeReady: false, amount: 99,
                     access: .deny(.childLocked(.bolus))).reason == .bolusInFlight)
        // In-flight resolved but no-cartridge + denied + over-max → no-cartridge dominates.
        #expect(gate(cartridgeReady: false, amount: 99,
                     access: .deny(.childLocked(.bolus))).reason == .noCartridge)
        // Cartridge ready but denied + over-max → access denial beats a bounds problem.
        #expect(gate(amount: 99, access: .deny(.childLocked(.bolus))).reason == .accessDenied(.childLocked(.bolus)))
    }

    /// CGM staleness is deliberately NOT an input — a stale reading never disables the button (group A/D).
    /// There is no staleness parameter to pass; a fully-valid gate allows regardless of any CGM state.
    @Test func stalenessIsNotAGate() {
        #expect(gate().canBolus)   // no staleness knob exists; the gate can't be tripped by an old reading
    }

    /// VA-11: a non-finite amount (NaN / ±inf) must fail closed. It satisfies neither `< minimum` nor
    /// `> maximum`, so without the explicit `isFinite` guard it would fall through and arm the affordance.
    @Test func nonFiniteAmountFailsClosed() {
        for bad in [Double.nan, .infinity, -.infinity] {
            let r = gate(amount: bad)
            #expect(!r.canBolus, "amount \(bad) must not arm the bolus")
            #expect(r.reason == .belowMinimum(0.05))
        }
    }

    @Test func pumpSnapshotSeamsSeparateLinkFromInFlight() {
        var s = PumpSnapshot()
        s.connection = .connected
        #expect(s.isLinked); #expect(!s.bolusInFlight)
        s.connection = .bolusing
        #expect(s.isLinked); #expect(s.bolusInFlight)   // delivering is still "linked"
        for down in [PumpConnectionState.disconnected, .scanning, .connecting, .error] {
            s.connection = down
            #expect(!s.isLinked); #expect(!s.bolusInFlight)
        }
    }
}
