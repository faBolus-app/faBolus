import Testing
@testable import faBolusCore

/// Phase 09.15 T2-3 (D-04) — the Control-IQ+-only temp-rate placeholder's bench + capability gate. Pins
/// two independent axes so a future regression on either one goes RED:
/// (1) `benchVerifiedDefault` ships `false` — the option is inert regardless of the connected pump's
///     controller variant.
/// (2) even hypothetically bench-verified, availability is capability-scoped to `.controlIQPro`
///     (Control-IQ+) only — classic Control-IQ and no-controller never offer it.
struct CiqPlusTempRateGateTests {

    @Test func shipsBenchUnverifiedByDefault() {
        #expect(CiqPlusTempRate.benchVerifiedDefault == false)
    }

    @Test func benchUnverifiedIsNeverOfferedOnAnyVariant() {
        // Gate false ⇒ inert on EVERY variant, including .controlIQPro itself — the bench flag alone
        // decides whether the option can ever appear, before capability is even considered.
        for v in ControllerVariant.allCases {
            #expect(CiqPlusTempRate.isOffered(benchVerified: false, controllerVariant: v) == false,
                    "bench-unverified must never offer the option (variant \(v))")
        }
    }

    @Test func benchVerifiedIsOfferedOnlyOnControlIQPro() {
        // Hypothetical post-bench state: offered ONLY on Control-IQ+, never on classic Control-IQ or
        // no-controller — this is a Control-IQ+-only manual tool, not a general temp-rate unlock.
        #expect(CiqPlusTempRate.isOffered(benchVerified: true, controllerVariant: .controlIQPro) == true)
        #expect(CiqPlusTempRate.isOffered(benchVerified: true, controllerVariant: .controlIQ) == false)
        #expect(CiqPlusTempRate.isOffered(benchVerified: true, controllerVariant: .none) == false)
    }

    @Test func defaultArgumentWiresToBenchVerifiedDefault() {
        // A call site that omits `benchVerified` (the production shape) must resolve identically to
        // passing `benchVerifiedDefault` explicitly — never offered pre-bench even by omission.
        #expect(CiqPlusTempRate.isOffered(controllerVariant: .controlIQPro) == CiqPlusTempRate.benchVerifiedDefault)
    }

    @Test func classicTempRateBlockReasonIsUntouchedByThisGate() {
        // The classic-CIQ inverse precondition (temp rate requires CIQ OFF) is a completely separate,
        // pre-existing gate — this bench-gated placeholder must not alter its behavior in either
        // direction, on any Control-IQ-enabled state.
        #expect(ControlIQPrecondition.tempRateBlockReason(controlIQEnabled: false) == nil)
        #expect(ControlIQPrecondition.tempRateBlockReason(controlIQEnabled: true) != nil)
    }
}
