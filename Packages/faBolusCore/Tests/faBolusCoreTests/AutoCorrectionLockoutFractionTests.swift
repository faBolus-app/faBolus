import Foundation
import Testing
@testable import faBolusCore

/// T1-5 core: `AutoCorrectionDisclosure.lockoutRemainingFraction` — a pure TIME-FILL fraction (elapsed /
/// documented lockout window, clamped to [0, 1]) proving the "fraction, never units" safety property
/// (D-06 guardrail #1) at the unit level, before any UI renders a countdown bar from it. The fraction fills
/// UP as the lockout expires (0.0 = just started, ~1.0 = about to clear) — it is NOT a draining battery and
/// NOT a percent-of-ceiling. Mirrors the same no-controller / off / unknown-window guard shape the removed
/// S1 lockout disclosure used PLUS a guard of its own: nil once the lockout has actually expired (no active
/// lockout to show).
struct AutoCorrectionLockoutFractionTests {

    private let sixtyMinutesAgo: (Date, Int) -> Date = { now, minutesAgo in
        now.addingTimeInterval(TimeInterval(-minutesAgo * 60))
    }

    // MARK: fraction fills UP as the 60-min Control-IQ lockout window elapses

    @Test func justStartedLockoutIsNearZero() {
        let now = Date()
        let started = sixtyMinutesAgo(now, 0)
        let fraction = AutoCorrectionDisclosure.lockoutRemainingFraction(
            descriptor: .controlIQ, controllerEnabled: true, lockoutStartDate: started, now: now)
        #expect(fraction != nil)
        #expect(abs(fraction! - 0.0) < 0.01)
    }

    @Test func halfwayThroughLockoutIsAroundOneHalf() {
        let now = Date()
        let started = sixtyMinutesAgo(now, 30)
        let fraction = AutoCorrectionDisclosure.lockoutRemainingFraction(
            descriptor: .controlIQ, controllerEnabled: true, lockoutStartDate: started, now: now)
        #expect(fraction != nil)
        #expect(abs(fraction! - 0.5) < 0.01)
    }

    @Test func almostExpiredLockoutIsJustUnderOne() {
        let now = Date()
        let started = sixtyMinutesAgo(now, 59)
        let fraction = AutoCorrectionDisclosure.lockoutRemainingFraction(
            descriptor: .controlIQ, controllerEnabled: true, lockoutStartDate: started, now: now)
        #expect(fraction != nil)
        #expect(abs(fraction! - 0.983) < 0.01)
        #expect(fraction! < 1.0)
    }

    // MARK: expired lockout — no active lockout to disclose (D-06 guardrail #5 fail-closed)

    @Test func exactlyExpiredLockoutIsNil() {
        let now = Date()
        let started = sixtyMinutesAgo(now, 60)
        let fraction = AutoCorrectionDisclosure.lockoutRemainingFraction(
            descriptor: .controlIQ, controllerEnabled: true, lockoutStartDate: started, now: now)
        #expect(fraction == nil)
    }

    @Test func wellPastExpiredLockoutIsNil() {
        let now = Date()
        let started = sixtyMinutesAgo(now, 120)
        let fraction = AutoCorrectionDisclosure.lockoutRemainingFraction(
            descriptor: .controlIQ, controllerEnabled: true, lockoutStartDate: started, now: now)
        #expect(fraction == nil)
    }

    // MARK: clamping — a future/negative-elapsed start date never produces an out-of-range fraction

    @Test func futureLockoutStartClampsToZeroNeverNegative() {
        let now = Date()
        let started = now.addingTimeInterval(5 * 60)  // starts 5 min from now: negative elapsed
        let fraction = AutoCorrectionDisclosure.lockoutRemainingFraction(
            descriptor: .controlIQ, controllerEnabled: true, lockoutStartDate: started, now: now)
        #expect(fraction != nil)
        #expect(fraction! >= 0.0)
        #expect(abs(fraction! - 0.0) < 0.01)
    }

    // MARK: same no-controller/off/unknown-window guard gates (the former S1 lockout disclosure) — always nil, never a stale/frozen bar

    @Test func noControllerNeverProducesAFraction() {
        let now = Date()
        let started = sixtyMinutesAgo(now, 10)
        let fraction = AutoCorrectionDisclosure.lockoutRemainingFraction(
            descriptor: .noController, controllerEnabled: true, lockoutStartDate: started, now: now)
        #expect(fraction == nil)
    }

    @Test func controllerDisabledAtRuntimeNeverProducesAFraction() {
        let now = Date()
        let started = sixtyMinutesAgo(now, 10)
        let fraction = AutoCorrectionDisclosure.lockoutRemainingFraction(
            descriptor: .controlIQ, controllerEnabled: false, lockoutStartDate: started, now: now)
        #expect(fraction == nil)
    }

    @Test func unknownLockoutWindowNeverProducesAFraction() {
        // A capable, enabled controller whose descriptor doesn't document a lockout window.
        let noWindow = ControllerDescriptor(
            variant: .controlIQ, displayName: "Acme Loop",
            automaticCorrection: AutomaticCorrection(enabled: true, blockedByRecentBolusMinutes: nil),
            activityPresets: [], drivingParameters: [],
            targetsUserAdjustable: false, basalModulation: .none)
        let now = Date()
        let started = sixtyMinutesAgo(now, 10)
        let fraction = AutoCorrectionDisclosure.lockoutRemainingFraction(
            descriptor: noWindow, controllerEnabled: true, lockoutStartDate: started, now: now)
        #expect(fraction == nil)
    }

    @Test func absentLockoutStartDateProducesNoFraction() {
        // No lockout currently active/known → nil, not a fabricated 0.0.
        let now = Date()
        let fraction = AutoCorrectionDisclosure.lockoutRemainingFraction(
            descriptor: .controlIQ, controllerEnabled: true, lockoutStartDate: nil, now: now)
        #expect(fraction == nil)
    }

    // MARK: fraction, never units (D-06 guardrail #1) — the return type itself is the proof

    @Test func returnTypeIsAFractionNeverADoseValue() {
        // Compile-time proof: `fraction` below is statically typed `Double?`. A dose/units value in this
        // codebase is never expressed as a bare fractional Double in [0, 1] — this function must never
        // return anything resembling insulin units. The bound checks below are the runtime half of that
        // guarantee: every non-nil result stays within the [0, 1] fraction range, whatever the input.
        let now = Date()
        let started = sixtyMinutesAgo(now, 45)
        let fraction: Double? = AutoCorrectionDisclosure.lockoutRemainingFraction(
            descriptor: .controlIQPlus, controllerEnabled: true, lockoutStartDate: started, now: now)
        #expect(fraction != nil)
        #expect(fraction! >= 0.0 && fraction! <= 1.0)
    }
}
