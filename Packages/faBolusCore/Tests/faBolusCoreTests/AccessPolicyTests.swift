import Testing
@testable import faBolusCore

/// Pins AccessPolicy fail-closed behavior across every GatedPumpWrite × Surface: read-only,
/// the remote bolus settings, and capability gates.
@Suite struct AccessPolicyTests {
    typealias P = AccessPolicy
    typealias A = GatedPumpWrite
    typealias S = AccessPolicy.Surface

    /// Fully locked: both read-only flags on, a pump model that can't take a dose.
    /// No dose may be delivered on any surface.
    private var locked: P.AccessContext {
        P.AccessContext(
            phoneReadOnly: true, remotesReadOnly: true,
            capabilities: .unknown)
    }
    /// Fully permissive: no read-only, a model that can take every kind of dose. No real model offers
    /// an extended bolus in this release, so the set is built here.
    private static var everyDose: PumpCapabilities {
        var caps = PumpCapabilities.tslimX2
        caps.supportsExtendedBolus = true
        return caps
    }
    private func openCtx() -> P.AccessContext {
        P.AccessContext(
            phoneReadOnly: false, remotesReadOnly: false,
            capabilities: Self.everyDose,
            // "Fully permissive" must set this explicitly now that the init default is
            // fail-closed (false); openCtx asserts a Garmin deliver is ALLOWED.
            garminBolusEnabled: true)
    }

    /// An otherwise-permissive host still refuses a Garmin `deliverBolus` when that surface's bolus
    /// enable is OFF — and ONLY that surface + that action.
    @Test func perSurfaceBolusEnableGatesGarminDeliverOnly() {
        let off = P.AccessContext(
            phoneReadOnly: false, remotesReadOnly: false,
            capabilities: Self.everyDose,
            garminBolusEnabled: false)
        #expect(P.evaluate(.deliverBolus, surface: .garmin, context: off).reason == .remoteBolusDisabled)
        // Not this surface — the phone is unaffected by the per-surface remote flag.
        #expect(P.evaluate(.deliverBolus, surface: .phoneUI, context: off).allowed)
        // Not this action — a safety STOP (cancel) from the same remote is never blocked by this gate.
        #expect(P.evaluate(.cancelBolus, surface: .garmin, context: off).reason != .remoteBolusDisabled)
        // Enabled ⇒ the deliver is allowed (openCtx defaults the flag to true).
        #expect(P.evaluate(.deliverBolus, surface: .garmin, context: openCtx()).allowed)
    }

    /// The per-surface remote-bolus enable gate AND the Garmin passcode gate must cover
    /// `.deliverExtendedBolus`, not only `.deliverBolus` — otherwise an extended bolus from a paired remote
    /// would bypass both.
    @Test func extendedBolusIsGatedLikeNormalBolusOnRemotes() {
        let off = P.AccessContext(
            phoneReadOnly: false, remotesReadOnly: false,
            capabilities: Self.everyDose,
            garminBolusEnabled: false)
        // Enable OFF ⇒ extended deliver denied on Garmin, exactly like a normal bolus.
        #expect(P.evaluate(.deliverExtendedBolus, surface: .garmin, context: off).reason == .remoteBolusDisabled)
        // Garmin passcode required-but-unsatisfied ⇒ extended deliver denied by the passcode gate too.
        var needsCode = openCtx()
        needsCode.bolusPasscodeRequired = true
        needsCode.bolusPasscodeSatisfied = false
        #expect(
            P.evaluate(.deliverExtendedBolus, surface: .garmin, context: needsCode).reason
                == .remoteBolusPasscodeRequired)
        // Enabled + no passcode ⇒ allowed (parity with normal bolus).
        #expect(P.evaluate(.deliverExtendedBolus, surface: .garmin, context: openCtx()).allowed)
    }

    /// A context built WITHOUT the per-surface remote-bolus flag must default it fail-closed, so a
    /// future call site that forgets to thread it cannot silently arm Garmin bolusing.
    @Test func accessContextDefaultsFailClosedForRemoteBolus() {
        let c = P.AccessContext(
            phoneReadOnly: false, remotesReadOnly: false,
            capabilities: .tslimX2)  // remote-bolus flag OMITTED
        #expect(P.evaluate(.deliverBolus, surface: .garmin, context: c).reason == .remoteBolusDisabled)
        #expect(P.evaluate(.deliverBolus, surface: .phoneUI, context: c).allowed)  // phone unaffected
    }

    /// When a passcode is required, a Garmin deliver is allowed only with a host-verified code.
    /// The phone is unaffected, a non-deliver action is never gated, and "bolusing off" still outranks "needs a passcode".
    @Test func garminBolusPasscodeGateRequiresASatisfiedCode() {
        // Required + verified ⇒ the Garmin deliver is allowed.
        var ok = openCtx()
        ok.bolusPasscodeRequired = true
        ok.bolusPasscodeSatisfied = true
        #expect(P.evaluate(.deliverBolus, surface: .garmin, context: ok).allowed)
        // Required + NOT satisfied (absent OR wrong OR backing off) ⇒ denied by the passcode gate.
        var bad = openCtx()
        bad.bolusPasscodeRequired = true
        bad.bolusPasscodeSatisfied = false
        #expect(P.evaluate(.deliverBolus, surface: .garmin, context: bad).reason == .remoteBolusPasscodeRequired)
        // Not required ⇒ no passcode gate at all (today's behavior), even with satisfied=false.
        var noReq = openCtx()
        noReq.bolusPasscodeRequired = false
        noReq.bolusPasscodeSatisfied = false
        #expect(P.evaluate(.deliverBolus, surface: .garmin, context: noReq).allowed)
        // The phone is unaffected by the Garmin passcode.
        #expect(P.evaluate(.deliverBolus, surface: .phoneUI, context: bad).allowed)
        // A non-deliver Garmin action (cancel) is never passcode-gated.
        #expect(P.evaluate(.cancelBolus, surface: .garmin, context: bad).reason != .remoteBolusPasscodeRequired)
        // Precedence: "Garmin bolusing off" still takes priority over "needs a passcode".
        var offAndReq = bad
        offAndReq.garminBolusEnabled = false
        #expect(P.evaluate(.deliverBolus, surface: .garmin, context: offAndReq).reason == .remoteBolusDisabled)
    }

    @Test func fullyLockedDeniesEveryDeliveryOnEverySurface() {
        for a in A.allCases where a.gate == .ledgeredDelivery {
            for s in S.allCases {
                #expect(
                    !P.evaluate(a, surface: s, context: locked).allowed,
                    "\(a.rawValue) on \(s.rawValue) must be denied when fully locked")
            }
        }
    }

    /// Cancel is never blocked by a gate, and clearing an alert is low-risk, so even a fully
    /// locked context allows both everywhere.
    @Test func fullyLockedStillAllowsCancelAndDismissOnEverySurface() {
        for a in A.allCases where a.gate == .alwaysAllowed {
            for s in S.allCases {
                #expect(
                    P.evaluate(a, surface: s, context: locked).allowed,
                    "\(a.rawValue) on \(s.rawValue) must stay available when fully locked")
            }
        }
    }

    @Test func fullyOpenAllowsEveryActionOnItsLocalSurface() {
        // Sanity: not an always-deny. Every action passes from the phone UI when everything is permitted.
        for a in A.allCases {
            #expect(
                P.evaluate(a, surface: .phoneUI, context: openCtx()).allowed,
                "\(a.rawValue) should be allowed on phoneUI when fully open")
        }
    }

    @Test func cancelAndDismissBypassReadOnlyOnEverySurface() {
        var ctx = openCtx()
        ctx.phoneReadOnly = true
        ctx.remotesReadOnly = true
        for a in [A.cancelBolus, A.dismissNotification] {
            for s in S.allCases {
                #expect(
                    P.evaluate(a, surface: s, context: ctx).allowed,
                    "\(a.rawValue) (safety STOP / clear) must stay available under read-only on \(s.rawValue)")
            }
        }
        // …but a real delivery IS blocked by the same read-only, per surface — including Garmin.
        #expect(P.evaluate(.deliverBolus, surface: .phoneUI, context: ctx).reason == .phoneReadOnly)
        #expect(P.evaluate(.deliverBolus, surface: .garmin, context: ctx).reason == .remotesReadOnly)
    }

    /// Only a model that can take a dose receives one: a Mobi or an unknown pump is refused at
    /// the funnel, on every surface, while cancel and dismiss never need a capability.
    @Test func deliveryNeedsAModelThatCanTakeADose() {
        for caps in [PumpCapabilities.mobi, .unknown] {
            var ctx = openCtx()
            ctx.capabilities = caps
            for s in S.allCases {
                #expect(P.evaluate(.deliverBolus, surface: s, context: ctx).reason == .capabilityUnavailable)
                #expect(P.evaluate(.deliverExtendedBolus, surface: s, context: ctx).reason == .capabilityUnavailable)
                #expect(P.evaluate(.cancelBolus, surface: s, context: ctx).allowed)
                #expect(P.evaluate(.dismissNotification, surface: s, context: ctx).allowed)
            }
        }
        var tslim = openCtx()
        tslim.capabilities = .tslimX2
        #expect(P.evaluate(.deliverBolus, surface: .phoneUI, context: tslim).allowed)
        // No model offers an extended bolus in this release, so the room it has is closed.
        #expect(P.evaluate(.deliverExtendedBolus, surface: .phoneUI, context: tslim).reason == .capabilityUnavailable)
    }
}
