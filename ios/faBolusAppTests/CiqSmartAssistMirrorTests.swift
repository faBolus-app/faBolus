import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Phase 09.15-12 (D-07, guardrail #13): the belt-and-suspenders CIQ-awareness toggle-mirror parity
/// test. Proves a remote SUPPRESSES a Control-IQ-awareness feature whose mirrored toggle is OFF even
/// when the corresponding wire FIELD is still present on the command (the "the phone forgot to also
/// gate the field emission" case this plan's threat register calls T-09.15-12-T) — and that a legacy
/// command with the mirror keys entirely absent resolves to the SAME safe default each flag's own
/// `AppSettings` D-07 default already implies (non-suppressing for the always-on features,
/// suppressing for the opt-in ones).
@Suite struct CiqSmartAssistMirrorTests {

    private final class FakeLink: RemoteTransport {
        var onReceive: (@MainActor (RemoteCommand) -> Void)?
        var onReachabilityChange: (@MainActor (Bool) -> Void)?
        var onUndeliverable: (@MainActor (RemoteCommand) -> Void)?
        var isReachable: Bool = true
        func send(_ command: RemoteCommand) {}
    }

    // MARK: - Field present, toggle OFF ⇒ suppressed (belt-and-suspenders, guardrail #13)

    @MainActor
    @Test func stateReadoutFieldsLeakedWhileToggleOffAreSuppressedOnTheClient() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead)
        // The fields leaked even though the toggle says off — exactly the threat this test guards.
        cmd.ciqZone = ControlIQZone.increases.rawValue
        cmd.ciqSuspendedForLow = true
        cmd.ciqSuspendStartEpochSec = Int(Date().timeIntervalSince1970) - 60
        cmd.lastAutoCorrectionEpochSec = Int(Date().timeIntervalSince1970) - 120
        cmd.ciqLastCouldNotDeliverEpochSec = Int(Date().timeIntervalSince1970) - 300
        cmd.ciqStateReadoutsEnabled = false
        m.handle(cmd)
        #expect(m.ciqZone == nil)
        #expect(m.ciqSuspendedForLow == nil)
        #expect(m.ciqSuspendStartDate == nil)
        #expect(m.lastAutoCorrectionDate == nil)
        #expect(m.ciqLastCouldNotDeliverDate == nil)
    }

    @MainActor
    @Test func lockoutBarLeakedWhileToggleOffIsSuppressedOnTheClient() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        m.controllerVariant = .controlIQ
        m.controlIQEnabled = true
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.lockoutUntilEpochSec = Int(Date().timeIntervalSince1970) + 1800  // 30 min from now
        cmd.ciqLockoutCountdownEnabled = false
        m.handle(cmd)
        #expect(m.lockoutUntilDate == nil)
        #expect(m.lockoutRemainingFraction == nil)
        #expect(m.lockoutAvailableAt == nil)
    }

    @MainActor
    @Test func maxBasalReadoutLeakedWhileToggleOffIsSuppressedOnTheClient() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        m.basalRate = 1.0
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.maxBasalUnitsPerHour = 4.0
        cmd.ciqMaxBasalReadoutEnabled = false
        m.handle(cmd)
        #expect(m.maxBasalUnitsPerHour == nil)
        #expect(m.maxBasalReadout == nil)
    }

    @MainActor
    @Test func sleepExerciseFieldsLeakedWhileToggleOffAreSuppressedOnTheClient() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.controlIQMode = 2  // Exercise
        cmd.exerciseTimeRemainingSec = 900
        cmd.inSleepWindow = false
        cmd.ciqSleepExerciseAwarenessEnabled = false
        m.handle(cmd)
        #expect(m.controlIQMode == 0)
        #expect(m.exerciseTimeRemainingSec == nil)
        #expect(m.inSleepWindow == nil)
        #expect(m.sleepWindowStartMinute == nil)
        #expect(m.sleepWindowEndMinute == nil)
        #expect(m.ciqActivityPreset == nil)
        #expect(m.ciqActivityCompactLine == nil)
    }

    // MARK: - Field present, toggle ON ⇒ NOT suppressed (regression guard against over-suppression)

    @MainActor
    @Test func stateReadoutFieldsRenderWhenToggleIsOn() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.ciqZone = ControlIQZone.increases.rawValue
        cmd.ciqStateReadoutsEnabled = true
        m.handle(cmd)
        #expect(m.ciqZone == ControlIQZone.increases.rawValue)
    }

    // MARK: - Legacy absent-key defaults are safe (non-suppressing for always-on, suppressing for opt-in)

    @MainActor
    @Test func legacyCommandWithMirrorKeysAbsentDefaultsToSafeBehaviorPerFeature() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead)  // predates this plan: every mirror key absent
        cmd.ciqZone = ControlIQZone.increases.rawValue
        cmd.lockoutUntilEpochSec = Int(Date().timeIntervalSince1970) + 1800
        cmd.maxBasalUnitsPerHour = 4.0
        cmd.basalRate = 1.0
        cmd.controlIQMode = 2
        cmd.exerciseTimeRemainingSec = 900
        m.controllerVariant = .controlIQ
        m.controlIQEnabled = true
        m.handle(cmd)

        // Always-on-by-default features: absent toggle ⇒ non-suppressing (matches AppSettings default true).
        #expect(m.ciqStateReadoutsEnabled == true)
        #expect(m.ciqLockoutCountdownEnabled == true)
        #expect(m.ciqZone == ControlIQZone.increases.rawValue)
        #expect(m.lockoutUntilDate != nil)

        // Opt-in/OFF-by-default features: absent toggle ⇒ suppressing (matches AppSettings default false).
        #expect(m.ciqMaxBasalReadoutEnabled == false)
        #expect(m.ciqSleepExerciseAwarenessEnabled == false)
        #expect(m.maxBasalUnitsPerHour == nil)
        #expect(m.maxBasalReadout == nil)
        #expect(m.controlIQMode == 0)
        #expect(m.exerciseTimeRemainingSec == nil)
    }

    /// Loading backstop: a freshly-constructed client (before any statusRead) has every mirrored
    /// toggle at its safe default — matching each flag's own `AppSettings` D-07 default exactly.
    @MainActor
    @Test func freshClientBeforeAnyCommandHasSafeToggleDefaults() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        #expect(m.ciqStateReadoutsEnabled == true)
        #expect(m.ciqLockoutCountdownEnabled == true)
        #expect(m.ciqMaxBasalReadoutEnabled == false)
        #expect(m.ciqSleepExerciseAwarenessEnabled == false)
        #expect(m.ciqPlusTempRateEnabled == false)
        #expect(m.ciqCeilingFlagsEnabled == false)
    }
}
