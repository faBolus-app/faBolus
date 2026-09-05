import Testing
@testable import faBolusCore

/// Pins AccessPolicy fail-closed behavior across every GatedPumpWrite × Surface: read-only,
/// child-lock, and capability gates.
@Suite struct AccessPolicyTests {
    typealias P = AccessPolicy
    typealias A = GatedPumpWrite
    typealias S = AccessPolicy.Surface

    /// Fully locked: child on with nothing allowed, both read-only flags on, no advanced control.
    /// Nothing consequential may happen on any surface.
    private var locked: P.AccessContext {
        P.AccessContext(
            childModeEnabled: true, childAllowed: [],
            phoneReadOnly: true, remotesReadOnly: true,
            capabilities: PumpCapabilities())
    }
    /// Fully permissive: child off, no read-only, advanced control available.
    private func openCtx() -> P.AccessContext {
        P.AccessContext(
            childModeEnabled: false, childAllowed: Set(ChildFeature.allCases),
            phoneReadOnly: false, remotesReadOnly: false,
            capabilities: .mobiAdvanced,
            // "Fully permissive" must set this explicitly now that the init default is
            // fail-closed (false); openCtx asserts a Garmin deliver is ALLOWED.
            garminBolusEnabled: true)
    }

    /// An otherwise-permissive host still refuses a Garmin `deliverBolus` when that surface's bolus
    /// enable is OFF — and ONLY that surface + that action.
    @Test func perSurfaceBolusEnableGatesGarminDeliverOnly() {
        let off = P.AccessContext(
            childModeEnabled: false, childAllowed: Set(ChildFeature.allCases),
            phoneReadOnly: false, remotesReadOnly: false,
            capabilities: .mobiAdvanced,
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
            childModeEnabled: false, childAllowed: Set(ChildFeature.allCases),
            phoneReadOnly: false, remotesReadOnly: false,
            capabilities: .mobiAdvanced,
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
            childModeEnabled: false, childAllowed: Set(ChildFeature.allCases),
            phoneReadOnly: false, remotesReadOnly: false,
            capabilities: .mobiAdvanced)  // remote-bolus flag OMITTED
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

    @Test func fullyLockedDeniesEveryActionOnEverySurface() {
        for a in A.allCases {
            for s in S.allCases {
                #expect(
                    !P.evaluate(a, surface: s, context: locked).allowed,
                    "\(a.rawValue) on \(s.rawValue) must be denied when fully locked")
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
        ctx.remotesReadOnly = true  // child OFF
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

    @Test func childModeStillGovernsCancelAndDismissWhenDisallowed() {
        var ctx = openCtx()
        ctx.childModeEnabled = true
        ctx.childAllowed = []
        #expect(P.evaluate(.cancelBolus, surface: .phoneUI, context: ctx).reason == .childLocked(.cancelBolus))
        #expect(
            P.evaluate(.dismissNotification, surface: .phoneUI, context: ctx).reason == .childLocked(.dismissAlerts))
    }

    // Gate 5's opt-in axis is retired; only the capability axis remains — the surviving denier of
    // advanced writes on a t:slim.
    @Test func advancedControlRequiresCapability() {
        // Capability axis: a pump with no advanced capability (e.g. a t:slim, `.full`) denies advanced
        // writes — this keys on capabilities, not a pump-family flag.
        var noCap = openCtx()
        noCap.capabilities = .full
        #expect(P.evaluate(.syncTimeToNow, surface: .phoneUI, context: noCap).reason == .capabilityUnavailable)
    }

    /// The only evaluator-level proof anywhere that a t:slim refuses a pump-clock write.
    @Test func syncTimeToNowNeedsCapability() {
        var noTimeSync = openCtx()
        noTimeSync.capabilities = .full  // t:slim: no supportsTimeSync
        #expect(P.evaluate(.syncTimeToNow, surface: .phoneUI, context: noTimeSync).reason == .capabilityUnavailable)
    }

    // MARK: - Mode axis

    @Test func defaultModeContextIsANoOp() {
        // The default (.advanced, no toggles) must add zero denials: every action passes on phoneUI when
        // everything else is open, exactly as before the mode gate existed.
        for a in A.allCases {
            #expect(
                P.evaluate(a, surface: .phoneUI, context: openCtx()).allowed,
                "\(a.rawValue) must stay allowed at the default (Advanced) mode")
        }
    }

    @Test func simpleModeAllowsCoreButDeniesAdvancedWithModeReason() {
        var ctx = openCtx()
        ctx.modeContext = P.ModeGateContext(activeMode: .simple)
        // Core: a normal bolus is available in Simple.
        #expect(P.evaluate(.deliverBolus, surface: .phoneUI, context: ctx).allowed)
        // Advanced (min .advanced): denied specifically by the mode gate, not another gate.
        for a in [A.deliverExtendedBolus, .syncTimeToNow] {
            #expect(
                P.evaluate(a, surface: .phoneUI, context: ctx).reason == .modeDisallowed(required: .advanced),
                "\(a.rawValue) must be modeDisallowed(.advanced) in Simple")
        }
        // Standard mode still hides the advanced writes — no surviving case has a `.standard` floor today,
        // so this is purely the mode axis' own ranking, not a case-specific proof.
        ctx.modeContext = P.ModeGateContext(activeMode: .standard)
        #expect(
            P.evaluate(.syncTimeToNow, surface: .phoneUI, context: ctx).reason == .modeDisallowed(required: .advanced))
    }

    @Test func modeNeverBlocksSafetyStopsOnAnySurface() {
        // The mode gate is carved out for `.childOnly` STOPs exactly as Gate 3 is. Even in the most
        // restrictive mode (Simple), a cancel / dismiss stays available on every surface.
        var ctx = openCtx()
        ctx.modeContext = P.ModeGateContext(activeMode: .simple)
        for a in [A.cancelBolus, A.dismissNotification] {
            for s in S.allCases {
                #expect(
                    P.evaluate(a, surface: s, context: ctx).allowed,
                    "\(a.rawValue) (safety STOP) must survive Simple mode on \(s.rawValue)")
            }
        }
    }

    @Test func perFeatureToggleDeniesWithinTheMode() {
        // Owner decision #4: even in a mode that would permit an action, a per-feature toggle turns it off.
        var ctx = openCtx()
        ctx.modeContext = P.ModeGateContext(activeMode: .advanced, disabledFeatures: [.syncTimeToNow])
        #expect(P.evaluate(.syncTimeToNow, surface: .phoneUI, context: ctx).reason == .featureDisabledInMode)
        #expect(P.evaluate(.deliverExtendedBolus, surface: .phoneUI, context: ctx).allowed)  // a different feature is unaffected
        // …but a toggle can never disable a safety STOP (carve-out again).
        ctx.modeContext = P.ModeGateContext(
            activeMode: .advanced, disabledFeatures: [.cancelBolus, .dismissNotification])
        #expect(P.evaluate(.cancelBolus, surface: .phoneUI, context: ctx).allowed)
        #expect(P.evaluate(.dismissNotification, surface: .phoneUI, context: ctx).allowed)
    }
}
