import Testing
@testable import faBolusCore

/// Exhaustive matrix for SG1 (`StackingGuard.calcOverride`) — mirrors `CalcInputGateTests`' nested-loop
/// exhaustive style. Each row pins a safety property; a future edit that reintroduces a false-positive,
/// false-negative, structural, or forbidden-phrase hole fails here rather than shipping.
@Suite struct StackingGuardTests {

    private let target = 120   // arbitrary pump-reported op-115 target for these rows

    // MARK: - SG1 fires: entered > positive recommended, glucose above the pump's own target, displayable dose

    @Test func firesWhenOverridingAboveTargetWithDisplayableDose() {
        let cases: [(entered: Double, recommended: Double)] = [(2.0, 0.5), (5.0, 1.0), (10.0, 9.9)]
        for c in cases {
            let d = StackingGuard.calcOverride(enteredUnits: c.entered, recommendedUnits: c.recommended,
                                                displaysNumericDose: true, pumpIOBUnits: 0.5,
                                                glucoseMgdl: target + 10, targetMgdl: target)
            #expect(d.friction == .disclose)
            #expect(d.message?.contains("more than the pump's calculator suggested") == true)
        }
    }

    // MARK: - False positive: exact-recommended carb bolus never fires, regardless of absolute size

    @Test func exactRecommendedNeverFiresRegardlessOfSize() {
        for dose in [0.5, 5.0, 25.0, 80.0] {   // large carb bolus sizes
            let d = StackingGuard.calcOverride(enteredUnits: dose, recommendedUnits: dose,
                                                displaysNumericDose: true, pumpIOBUnits: 1.0,
                                                glucoseMgdl: target + 20, targetMgdl: target)
            #expect(d.friction == .none)
        }
    }

    @Test func underRecommendedNeverFires() {
        let cases: [(entered: Double, recommended: Double)] = [(0.0, 1.0), (1.0, 2.0), (2.0, 7.0)]
        for c in cases {
            let d = StackingGuard.calcOverride(enteredUnits: c.entered, recommendedUnits: c.recommended,
                                                displaysNumericDose: true, pumpIOBUnits: 0,
                                                glucoseMgdl: target + 10, targetMgdl: target)
            #expect(d.friction == .none)
        }
    }

    // MARK: - rec == 0 full-override branch: no ratio, no NaN/inf, no crash

    @Test func fullOverrideAgainstZeroRecommendedDisclosesWithoutRatio() {
        for entered in [0.5, 3.0, 25.0] {
            let d = StackingGuard.calcOverride(enteredUnits: entered, recommendedUnits: 0,
                                                displaysNumericDose: true, pumpIOBUnits: 0,
                                                glucoseMgdl: target + 10, targetMgdl: target)
            #expect(d.friction == .disclose)
            #expect(d.message != nil)
            if let m = d.message {
                #expect(!m.lowercased().contains("nan"))
                #expect(!m.contains("inf"))
            }
        }
    }

    @Test func zeroEnteredAgainstZeroRecommendedNeverFires() {
        let d = StackingGuard.calcOverride(enteredUnits: 0, recommendedUnits: 0,
                                            displaysNumericDose: true, pumpIOBUnits: 0,
                                            glucoseMgdl: target + 10, targetMgdl: target)
        #expect(d.friction == .none)
    }

    // MARK: - displaysNumericDose == false always suppresses (mirrors carbOverrideWarning's §13 Rule-1 guard)

    @Test func hardcodedGuessSuppressesSG1Regardless() {
        for recommended in [0.0, 1.0] {
            let d = StackingGuard.calcOverride(enteredUnits: 10.0, recommendedUnits: recommended,
                                                displaysNumericDose: false, pumpIOBUnits: 0,
                                                glucoseMgdl: target + 30, targetMgdl: target)
            #expect(d.friction == .none)
        }
    }

    // MARK: - glucose at/below target, or absent, never fires

    @Test func glucoseAtOrBelowTargetNeverFires() {
        for glucose in [target, target - 20] {
            let d = StackingGuard.calcOverride(enteredUnits: 5.0, recommendedUnits: 2.0,
                                                displaysNumericDose: true, pumpIOBUnits: 0,
                                                glucoseMgdl: glucose, targetMgdl: target)
            #expect(d.friction == .none)
        }
    }

    @Test func absentGlucoseNeverFires() {
        let d = StackingGuard.calcOverride(enteredUnits: 5.0, recommendedUnits: 2.0,
                                            displaysNumericDose: true, pumpIOBUnits: 0,
                                            glucoseMgdl: nil, targetMgdl: target)
        #expect(d.friction == .none)
    }

    // MARK: - Structural: exactly four Friction cases, no `.block` (compile-time facts pinned here)

    @Test func frictionHasExactlyFourCasesNoBlock() {
        #expect(StackingGuard.Friction.allCases.count == 4)
        // Exhaustive switch over every case — if a `.block` case is ever added, this switch (and every
        // other exhaustive switch over Friction in the codebase) fails to COMPILE until updated, making the
        // addition of a block case a loud, unavoidable build break rather than a silent behavior change.
        for f in StackingGuard.Friction.allCases {
            switch f {
            case .none, .disclose, .confirmExtra, .reenter: break
            }
        }
    }

    // MARK: - Forbidden phrase: no StackingGuard string ever contains "rage bolus"

    @Test func noReturnedStringContainsForbiddenPhrase() {
        let entries: [Double] = [0, 0.5, 1, 2, 5, 10, 25, 80]
        let glucoses: [Int?] = [nil, 50, target, target + 1, target + 50]
        for entered in entries {
            for recommended in entries {
                for glucose in glucoses {
                    for displayable in [true, false] {
                        let d = StackingGuard.calcOverride(enteredUnits: entered, recommendedUnits: recommended,
                                                            displaysNumericDose: displayable, pumpIOBUnits: 1.0,
                                                            glucoseMgdl: glucose, targetMgdl: target)
                        assertNoForbiddenPhrase(d)
                    }
                }
                for ciq in [true, false] {
                    let t = StackingGuard.tempRateOffer(iobUnits: entered, glucoseMgdl: nil, controlIQEnabled: ciq)
                    assertNoForbiddenPhrase(t)
                }
            }
        }
    }

    private func assertNoForbiddenPhrase(_ d: StackingGuard.Disclosure) {
        for s in [d.message, d.detail] {
            if let s {
                #expect(!s.lowercased().contains("rage bolus"))
            }
        }
    }

    // MARK: - SG3b (tempRateOffer): inert under every input in a representative sweep

    @Test func tempRateOfferIsInertUnderRepresentativeSweep() {
        let glucoses: [Int?] = [nil, 100, 200, 300]
        for iob in [0.0, 1.0, 5.0] {
            for glucose in glucoses {
                for ciq in [true, false] {
                    let d = StackingGuard.tempRateOffer(iobUnits: iob, glucoseMgdl: glucose, controlIQEnabled: ciq)
                    #expect(d.friction == .none)
                    #expect(d.message == nil)
                    #expect(d.detail == nil)
                }
            }
        }
    }
}
