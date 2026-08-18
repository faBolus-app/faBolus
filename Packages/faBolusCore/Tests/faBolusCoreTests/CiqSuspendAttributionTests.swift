import Testing
import Foundation
@testable import faBolusCore

/// Phase 09.15-05 (T1-2, D-09.1 BINDING fail-closed cause-attribution): pins the pure predicate that
/// decides whether an active basal suspend may be labeled "Control-IQ paused" — the safety-critical
/// nuance distinguishing this from the generic `PumpSnapshot.deliverySuspended` bool, which does NOT
/// know the cause. `ControlIQSuspendAttribution.isCiqAttributedSuspend(controlStateType:)` must return
/// `true` ONLY for the op-179 raw value that means "Control-IQ stopped basal to prevent a low" and
/// `false` for every other known zone AND for any unmapped/unknown raw value — never a guess.
@Suite struct CiqSuspendAttributionTests {

    /// controlStateType == the CIQ-low-suspend value (0, `ControlIQZone.stops`) → predicate true.
    @Test func trueOnlyForTheCiqSuspendState() {
        #expect(ControlIQSuspendAttribution.isCiqAttributedSuspend(controlStateType: 0) == true)
    }

    /// controlStateType == a non-suspend zone (decreases/maintains/increases/delivers) → false. A
    /// suspend attributed to Control-IQ is exactly the "Stops" zone and no other.
    @Test func falseForEveryOtherKnownZone() {
        for raw in [1, 2, 3, 4] {
            #expect(ControlIQSuspendAttribution.isCiqAttributedSuspend(controlStateType: raw) == false)
        }
    }

    /// controlStateType == unknown/unmapped → false (fail-closed, no false CIQ claim) — mirrors
    /// `ControlIQZone.fromControlStateType`'s own unmapped-⇒-nil contract exactly.
    @Test func failsClosedOnUnknownOrUnmappedRawValue() {
        for raw in [-1, 5, 99, 255] {
            #expect(ControlIQSuspendAttribution.isCiqAttributedSuspend(controlStateType: raw) == false)
        }
    }

    // MARK: - elapsedMinutesLabel (pure draw-time formatter, D-08 epoch-not-age convention)

    @Test func elapsedMinutesLabelFormatsWholeMinutesSinceStart() {
        let now = Date()
        let start = now.addingTimeInterval(-8 * 60)
        #expect(ControlIQSuspendAttribution.elapsedMinutesLabel(since: start, now: now) == "8 min")
    }

    /// A future/clock-skewed `start` (elapsed would be negative) clamps to 0, never a negative label.
    @Test func elapsedMinutesLabelClampsAFutureStartToZero() {
        let now = Date()
        let start = now.addingTimeInterval(60)
        #expect(ControlIQSuspendAttribution.elapsedMinutesLabel(since: start, now: now) == "0 min")
    }
}
