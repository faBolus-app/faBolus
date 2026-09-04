import Testing
@testable import faBolusCore

/// Pins AccessPolicy fail-closed behavior across every GatedPumpWrite × Surface: read-only,
/// child-lock, capability, and ack gates.
@Suite struct AccessPolicyTests {
    typealias P = AccessPolicy
    typealias A = GatedPumpWrite
    typealias S = AccessPolicy.Surface

    /// Fully locked: child on with nothing allowed, both read-only flags on, no ack, no advanced
    /// control. Nothing consequential may happen on any surface.
    private var locked: P.AccessContext {
        P.AccessContext(
            childModeEnabled: true, childAllowed: [],
            phoneReadOnly: true, remotesReadOnly: true,
            advancedControlOptIn: false, capabilities: PumpCapabilities(),
            hasRecentUnverifiedAck: false)
    }
    /// Fully permissive: child off, no read-only, advanced control available, ack present.
    private func openCtx() -> P.AccessContext {
        P.AccessContext(
            childModeEnabled: false, childAllowed: Set(ChildFeature.allCases),
            phoneReadOnly: false, remotesReadOnly: false,
            advancedControlOptIn: true, capabilities: .mobiAdvanced,
            hasRecentUnverifiedAck: true,
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
            advancedControlOptIn: true, capabilities: .mobiAdvanced,
            hasRecentUnverifiedAck: true,
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
            advancedControlOptIn: true, capabilities: .mobiAdvanced,
            hasRecentUnverifiedAck: true,
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
            advancedControlOptIn: true, capabilities: .mobiAdvanced,
            hasRecentUnverifiedAck: true)  // flag OMITTED
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

    // Gate 5 has two independent axes; these are split into one test per axis so the opt-in half can be
    // removed wholesale when the advanced-control opt-in is retired, leaving the capability half — the
    // surviving denier of advanced writes on a t:slim — untouched.
    @Test func advancedControlRequiresOptIn() {
        // Opt-in axis: opt-in off ⇒ an advanced write is denied even on a fully-capable pump.
        var noOptIn = openCtx()
        noOptIn.advancedControlOptIn = false
        #expect(P.evaluate(.setTempBasal, surface: .phoneUI, context: noOptIn).reason == .capabilityUnavailable)
        // Delivery + the childOnly pair never require advanced control (Gate 5 is a no-op for them).
        #expect(P.evaluate(.deliverBolus, surface: .phoneUI, context: noOptIn).allowed)
        #expect(P.evaluate(.cancelBolus, surface: .phoneUI, context: noOptIn).allowed)
    }

    @Test func advancedControlRequiresCapability() {
        // Capability axis: a pump with no advanced capability (e.g. a t:slim, `.full`) denies advanced
        // writes regardless of opt-in — this keys on capabilities, not a pump-family flag.
        var noCap = openCtx()
        noCap.capabilities = .full
        #expect(P.evaluate(.suspendDelivery, surface: .phoneUI, context: noCap).reason == .capabilityUnavailable)
    }

    // `syncTimeToNow` is split the same way: it never needed the opt-in (its opt-in half retires with the
    // opt-in), but it DOES need `supportsTimeSync`. That capability half is the only evaluator-level proof
    // anywhere that a t:slim refuses a pump-clock write, so it must outlive the opt-in cut.
    @Test func syncTimeToNowDoesNotNeedOptIn() {
        // syncTimeToNow requires `supportsTimeSync` but NOT the advanced-control opt-in.
        var noOptIn = openCtx()
        noOptIn.advancedControlOptIn = false  // caps = .mobiAdvanced (has timeSync)
        #expect(P.evaluate(.syncTimeToNow, surface: .phoneUI, context: noOptIn).allowed)
    }

    @Test func syncTimeToNowNeedsCapability() {
        var noTimeSync = openCtx()
        noTimeSync.capabilities = .full  // t:slim: no supportsTimeSync
        #expect(P.evaluate(.syncTimeToNow, surface: .phoneUI, context: noTimeSync).reason == .capabilityUnavailable)
    }

    /// `setSleepSchedule` declares its own dedicated capability (`supportsSleepScheduleWrite`) rather
    /// than the coarse advanced-control set — a t:slim-shaped context denies it even with opt-in + ack.
    @Test func setSleepScheduleNeedsItsOwnDedicatedCapability() {
        var noWriteCap = openCtx()
        noWriteCap.capabilities = .full  // t:slim: no supportsSleepScheduleWrite
        #expect(P.evaluate(.setSleepSchedule, surface: .phoneUI, context: noWriteCap).reason == .capabilityUnavailable)
        let mobi = openCtx()  // .mobiAdvanced has supportsSleepScheduleWrite == true
        #expect(P.evaluate(.setSleepSchedule, surface: .phoneUI, context: mobi).allowed)
    }

    @Test func unverifiedAckGatesExactlyTheAckSet() {
        var noAck = openCtx()
        noAck.hasRecentUnverifiedAck = false
        for a in A.allCases where a.gate == .unverifiedAck {
            #expect(P.evaluate(a, surface: .phoneUI, context: noAck).reason == .unverifiedAckRequired)
            var withAck = noAck
            withAck.hasRecentUnverifiedAck = true
            #expect(P.evaluate(a, surface: .phoneUI, context: withAck).allowed)
        }
    }

    // MARK: - Denial oracle: a t:slim refuses every advanced write

    /// The machine-checked statement that a t:slim (`.full` capabilities) refuses every advanced pump
    /// write and permits only the four capability-exempt actions — with the advanced-control opt-in AND
    /// the unverified-ack BOTH satisfied, so it is the pump-capability axis ALONE that supplies the
    /// denial while the other two gates still exist. The expected sets are hardcoded by name (never
    /// derived from `hasRequiredCapability`) and cross-checked on `action.gate` (never on
    /// `decision.allowed`), so this cannot go vacuously green if the capability axis is later removed.
    @Test func tslimDeniesEveryAdvancedWriteAndPermitsOnlyTheCapabilityExemptFour() {
        // A t:slim `.full` context with BOTH the opt-in and the ack set, so neither the opt-in axis nor
        // the ack gate can supply the green — only the capability axis can deny.
        let tslim = P.AccessContext(
            childModeEnabled: false, childAllowed: Set(ChildFeature.allCases),
            phoneReadOnly: false, remotesReadOnly: false,
            advancedControlOptIn: true, capabilities: .full,
            hasRecentUnverifiedAck: true)

        // Hardcoded expected sets, asserted individually below — NOT derived from the implementation
        // this oracle exists to guard.
        let expectedDenied: [A] = [
            // capability-gated therapy writes (ack-tier)
            .createProfile, .setActiveProfile, .renameProfile, .deleteProfile,
            .addProfileSegment, .modifyProfileSegment, .deleteProfileSegment, .setCgmHighLowAlert,
            .setControlIQ, .setMaxBolus, .setMaxBasal, .setSleepSchedule,
            // capability-gated operational writes (control-interlock tier)
            .suspendDelivery, .resumeDelivery, .setTempBasal, .stopTempBasal, .setMode, .playFindMyPump,
            .startG6Session, .startG7Session, .setSensorType, .stopCgmSession,
            .enterChangeCartridgeMode, .exitChangeCartridgeMode, .enterFillTubingMode, .exitFillTubingMode,
            .fillCannula, .syncTimeToNow,
            .setLowInsulinAlert, .setAutoOffAlert, .setSiteChangeReminder, .setAlertSnooze,
            .setCgmOutOfRangeAlert, .setCgmRiseFallAlert,
        ]
        let expectedPermitted: [A] = [
            .deliverBolus, .deliverExtendedBolus,  // ledgered delivery — capability-exempt
            .cancelBolus, .dismissNotification,  // child-only STOP/clear — capability-exempt
        ]

        // Literal counts: 34 denied / 4 permitted, with the 38 total guarding against a new case slipping
        // in unclassified.
        let deniedCount = expectedDenied.count
        #expect(deniedCount == 34)
        #expect(expectedPermitted.count == 4)
        #expect(A.allCases.count == 38)

        // The two hardcoded sets partition GatedPumpWrite exactly — nothing missing, nothing double-listed.
        #expect(Set(expectedDenied).isDisjoint(with: Set(expectedPermitted)))
        #expect(Set(expectedDenied).union(expectedPermitted) == Set(A.allCases))

        // Cross-check on `action.gate` — an independent property, NEVER the capability predicate and NEVER
        // `decision.allowed`: the denied set is exactly the two capability-gated gates, the permitted set
        // exactly the two capability-exempt gates.
        for a in expectedDenied {
            #expect(
                a.gate == .unverifiedAck || a.gate == .controlInterlock,
                "\(a.rawValue) is listed as denied but its gate is capability-exempt")
        }
        for a in expectedPermitted {
            #expect(
                a.gate == .ledgeredDelivery || a.gate == .childOnly,
                "\(a.rawValue) is listed as permitted but its gate is capability-gated")
        }

        // The oracle proper, on the local phone surface: every hardcoded denied case denies with
        // `.capabilityUnavailable`; every hardcoded permitted case is allowed.
        for a in expectedDenied {
            #expect(
                P.evaluate(a, surface: .phoneUI, context: tslim).reason == .capabilityUnavailable,
                "\(a.rawValue) must be capability-denied on a t:slim")
        }
        for a in expectedPermitted {
            #expect(
                P.evaluate(a, surface: .phoneUI, context: tslim).allowed,
                "\(a.rawValue) must stay allowed on a t:slim (capability-exempt)")
        }
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
        for a in [A.setTempBasal, .setControlIQ, .deliverExtendedBolus, .createProfile] {
            #expect(
                P.evaluate(a, surface: .phoneUI, context: ctx).reason == .modeDisallowed(required: .advanced),
                "\(a.rawValue) must be modeDisallowed(.advanced) in Simple")
        }
        // Standard-tier control (suspend/resume) reports it needs Standard, not Advanced.
        #expect(
            P.evaluate(.suspendDelivery, surface: .phoneUI, context: ctx).reason == .modeDisallowed(required: .standard)
        )
        // Standard mode then permits suspend/resume but still hides the advanced writes.
        ctx.modeContext = P.ModeGateContext(activeMode: .standard)
        #expect(P.evaluate(.suspendDelivery, surface: .phoneUI, context: ctx).allowed)
        #expect(
            P.evaluate(.setTempBasal, surface: .phoneUI, context: ctx).reason == .modeDisallowed(required: .advanced))
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
        ctx.modeContext = P.ModeGateContext(activeMode: .advanced, disabledFeatures: [.setTempBasal])
        #expect(P.evaluate(.setTempBasal, surface: .phoneUI, context: ctx).reason == .featureDisabledInMode)
        #expect(P.evaluate(.setControlIQ, surface: .phoneUI, context: ctx).allowed)  // a different feature is unaffected
        // …but a toggle can never disable a safety STOP (carve-out again).
        ctx.modeContext = P.ModeGateContext(
            activeMode: .advanced, disabledFeatures: [.cancelBolus, .dismissNotification])
        #expect(P.evaluate(.cancelBolus, surface: .phoneUI, context: ctx).allowed)
        #expect(P.evaluate(.dismissNotification, surface: .phoneUI, context: ctx).allowed)
    }
}
