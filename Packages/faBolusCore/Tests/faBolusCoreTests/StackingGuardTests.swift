import Testing
@testable import faBolusCore

/// Exhaustive matrix for SG1 (`StackingGuard.calcOverride`) — mirrors `CalcInputGateTests`' nested-loop
/// exhaustive style. Each row pins a safety property; a future edit that reintroduces a false-positive,
/// false-negative, structural, or forbidden-phrase hole fails here rather than shipping.
// `.serialized`: the escalation-boundary tests mutate process-global OSAllocatedUnfairLock-backed
// statics (`confirmExtraOverrideRatio`/`reenterOverrideRatio`); Swift Testing's default concurrent
// scheduling otherwise races them against sibling rows (flaky reds). Mirrors StackingGuardNoticeAckTests.
@Suite(.serialized) struct StackingGuardTests {

    private let target = 120  // arbitrary pump-reported op-115 target for these rows

    // MARK: - SG1 fires: entered > positive recommended, glucose above the pump's own target, displayable dose

    @Test func firesWhenOverridingAboveTargetWithDisplayableDose() {
        let cases: [(entered: Double, recommended: Double)] = [(2.0, 0.5), (5.0, 1.0), (10.0, 9.9)]
        for c in cases {
            let d = StackingGuard.calcOverride(
                enteredUnits: c.entered, recommendedUnits: c.recommended,
                displaysNumericDose: true, pumpIOBUnits: 0.5,
                glucoseMgdl: target + 10, targetMgdl: target)
            #expect(d.friction == .disclose)
            #expect(d.message?.contains("more than the pump's calculator suggested") == true)
        }
    }

    // MARK: - False positive: exact-recommended carb bolus never fires, regardless of absolute size

    @Test func exactRecommendedNeverFiresRegardlessOfSize() {
        for dose in [0.5, 5.0, 25.0, 80.0] {  // large carb bolus sizes
            let d = StackingGuard.calcOverride(
                enteredUnits: dose, recommendedUnits: dose,
                displaysNumericDose: true, pumpIOBUnits: 1.0,
                glucoseMgdl: target + 20, targetMgdl: target)
            #expect(d.friction == .none)
        }
    }

    @Test func underRecommendedNeverFires() {
        let cases: [(entered: Double, recommended: Double)] = [(0.0, 1.0), (1.0, 2.0), (2.0, 7.0)]
        for c in cases {
            let d = StackingGuard.calcOverride(
                enteredUnits: c.entered, recommendedUnits: c.recommended,
                displaysNumericDose: true, pumpIOBUnits: 0,
                glucoseMgdl: target + 10, targetMgdl: target)
            #expect(d.friction == .none)
        }
    }

    // MARK: - rec == 0 full-override branch: no ratio, no NaN/inf, no crash

    @Test func fullOverrideAgainstZeroRecommendedDisclosesWithoutRatio() {
        for entered in [0.5, 3.0, 25.0] {
            let d = StackingGuard.calcOverride(
                enteredUnits: entered, recommendedUnits: 0,
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
        let d = StackingGuard.calcOverride(
            enteredUnits: 0, recommendedUnits: 0,
            displaysNumericDose: true, pumpIOBUnits: 0,
            glucoseMgdl: target + 10, targetMgdl: target)
        #expect(d.friction == .none)
    }

    // MARK: - displaysNumericDose == false always suppresses (mirrors carbOverrideWarning's §13 Rule-1 guard)

    @Test func hardcodedGuessSuppressesSG1Regardless() {
        for recommended in [0.0, 1.0] {
            let d = StackingGuard.calcOverride(
                enteredUnits: 10.0, recommendedUnits: recommended,
                displaysNumericDose: false, pumpIOBUnits: 0,
                glucoseMgdl: target + 30, targetMgdl: target)
            #expect(d.friction == .none)
        }
    }

    // MARK: - glucose at/below target, or absent, never fires

    @Test func glucoseAtOrBelowTargetNeverFires() {
        for glucose in [target, target - 20] {
            let d = StackingGuard.calcOverride(
                enteredUnits: 5.0, recommendedUnits: 2.0,
                displaysNumericDose: true, pumpIOBUnits: 0,
                glucoseMgdl: glucose, targetMgdl: target)
            #expect(d.friction == .none)
        }
    }

    @Test func absentGlucoseNeverFires() {
        let d = StackingGuard.calcOverride(
            enteredUnits: 5.0, recommendedUnits: 2.0,
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
                        let d = StackingGuard.calcOverride(
                            enteredUnits: entered, recommendedUnits: recommended,
                            displaysNumericDose: displayable, pumpIOBUnits: 1.0,
                            glucoseMgdl: glucose, targetMgdl: target)
                        assertNoForbiddenPhrase(d)
                    }
                }
                for ciq in [true, false] {
                    let t = StackingGuard.tempRateOffer(iobUnits: entered, glucoseMgdl: nil, controlIQEnabled: ciq)
                    assertNoForbiddenPhrase(t)
                }
                for max in entries {
                    let sg2 = StackingGuard.maxBolusProximity(enteredUnits: entered, maxBolusUnits: max)
                    assertNoForbiddenPhrase(sg2)
                    for glucose in glucoses {
                        for displayable in [true, false] {
                            let sg3a = StackingGuard.escalation(
                                enteredUnits: entered, recommendedUnits: recommended,
                                displaysNumericDose: displayable, pumpIOBUnits: 1.0,
                                glucoseMgdl: glucose, targetMgdl: target, maxBolusUnits: max)
                            assertNoForbiddenPhrase(sg3a)
                        }
                    }
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

    // MARK: - SG2 (maxBolusProximity): exhaustive entered/max matrix — fire boundary is exactly entered >= max

    @Test func firesAtOrAboveMaxAcrossRepresentativeEnteredMaxPairs() {
        let maxValues: [Double] = [1.0, 5.0, 25.0]
        for max in maxValues {
            let below: [Double] = [0.0, max - 0.5, max - 0.01]
            let atOrAbove: [Double] = [max, max + 0.01, max + 5.0]

            for entered in below {
                let d = StackingGuard.maxBolusProximity(enteredUnits: entered, maxBolusUnits: max)
                #expect(d.friction == .none, "entered \(entered) < max \(max) must not fire")
            }
            for entered in atOrAbove {
                let d = StackingGuard.maxBolusProximity(enteredUnits: entered, maxBolusUnits: max)
                #expect(d.friction == .disclose, "entered \(entered) >= max \(max) must fire")
                #expect(d.message != nil)
            }
        }
    }

    @Test func neverFiresOnZeroOrInvalidMax() {
        let invalidMaxValues: [Double] = [0.0, -1.0, -25.0]
        let enteredValues: [Double] = [0.0, 1.0, 25.0, 80.0]
        for max in invalidMaxValues {
            for entered in enteredValues {
                let d = StackingGuard.maxBolusProximity(enteredUnits: entered, maxBolusUnits: max)
                #expect(d.friction == .none, "invalid max \(max) must never fire regardless of entered \(entered)")
            }
        }
    }

    @Test func maxBolusProximityMessageCitesThePassedMaxAnchor() {
        let d = StackingGuard.maxBolusProximity(enteredUnits: 25.0, maxBolusUnits: 25.0)
        #expect(d.friction == .disclose)
        #expect(d.message?.contains("25") == true)
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

    // MARK: - SG3a (escalation): none when SG1 would not fire — mirrors calcOverride's own guards

    @Test func escalationNoneWhenNeitherSG1NorSG2WouldFire() {
        // Not displayable.
        var d = StackingGuard.escalation(
            enteredUnits: 10.0, recommendedUnits: 1.0, displaysNumericDose: false,
            pumpIOBUnits: 0, glucoseMgdl: target + 50, targetMgdl: target, maxBolusUnits: 25.0)
        #expect(d.friction == .none)

        // Glucose at/below target.
        d = StackingGuard.escalation(
            enteredUnits: 10.0, recommendedUnits: 1.0, displaysNumericDose: true,
            pumpIOBUnits: 0, glucoseMgdl: target, targetMgdl: target, maxBolusUnits: 25.0)
        #expect(d.friction == .none)

        // Absent glucose.
        d = StackingGuard.escalation(
            enteredUnits: 10.0, recommendedUnits: 1.0, displaysNumericDose: true,
            pumpIOBUnits: 0, glucoseMgdl: nil, targetMgdl: target, maxBolusUnits: 25.0)
        #expect(d.friction == .none)

        // Not an override at all (entered <= recommended).
        d = StackingGuard.escalation(
            enteredUnits: 1.0, recommendedUnits: 5.0, displaysNumericDose: true,
            pumpIOBUnits: 0, glucoseMgdl: target + 50, targetMgdl: target, maxBolusUnits: 25.0)
        #expect(d.friction == .none)
    }

    // MARK: - False positive re-assertion: exact-recommended never escalates, regardless of size

    @Test func escalationExactRecommendedNeverFiresRegardlessOfSize() {
        for dose in [0.5, 5.0, 25.0, 80.0] {
            let d = StackingGuard.escalation(
                enteredUnits: dose, recommendedUnits: dose, displaysNumericDose: true,
                pumpIOBUnits: 1.0, glucoseMgdl: target + 20, targetMgdl: target,
                maxBolusUnits: dose)  // even exactly at "max" — still not an override
            #expect(d.friction == .none)
        }
    }

    // MARK: - Escalation ladder: disclose -> confirmExtra -> reenter as the override ratio increases

    @Test func escalationLadderStepsUpMonotonicallyWithOverrideRatio() {
        let recommended = 2.0
        // A representative sweep of increasing entered doses (increasing ratio), max kept high (no SG2
        // contribution) so only the ratio cut-points drive the tier.
        let entered: [Double] = [
            2.5, 2.9,  // ratio 1.25, 1.45           -> disclose
            3.1, 3.9,  // ratio 1.55, 1.95          -> confirmExtra
            4.1, 8.0
        ]  // ratio 2.05, 4.0           -> reenter
        var priorRank = -1
        for e in entered {
            let d = StackingGuard.escalation(
                enteredUnits: e, recommendedUnits: recommended, displaysNumericDose: true,
                pumpIOBUnits: 0, glucoseMgdl: target + 10, targetMgdl: target,
                maxBolusUnits: 1_000.0)
            #expect(d.friction != .none, "entered \(e) over recommended \(recommended) must fire")
            #expect(d.friction.rawValue >= priorRank, "friction must never step DOWN as entered increases")
            priorRank = d.friction.rawValue
        }
        #expect(
            priorRank == StackingGuard.Friction.reenter.rawValue,
            "the largest override in the sweep must reach .reenter")

        // Explicit tier boundaries against the DEFAULT statics (1.5 / 2.0).
        func tier(_ e: Double) -> StackingGuard.Friction {
            StackingGuard.escalation(
                enteredUnits: e, recommendedUnits: recommended, displaysNumericDose: true,
                pumpIOBUnits: 0, glucoseMgdl: target + 10, targetMgdl: target,
                maxBolusUnits: 1_000.0
            ).friction
        }
        #expect(tier(2.5) == .disclose)  // ratio 1.25 < 1.5
        #expect(tier(2.9) == .disclose)  // ratio 1.45 < 1.5
        #expect(tier(3.0) == .confirmExtra)  // ratio 1.50 == cut-point (>=)
        #expect(tier(3.9) == .confirmExtra)  // ratio 1.95 < 2.0
        #expect(tier(4.0) == .reenter)  // ratio 2.00 == cut-point (>=)
        #expect(tier(8.0) == .reenter)
    }

    // MARK: - SG2 contribution: at/over the pump's own max escalates to confirmExtra even at a modest ratio

    @Test func escalationReachesConfirmExtraWhenAtOrAboveMaxEvenAtModestRatio() {
        // ratio 1.1 (entered 2.2 / recommended 2.0) is well below confirmExtraOverrideRatio's default 1.5,
        // but maxBolusUnits == enteredUnits means SG2 (maxBolusProximity) fires — that alone must be enough
        // to reach .confirmExtra.
        let d = StackingGuard.escalation(
            enteredUnits: 2.2, recommendedUnits: 2.0, displaysNumericDose: true,
            pumpIOBUnits: 0, glucoseMgdl: target + 10, targetMgdl: target,
            maxBolusUnits: 2.2)
        #expect(d.friction == .confirmExtra)
    }

    @Test func escalationBelowMaxAtModestRatioStaysAtDisclose() {
        let d = StackingGuard.escalation(
            enteredUnits: 2.2, recommendedUnits: 2.0, displaysNumericDose: true,
            pumpIOBUnits: 0, glucoseMgdl: target + 10, targetMgdl: target,
            maxBolusUnits: 25.0)
        #expect(d.friction == .disclose)
    }

    // MARK: - recommendedUnits == 0 full-override branch: reenter directly, no ratio, no NaN/inf

    @Test func escalationFullOverrideAgainstZeroRecommendedGoesStraightToReenter() {
        for entered in [0.5, 3.0, 25.0] {
            let d = StackingGuard.escalation(
                enteredUnits: entered, recommendedUnits: 0, displaysNumericDose: true,
                pumpIOBUnits: 0, glucoseMgdl: target + 10, targetMgdl: target,
                maxBolusUnits: 25.0)
            #expect(d.friction == .reenter)
            #expect(d.message != nil)
            if let m = d.message {
                #expect(!m.lowercased().contains("nan"))
                #expect(!m.contains("inf"))
            }
        }
    }

    // MARK: - Cut-points are statics, not literals: mutating them shifts the boundary

    @Test func escalationBoundariesTrackTheMutableStaticsNotHardcodedLiterals() {
        let originalConfirmExtra = StackingGuard.confirmExtraOverrideRatio
        let originalReenter = StackingGuard.reenterOverrideRatio
        defer {
            StackingGuard.confirmExtraOverrideRatio = originalConfirmExtra
            StackingGuard.reenterOverrideRatio = originalReenter
        }

        // A ratio of 1.2 sits below the DEFAULT confirmExtra cut-point (1.5) -> disclose.
        var d = StackingGuard.escalation(
            enteredUnits: 2.4, recommendedUnits: 2.0, displaysNumericDose: true,
            pumpIOBUnits: 0, glucoseMgdl: target + 10, targetMgdl: target,
            maxBolusUnits: 1_000.0)
        #expect(d.friction == .disclose)

        // Lower the static below that same ratio (1.2) — the SAME entered/recommended pair must now cross
        // into .confirmExtra, proving the boundary tracks the static rather than a baked-in literal.
        StackingGuard.confirmExtraOverrideRatio = 1.1
        d = StackingGuard.escalation(
            enteredUnits: 2.4, recommendedUnits: 2.0, displaysNumericDose: true,
            pumpIOBUnits: 0, glucoseMgdl: target + 10, targetMgdl: target,
            maxBolusUnits: 1_000.0)
        #expect(d.friction == .confirmExtra)

        // Same for the reenter cut-point: default 2.0 means ratio 1.8 stays at confirmExtra; lowering the
        // static to 1.7 must push that SAME pair to .reenter.
        d = StackingGuard.escalation(
            enteredUnits: 3.6, recommendedUnits: 2.0, displaysNumericDose: true,
            pumpIOBUnits: 0, glucoseMgdl: target + 10, targetMgdl: target,
            maxBolusUnits: 1_000.0)
        #expect(d.friction == .confirmExtra)  // ratio 1.8, still below default reenter cut-point 2.0

        StackingGuard.reenterOverrideRatio = 1.7
        d = StackingGuard.escalation(
            enteredUnits: 3.6, recommendedUnits: 2.0, displaysNumericDose: true,
            pumpIOBUnits: 0, glucoseMgdl: target + 10, targetMgdl: target,
            maxBolusUnits: 1_000.0)
        #expect(d.friction == .reenter)
    }

    // MARK: - Structural re-assertion: SG3a landing still leaves Friction at exactly 4 cases, no .block

    @Test func frictionStillHasExactlyFourCasesNoBlockAfterSG3a() {
        #expect(StackingGuard.Friction.allCases.count == 4)
        for f in StackingGuard.Friction.allCases {
            switch f {
            case .none, .disclose, .confirmExtra, .reenter: break
            }
        }
    }

    // MARK: - insufficientReservoir: non-blocking over-request disclosure, anchored
    // solely on the pump's OWN reservoirUnits read — never a hardcoded threshold.

    @Test func insufficientReservoirFiresWhenEnteredExceedsAValidReservoirReading() {
        let cases: [(entered: Double, reservoir: Double)] = [(5.0, 3.0), (1.0, 0.0), (25.0, 24.99)]
        for c in cases {
            let d = StackingGuard.insufficientReservoir(enteredUnits: c.entered, reservoirUnits: c.reservoir)
            #expect(d.friction == .disclose, "entered \(c.entered) > reservoir \(c.reservoir) must fire")
            #expect(d.message != nil)
        }
    }

    @Test func insufficientReservoirMessageNamesBothEnteredAndReservoirUnits() {
        let d = StackingGuard.insufficientReservoir(enteredUnits: 5.0, reservoirUnits: 3.0)
        #expect(d.friction == .disclose)
        #expect(d.message?.contains("5") == true)
        #expect(d.message?.contains("3") == true)
    }

    @Test func insufficientReservoirBoundaryExactlyEqualNeverFires() {
        let d = StackingGuard.insufficientReservoir(enteredUnits: 3.0, reservoirUnits: 3.0)
        #expect(d == .none)
    }

    @Test func insufficientReservoirBelowReservoirNeverFires() {
        let cases: [(entered: Double, reservoir: Double)] = [(0.0, 1.0), (1.0, 3.0), (2.99, 3.0)]
        for c in cases {
            let d = StackingGuard.insufficientReservoir(enteredUnits: c.entered, reservoirUnits: c.reservoir)
            #expect(d == .none, "entered \(c.entered) <= reservoir \(c.reservoir) must not fire")
        }
    }

    @Test func insufficientReservoirNeverFiresOnInvalidNegativeReservoir() {
        let invalidReservoirValues: [Double] = [-0.01, -1.0, -25.0]
        let enteredValues: [Double] = [0.0, 1.0, 5.0, 80.0]
        for reservoir in invalidReservoirValues {
            for entered in enteredValues {
                let d = StackingGuard.insufficientReservoir(enteredUnits: entered, reservoirUnits: reservoir)
                #expect(d == .none, "invalid reservoir \(reservoir) must never fire regardless of entered \(entered)")
            }
        }
    }

    @Test func insufficientReservoirZeroReservoirIsAValidReadingAndCanFire() {
        // reservoirUnits == 0 is a VALID (empty) reading, distinct from an invalid negative/unread value —
        // any positive entered amount against a truly empty reservoir must still disclose.
        let d = StackingGuard.insufficientReservoir(enteredUnits: 1.0, reservoirUnits: 0.0)
        #expect(d.friction == .disclose)
    }
}
