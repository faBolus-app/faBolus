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
                        advancedControlOptIn: false, capabilities: PumpCapabilities(),
                        hasRecentUnverifiedAck: false, peerPolicy: .viewOnly)
    }
    /// Fully permissive: child off, no read-only, advanced control available, ack present, full peer policy.
    private func openCtx(peer: RemotePeerPolicy? = .fullControl) -> P.AccessContext {
        P.AccessContext(childModeEnabled: false, childAllowed: Set(ChildFeature.allCases),
                        phoneReadOnly: false, remotesReadOnly: false,
                        advancedControlOptIn: true, capabilities: .mobiAdvanced,
                        hasRecentUnverifiedAck: true, peerPolicy: peer,
                        // "Fully permissive" must set this explicitly now that the init default is
                        // fail-closed (false); openCtx asserts a Garmin deliver is ALLOWED.
                        garminBolusEnabled: true)
    }

    /// P15 §2.3: an otherwise-permissive host still refuses a Garmin `deliverBolus` when that surface's
    /// bolus enable is OFF (the app default) — and ONLY that surface + that action. The phone and
    /// authenticated peers bolus regardless of the per-surface remote flag, and a non-deliver action from
    /// the same remote is never denied by this gate.
    @Test func perSurfaceBolusEnableGatesGarminDeliverOnly() {
        let off = P.AccessContext(childModeEnabled: false, childAllowed: Set(ChildFeature.allCases),
                                  phoneReadOnly: false, remotesReadOnly: false,
                                  advancedControlOptIn: true, capabilities: .mobiAdvanced,
                                  hasRecentUnverifiedAck: true, peerPolicy: .fullControl,
                                  garminBolusEnabled: false)
        #expect(P.evaluate(.deliverBolus, surface: .garmin, context: off).reason == .remoteBolusDisabled)
        // Not this surface — the phone and authenticated peers are unaffected by the per-surface remote flag.
        #expect(P.evaluate(.deliverBolus, surface: .phoneUI, context: off).allowed)
        #expect(P.evaluate(.deliverBolus, surface: .macPeer, context: off).allowed)
        // Not this action — a safety STOP (cancel) from the same remote is never blocked by this gate.
        #expect(P.evaluate(.cancelBolus, surface: .garmin, context: off).reason != .remoteBolusDisabled)
        // Enabled ⇒ the deliver is allowed (openCtx defaults the flag to true).
        #expect(P.evaluate(.deliverBolus, surface: .garmin, context: openCtx()).allowed)
    }

    /// VA-30: the per-surface remote-bolus enable gate AND the Garmin passcode gate must cover
    /// `.deliverExtendedBolus`, not only `.deliverBolus` — otherwise an extended bolus from a paired remote
    /// would bypass both. Latent today (extended bolus isn't Garmin-reachable), but the single evaluator
    /// must not drift.
    @Test func extendedBolusIsGatedLikeNormalBolusOnRemotes() {
        let off = P.AccessContext(childModeEnabled: false, childAllowed: Set(ChildFeature.allCases),
                                  phoneReadOnly: false, remotesReadOnly: false,
                                  advancedControlOptIn: true, capabilities: .mobiAdvanced,
                                  hasRecentUnverifiedAck: true, peerPolicy: .fullControl,
                                  garminBolusEnabled: false)
        // Enable OFF ⇒ extended deliver denied on Garmin, exactly like a normal bolus.
        #expect(P.evaluate(.deliverExtendedBolus, surface: .garmin, context: off).reason == .remoteBolusDisabled)
        // Garmin passcode required-but-unsatisfied ⇒ extended deliver denied by the passcode gate too.
        var needsCode = openCtx(); needsCode.bolusPasscodeRequired = true; needsCode.bolusPasscodeSatisfied = false
        #expect(P.evaluate(.deliverExtendedBolus, surface: .garmin, context: needsCode).reason == .remoteBolusPasscodeRequired)
        // Enabled + no passcode ⇒ allowed (parity with normal bolus).
        #expect(P.evaluate(.deliverExtendedBolus, surface: .garmin, context: openCtx()).allowed)
    }

    /// Q1.2: a context built WITHOUT the per-surface remote-bolus flag must default it fail-CLOSED, so a
    /// future call site that forgets to thread it cannot silently arm Garmin bolusing.
    @Test func accessContextDefaultsFailClosedForRemoteBolus() {
        let c = P.AccessContext(childModeEnabled: false, childAllowed: Set(ChildFeature.allCases),
                                phoneReadOnly: false, remotesReadOnly: false,
                                advancedControlOptIn: true, capabilities: .mobiAdvanced,
                                hasRecentUnverifiedAck: true, peerPolicy: .fullControl)   // flag OMITTED
        #expect(P.evaluate(.deliverBolus, surface: .garmin, context: c).reason == .remoteBolusDisabled)
        #expect(P.evaluate(.deliverBolus, surface: .phoneUI, context: c).allowed)   // phone unaffected
    }

    /// C2 §2.3 — the OPTIONAL Garmin bolus passcode gate. When a passcode is required, a Garmin deliver is
    /// allowed ONLY with a host-verified (satisfied) code; absent/wrong (satisfied=false) denies with the
    /// passcode reason. The phone/peers are unaffected, a non-deliver action is never gated, and "bolusing
    /// off" still outranks "needs a passcode".
    @Test func garminBolusPasscodeGateRequiresASatisfiedCode() {
        // Required + verified ⇒ the Garmin deliver is allowed.
        var ok = openCtx(); ok.bolusPasscodeRequired = true; ok.bolusPasscodeSatisfied = true
        #expect(P.evaluate(.deliverBolus, surface: .garmin, context: ok).allowed)
        // Required + NOT satisfied (absent OR wrong OR backing off) ⇒ denied by the passcode gate.
        var bad = openCtx(); bad.bolusPasscodeRequired = true; bad.bolusPasscodeSatisfied = false
        #expect(P.evaluate(.deliverBolus, surface: .garmin, context: bad).reason == .remoteBolusPasscodeRequired)
        // Not required ⇒ no passcode gate at all (today's behavior), even with satisfied=false.
        var noReq = openCtx(); noReq.bolusPasscodeRequired = false; noReq.bolusPasscodeSatisfied = false
        #expect(P.evaluate(.deliverBolus, surface: .garmin, context: noReq).allowed)
        // The phone is unaffected by the Garmin passcode.
        #expect(P.evaluate(.deliverBolus, surface: .phoneUI, context: bad).allowed)
        // A non-deliver Garmin action (cancel) is never passcode-gated.
        #expect(P.evaluate(.cancelBolus, surface: .garmin, context: bad).reason != .remoteBolusPasscodeRequired)
        // Precedence: "Garmin bolusing off" still takes priority over "needs a passcode".
        var offAndReq = bad; offAndReq.garminBolusEnabled = false
        #expect(P.evaluate(.deliverBolus, surface: .garmin, context: offAndReq).reason == .remoteBolusDisabled)
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
        #expect(P.evaluate(.deliverBolus, surface: .garmin, context: ctx).reason == .remotesReadOnly)
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
        // Opt-in axis: opt-in off ⇒ an advanced write is denied even on a fully-capable pump.
        var noOptIn = openCtx(); noOptIn.advancedControlOptIn = false
        #expect(P.evaluate(.setTempBasal, surface: .phoneUI, context: noOptIn).reason == .capabilityUnavailable)
        // Capability axis: a pump with no advanced capability (e.g. a t:slim, `.full`) denies advanced
        // writes regardless of opt-in — P13 keys this on capabilities, not the retired `isMobi`.
        var noCap = openCtx(); noCap.capabilities = .full
        #expect(P.evaluate(.suspendDelivery, surface: .phoneUI, context: noCap).reason == .capabilityUnavailable)
        // Delivery + the childOnly pair never require advanced control (Gate 5 is a no-op for them).
        #expect(P.evaluate(.deliverBolus, surface: .phoneUI, context: noOptIn).allowed)
        #expect(P.evaluate(.cancelBolus, surface: .phoneUI, context: noOptIn).allowed)
    }

    @Test func syncTimeToNowNeedsCapabilityNotOptIn() {
        // P13 split, the motivating case: syncTimeToNow requires `supportsTimeSync` but NOT the opt-in.
        var noOptIn = openCtx(); noOptIn.advancedControlOptIn = false   // caps = .mobiAdvanced (has timeSync)
        #expect(P.evaluate(.syncTimeToNow, surface: .phoneUI, context: noOptIn).allowed)
        var noTimeSync = openCtx(); noTimeSync.capabilities = .full     // t:slim: no supportsTimeSync
        #expect(P.evaluate(.syncTimeToNow, surface: .phoneUI, context: noTimeSync).reason == .capabilityUnavailable)
    }

    /// Phase 09.10: `setSleepSchedule` declares its own dedicated capability (`supportsSleepScheduleWrite`)
    /// rather than the coarse advanced-control set — a t:slim-shaped capability context (no sleep-schedule
    /// write) denies it on phoneUI even with the advanced opt-in + a fresh ack, while a Mobi-shaped
    /// context (`.mobiAdvanced`) allows it. This is the funnel-level enforcement of the write's Mobi-only
    /// device scope (mirrors the pump protocol's own MOBI_ONLY/minApi annotation).
    @Test func setSleepScheduleNeedsItsOwnDedicatedCapability() {
        var noWriteCap = openCtx(); noWriteCap.capabilities = .full   // t:slim: no supportsSleepScheduleWrite
        #expect(P.evaluate(.setSleepSchedule, surface: .phoneUI, context: noWriteCap).reason == .capabilityUnavailable)
        let mobi = openCtx()   // .mobiAdvanced has supportsSleepScheduleWrite == true
        #expect(P.evaluate(.setSleepSchedule, surface: .phoneUI, context: mobi).allowed)
    }

    @Test func unverifiedAckGatesExactlyTheAckSet() {
        var noAck = openCtx(); noAck.hasRecentUnverifiedAck = false
        for a in A.allCases where a.gate == .unverifiedAck {
            #expect(P.evaluate(a, surface: .phoneUI, context: noAck).reason == .unverifiedAckRequired)
            var withAck = noAck; withAck.hasRecentUnverifiedAck = true
            #expect(P.evaluate(a, surface: .phoneUI, context: withAck).allowed)
        }
    }

    // MARK: - P14 Slice 2 — the mode axis

    @Test func defaultModeContextIsANoOp() {
        // The default (.advanced, no toggles) must add zero denials: every action passes on phoneUI when
        // everything else is open, exactly as before the mode gate existed.
        for a in A.allCases {
            #expect(P.evaluate(a, surface: .phoneUI, context: openCtx()).allowed,
                    "\(a.rawValue) must stay allowed at the default (Advanced) mode")
        }
    }

    @Test func simpleModeAllowsCoreButDeniesAdvancedWithModeReason() {
        var ctx = openCtx(); ctx.modeContext = P.ModeGateContext(activeMode: .simple)
        // Core: a normal bolus is available in Simple.
        #expect(P.evaluate(.deliverBolus, surface: .phoneUI, context: ctx).allowed)
        // Advanced (min .advanced): denied specifically by the mode gate, not another gate.
        for a in [A.setTempBasal, .setControlIQ, .deliverExtendedBolus, .createProfile] {
            #expect(P.evaluate(a, surface: .phoneUI, context: ctx).reason == .modeDisallowed(required: .advanced),
                    "\(a.rawValue) must be modeDisallowed(.advanced) in Simple")
        }
        // Standard-tier control (suspend/resume) reports it needs Standard, not Advanced.
        #expect(P.evaluate(.suspendDelivery, surface: .phoneUI, context: ctx).reason == .modeDisallowed(required: .standard))
        // Standard mode then permits suspend/resume but still hides the advanced writes.
        ctx.modeContext = P.ModeGateContext(activeMode: .standard)
        #expect(P.evaluate(.suspendDelivery, surface: .phoneUI, context: ctx).allowed)
        #expect(P.evaluate(.setTempBasal, surface: .phoneUI, context: ctx).reason == .modeDisallowed(required: .advanced))
    }

    @Test func modeNeverBlocksSafetyStopsOnAnySurface() {
        // OQ9: the mode gate is carved out for `.childOnly` STOPs exactly as Gate 3 is. Even in the most
        // restrictive mode (Simple), a cancel / dismiss stays available on every surface.
        var ctx = openCtx(); ctx.modeContext = P.ModeGateContext(activeMode: .simple)
        for a in [A.cancelBolus, A.dismissNotification] {
            for s in S.allCases {
                #expect(P.evaluate(a, surface: s, context: ctx).allowed,
                        "\(a.rawValue) (safety STOP) must survive Simple mode on \(s.rawValue)")
            }
        }
    }

    @Test func perFeatureToggleDeniesWithinTheMode() {
        // Owner decision #4: even in a mode that would permit an action, a per-feature toggle turns it off.
        var ctx = openCtx()
        ctx.modeContext = P.ModeGateContext(activeMode: .advanced, disabledFeatures: [.setTempBasal])
        #expect(P.evaluate(.setTempBasal, surface: .phoneUI, context: ctx).reason == .featureDisabledInMode)
        #expect(P.evaluate(.setControlIQ, surface: .phoneUI, context: ctx).allowed)   // a different feature is unaffected
        // …but a toggle can never disable a safety STOP (carve-out again).
        ctx.modeContext = P.ModeGateContext(activeMode: .advanced, disabledFeatures: [.cancelBolus, .dismissNotification])
        #expect(P.evaluate(.cancelBolus, surface: .phoneUI, context: ctx).allowed)
        #expect(P.evaluate(.dismissNotification, surface: .phoneUI, context: ctx).allowed)
    }
}
