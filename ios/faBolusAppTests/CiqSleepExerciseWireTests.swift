import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Phase 09.15-10 (T1-9, D-01/D-08/D-09.5): the Sleep/Exercise-awareness primitive-propagation
/// spine — op-179 `exerciseTimeRemainingSeconds` (already decoded, previously dropped) →
/// `PumpSnapshot`/`SleepExerciseAwareness` pure UI wiring of `ControllerDescriptor.activityPresets`
/// → `RemoteCommand` additive-optional wire fields → `validate()` bounds → `RemoteCommandWireFixture`
/// parse/render helpers. Covers: round-trip, legacy absent-key decode, validate bounds,
/// mutual-exclusivity (never both Sleep and Exercise), and fail-closed (controlIQMode 0/absent ⇒
/// no card/timer).
@Suite struct CiqSleepExerciseWireTests {

    // MARK: - SleepExerciseAwareness.activePreset — mutual exclusivity (D-01 T1-9, D-06 #4/#6)

    @Test func normalModeSelectsNoPreset() {
        #expect(SleepExerciseAwareness.activePreset(mode: .normal, descriptor: .controlIQ) == nil)
        #expect(SleepExerciseAwareness.activePreset(mode: .normal, descriptor: .controlIQPlus) == nil)
    }

    @Test func sleepModeSelectsExactlyTheSleepPresetNeverExercise() {
        let preset = SleepExerciseAwareness.activePreset(mode: .sleep, descriptor: .controlIQ)
        #expect(preset?.name == "Sleep")
        #expect(preset?.targetLowMgdl == 112.5)
        #expect(preset?.targetHighMgdl == 120)
        #expect(preset?.automaticCorrectionEnabled == false)
    }

    @Test func exerciseModeSelectsExactlyTheExercisePresetNeverSleep() {
        let preset = SleepExerciseAwareness.activePreset(mode: .exercise, descriptor: .controlIQ)
        #expect(preset?.name == "Exercise")
        #expect(preset?.targetLowMgdl == 140)
        #expect(preset?.targetHighMgdl == 160)
        #expect(preset?.suspendThresholdMgdl == 79)
    }

    /// The CIQ/CIQ+ discriminator (O7): Sleep AutoBolus differs by variant; Exercise does not.
    @Test func sleepAutoBolusDiffersByVariantExerciseDoesNot() {
        let classicSleep = SleepExerciseAwareness.activePreset(mode: .sleep, descriptor: .controlIQ)
        let plusSleep = SleepExerciseAwareness.activePreset(mode: .sleep, descriptor: .controlIQPlus)
        #expect(classicSleep?.automaticCorrectionEnabled == false)
        #expect(plusSleep?.automaticCorrectionEnabled == true)

        let classicExercise = SleepExerciseAwareness.activePreset(mode: .exercise, descriptor: .controlIQ)
        let plusExercise = SleepExerciseAwareness.activePreset(mode: .exercise, descriptor: .controlIQPlus)
        #expect(classicExercise?.automaticCorrectionEnabled == false)
        #expect(plusExercise?.automaticCorrectionEnabled == false)
    }

    @Test func noControllerSelectsNoPresetEvenInSleepOrExerciseMode() {
        #expect(SleepExerciseAwareness.activePreset(mode: .sleep, descriptor: .noController) == nil)
        #expect(SleepExerciseAwareness.activePreset(mode: .exercise, descriptor: .noController) == nil)
    }

    // MARK: - SleepExerciseAwareness.exerciseTimerToStore — mutual-exclusivity gate at the applier

    @Test func exerciseTimerOnlyStoresWhileGenuinelyInExerciseMode() {
        #expect(SleepExerciseAwareness.exerciseTimerToStore(mode: .exercise, rawRemainingSeconds: 300) == 300)
        #expect(SleepExerciseAwareness.exerciseTimerToStore(mode: .sleep, rawRemainingSeconds: 300) == nil)
        #expect(SleepExerciseAwareness.exerciseTimerToStore(mode: .normal, rawRemainingSeconds: 300) == nil)
    }

    @Test func exerciseTimerZeroOrNegativeNeverStoresAFakeCountdown() {
        #expect(SleepExerciseAwareness.exerciseTimerToStore(mode: .exercise, rawRemainingSeconds: 0) == nil)
    }

    // MARK: - Fact-line formatting (pure UI wiring of activityPresets — D-06 guardrail #4)

    @Test func targetAutoBolusLineReadsRealDescriptorNumbersNoLiteralInCode() {
        let sleepPreset = SleepExerciseAwareness.activePreset(mode: .sleep, descriptor: .controlIQ)!
        #expect(SleepExerciseAwareness.targetAutoBolusLine(sleepPreset) == "Target 112.5–120 mg/dL · AutoBolus off")

        let exercisePreset = SleepExerciseAwareness.activePreset(mode: .exercise, descriptor: .controlIQPlus)!
        #expect(SleepExerciseAwareness.targetAutoBolusLine(exercisePreset) == "Target 140–160 mg/dL · AutoBolus off")
    }

    @Test func suspendThresholdLineOmittedWhenPresetHasNoneSleepToday() {
        let sleepPreset = SleepExerciseAwareness.activePreset(mode: .sleep, descriptor: .controlIQ)!
        #expect(SleepExerciseAwareness.suspendThresholdLine(sleepPreset) == nil)

        let exercisePreset = SleepExerciseAwareness.activePreset(mode: .exercise, descriptor: .controlIQ)!
        #expect(SleepExerciseAwareness.suspendThresholdLine(exercisePreset) == "Suspends below 79 mg/dL")
    }

    @Test func remainingLabelFormatsHoursAndMinutesFailsClosedOnNonPositive() {
        #expect(SleepExerciseAwareness.remainingLabel(seconds: 4 * 3600 + 20 * 60) == "4h 20m remaining")
        #expect(SleepExerciseAwareness.remainingLabel(seconds: 5 * 60) == "5m remaining")
        #expect(SleepExerciseAwareness.remainingLabel(seconds: 0) == nil)
        #expect(SleepExerciseAwareness.remainingLabel(seconds: -1) == nil)
        #expect(SleepExerciseAwareness.remainingLabel(seconds: nil) == nil)
    }

    @Test func endsAtLabelComputesTwelveHourClockFromDurationFailsClosedOnNonPositive() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 8, day: 17, hour: 13, minute: 0))!
        // 13:00 + 4h20m = 17:20 -> "5:20" (12-hour, no AM/PM).
        #expect(SleepExerciseAwareness.endsAtLabel(seconds: 4 * 3600 + 20 * 60, now: now, calendar: cal) == "ends 5:20")
        #expect(SleepExerciseAwareness.endsAtLabel(seconds: 0, now: now, calendar: cal) == nil)
        #expect(SleepExerciseAwareness.endsAtLabel(seconds: nil, now: now, calendar: cal) == nil)
    }

    // MARK: - compactLine (D-09.5 remote-first form) — mutual exclusivity + fail-closed

    @Test func compactLineIsNilInNormalMode() {
        #expect(
            SleepExerciseAwareness.compactLine(
                mode: .normal, descriptor: .controlIQ,
                exerciseTimeRemainingSec: 300) == nil)
    }

    @Test func compactLineForSleepNeverMentionsExerciseFacts() {
        let line = SleepExerciseAwareness.compactLine(
            mode: .sleep, descriptor: .controlIQ,
            exerciseTimeRemainingSec: nil)
        #expect(line == "Sleep — AutoBolus off")
    }

    @Test func compactLineForExerciseIsAbsentWithoutAKnownTimer() {
        let line = SleepExerciseAwareness.compactLine(
            mode: .exercise, descriptor: .controlIQ,
            exerciseTimeRemainingSec: nil)
        #expect(line == nil)
    }

    @Test func compactLineForExerciseShowsEndsAtWhenTimerKnown() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 8, day: 17, hour: 13, minute: 0))!
        let line = SleepExerciseAwareness.compactLine(
            mode: .exercise, descriptor: .controlIQ,
            exerciseTimeRemainingSec: 4 * 3600 + 20 * 60,
            now: now, calendar: cal)
        #expect(line == "Exercise — ends 5:20")
    }

    // MARK: - SleepWindowDerivation — pure window math (b) pump-communicated, no clinical literal

    private func utcCalendar() -> Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    /// 2026-08-17 is a Monday.
    @Test func activeWindowFindsASameDayEnabledSlotOnItsWeekday() {
        let cal = utcCalendar()
        let now = cal.date(from: DateComponents(year: 2026, month: 8, day: 17, hour: 23, minute: 0))!  // Monday 23:00
        let slot = PumpSleepScheduleSlot(
            slot: 0, enabled: true, activeDays: 1,  // Monday only
            startMinute: 22 * 60, endMinute: 23 * 60 + 30)
        let window = SleepWindowDerivation.activeWindow(slots: [slot], now: now, calendar: cal)
        #expect(window?.startMinute == 22 * 60)
        #expect(window?.endMinute == 23 * 60 + 30)
    }

    @Test func activeWindowIsNilOutsideTheConfiguredMinutes() {
        let cal = utcCalendar()
        let now = cal.date(from: DateComponents(year: 2026, month: 8, day: 17, hour: 12, minute: 0))!  // Monday noon
        let slot = PumpSleepScheduleSlot(
            slot: 0, enabled: true, activeDays: 1,
            startMinute: 22 * 60, endMinute: 23 * 60 + 30)
        #expect(SleepWindowDerivation.activeWindow(slots: [slot], now: now, calendar: cal) == nil)
    }

    @Test func activeWindowIsNilForADisabledSlotEvenInsideItsMinutes() {
        let cal = utcCalendar()
        let now = cal.date(from: DateComponents(year: 2026, month: 8, day: 17, hour: 23, minute: 0))!
        let slot = PumpSleepScheduleSlot(
            slot: 0, enabled: false, activeDays: 1,
            startMinute: 22 * 60, endMinute: 23 * 60 + 30)
        #expect(SleepWindowDerivation.activeWindow(slots: [slot], now: now, calendar: cal) == nil)
    }

    /// A midnight-spanning window (22:00 Monday -> 06:00 Tuesday): active both "tonight" (Monday,
    /// checked against Monday's day-bit) and "this morning" (checked against Monday's day-bit from
    /// Tuesday's clock, since the slot's day-of-week names the START day).
    @Test func activeWindowHandlesAMidnightSpanningSlotOnBothSides() {
        let cal = utcCalendar()
        let slot = PumpSleepScheduleSlot(
            slot: 0, enabled: true, activeDays: 1,  // Monday
            startMinute: 22 * 60, endMinute: 6 * 60)
        let tonight = cal.date(from: DateComponents(year: 2026, month: 8, day: 17, hour: 23, minute: 0))!  // Mon 23:00
        #expect(SleepWindowDerivation.activeWindow(slots: [slot], now: tonight, calendar: cal) != nil)
        let thisMorning = cal.date(from: DateComponents(year: 2026, month: 8, day: 18, hour: 3, minute: 0))!  // Tue 03:00
        #expect(SleepWindowDerivation.activeWindow(slots: [slot], now: thisMorning, calendar: cal) != nil)
        let afterEnd = cal.date(from: DateComponents(year: 2026, month: 8, day: 18, hour: 7, minute: 0))!  // Tue 07:00
        #expect(SleepWindowDerivation.activeWindow(slots: [slot], now: afterEnd, calendar: cal) == nil)
    }

    @Test func activeWindowRespectsTheDayBitEvenWithinTheMinuteRange() {
        let cal = utcCalendar()
        // Slot only active on Sunday (bit 6) — 2026-08-17 is a Monday, so no match even though the
        // clock time is inside the configured minute range.
        let slot = PumpSleepScheduleSlot(
            slot: 0, enabled: true, activeDays: 1 << 6,
            startMinute: 22 * 60, endMinute: 23 * 60 + 30)
        let now = cal.date(from: DateComponents(year: 2026, month: 8, day: 17, hour: 23, minute: 0))!
        #expect(SleepWindowDerivation.activeWindow(slots: [slot], now: now, calendar: cal) == nil)
    }

    // MARK: - PumpSnapshot computed properties — the mutual-exclusivity choke point

    @Test func snapshotCiqActivityPresetIsNilWhenControlIQModeIsNormal() {
        var snap = PumpSnapshot()
        snap.controlIQMode = 0
        snap.controllerVariant = .controlIQ
        #expect(snap.ciqActivityPreset == nil)
        #expect(snap.ciqActivityCompactLine == nil)
    }

    @Test func snapshotSelectsExactlyOnePresetNeverBoth() {
        var snap = PumpSnapshot()
        snap.controllerVariant = .controlIQ
        snap.controlIQMode = 1  // sleep
        #expect(snap.ciqActivityPreset?.name == "Sleep")
        snap.controlIQMode = 2  // exercise
        #expect(snap.ciqActivityPreset?.name == "Exercise")
    }

    @Test func snapshotSleepWindowLineOmittedWithoutAllThreeFields() {
        var snap = PumpSnapshot()
        snap.inSleepWindow = true
        snap.sleepWindowStartMinute = 22 * 60
        // sleepWindowEndMinute left nil ⇒ line omitted (partial-state fail-closed).
        #expect(snap.ciqSleepWindowLine == nil)

        snap.sleepWindowEndMinute = 6 * 60
        #expect(snap.ciqSleepWindowLine == "Current window: 22:00–06:00")
    }

    // MARK: - RemoteCommand wire — round-trip + legacy absent-key decode

    @Test func allFiveFieldsRoundTripThroughJSONUnchanged() throws {
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.controlIQMode = 2
        cmd.exerciseTimeRemainingSec = 1500
        cmd.inSleepWindow = true
        cmd.sleepWindowStartMinute = 1320
        cmd.sleepWindowEndMinute = 360
        let data = try cmd.encoded()
        let back = try RemoteCommand.decode(data)
        #expect(back.controlIQMode == 2)
        #expect(back.exerciseTimeRemainingSec == 1500)
        #expect(back.inSleepWindow == true)
        #expect(back.sleepWindowStartMinute == 1320)
        #expect(back.sleepWindowEndMinute == 360)
        let validated = try RemoteCommand.decodeValidated(data)
        #expect(validated.controlIQMode == 2)
    }

    @Test func legacyJsonWithoutAnyOfTheFiveKeysDecodesFine() throws {
        let legacyJson = #"{"version":1,"kind":"statusRead","requestId":"r1"}"#
        let data = Data(legacyJson.utf8)
        let cmd = try RemoteCommand.decode(data)
        #expect(cmd.controlIQMode == nil)
        #expect(cmd.exerciseTimeRemainingSec == nil)
        #expect(cmd.inSleepWindow == nil)
        #expect(cmd.sleepWindowStartMinute == nil)
        #expect(cmd.sleepWindowEndMinute == nil)
        let validated = try RemoteCommand.decodeValidated(data)
        #expect(validated.controlIQMode == nil)
    }

    // MARK: - RemoteCommand.validate() bounds

    @Test func validateRejectsControlIQModeOutsideThePumpsThreeStates() {
        for bogus in [-1, 3, 99] {
            var cmd = RemoteCommand(kind: .statusRead)
            cmd.controlIQMode = bogus
            #expect(throws: RemoteCommand.ValidationError.outOfRange("controlIQMode")) {
                try cmd.validate()
            }
        }
        for ok in [0, 1, 2] {
            var cmd = RemoteCommand(kind: .statusRead)
            cmd.controlIQMode = ok
            #expect(throws: Never.self) { try cmd.validate() }
        }
    }

    @Test func validateRejectsExerciseTimeRemainingSecOutOfBounds() {
        var negative = RemoteCommand(kind: .statusRead)
        negative.exerciseTimeRemainingSec = -1
        #expect(throws: RemoteCommand.ValidationError.outOfRange("exerciseTimeRemainingSec")) {
            try negative.validate()
        }
        var tooLarge = RemoteCommand(kind: .statusRead)
        tooLarge.exerciseTimeRemainingSec = 24 * 60 * 60 + 1
        #expect(throws: RemoteCommand.ValidationError.outOfRange("exerciseTimeRemainingSec")) {
            try tooLarge.validate()
        }
        var ok = RemoteCommand(kind: .statusRead)
        ok.exerciseTimeRemainingSec = 24 * 60 * 60
        #expect(throws: Never.self) { try ok.validate() }
    }

    @Test func validateRejectsSleepWindowMinutesOutsideMinuteOfDay() {
        for field in ["start", "end"] {
            var cmd = RemoteCommand(kind: .statusRead)
            if field == "start" { cmd.sleepWindowStartMinute = 1440 } else { cmd.sleepWindowEndMinute = -1 }
            let name = field == "start" ? "sleepWindowStartMinute" : "sleepWindowEndMinute"
            #expect(throws: RemoteCommand.ValidationError.outOfRange(name)) { try cmd.validate() }
        }
        var ok = RemoteCommand(kind: .statusRead)
        ok.sleepWindowStartMinute = 0
        ok.sleepWindowEndMinute = 1439
        #expect(throws: Never.self) { try ok.validate() }
    }

    // MARK: - RemoteCommandWireFixture — fail-closed default + parse + mutual exclusivity

    private final class FakeLink: RemoteTransport {
        var onReceive: (@MainActor (RemoteCommand) -> Void)?
        var onReachabilityChange: (@MainActor (Bool) -> Void)?
        var onUndeliverable: (@MainActor (RemoteCommand) -> Void)?
        var isReachable: Bool = true
        func send(_ command: RemoteCommand) {}
    }

    /// Loading backstop: a freshly-constructed client BEFORE any `handle(cmd)` has `controlIQMode`
    /// at its safe `0` default — a fresh app launch before the first statusRead reply must show no
    /// T1-9 card/timer, never a stale/fabricated one.
    @MainActor
    @Test func freshClientHasControlIQModeZeroAndNoActivityPreset() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        #expect(m.controlIQMode == 0)
        #expect(m.ciqActivityPreset == nil)
        #expect(m.ciqActivityCompactLine == nil)
        #expect(m.exerciseTimeRemainingSec == nil)
    }

    @MainActor
    @Test func handleAdoptsControlIQModeAndExerciseTimer() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        m.controllerVariant = .controlIQ
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.controlIQMode = 2
        cmd.exerciseTimeRemainingSec = 1500
        // Phase 09.15-12 (D-07 belt-and-suspenders): the awareness toggle must be explicitly ON for
        // these fields to render on the client — this test proves the raw parse mechanics, not the
        // toggle-suppression behavior (covered by CiqSmartAssistMirrorTests).
        cmd.ciqSleepExerciseAwarenessEnabled = true
        m.handle(cmd)
        #expect(m.controlIQMode == 2)
        #expect(m.exerciseTimeRemainingSec == 1500)
        #expect(m.ciqActivityPreset?.name == "Exercise")
    }

    /// SP-5 fail-closed: once Exercise HAS been shown, a later statusRead reporting mode back to
    /// normal (0) MUST clear the client's stored mode/timer too — never a stale card surviving past
    /// the moment the pump's own state changed.
    @MainActor
    @Test func aLaterNormalModeClearsAPreviouslyKnownExerciseState() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        m.controllerVariant = .controlIQ
        var active = RemoteCommand(kind: .statusRead)
        active.controlIQMode = 2
        active.exerciseTimeRemainingSec = 900
        // Phase 09.15-12 (D-07 belt-and-suspenders): see note above.
        active.ciqSleepExerciseAwarenessEnabled = true
        m.handle(active)
        #expect(m.ciqActivityPreset?.name == "Exercise")

        var normal = RemoteCommand(kind: .statusRead)
        normal.controlIQMode = 0  // exerciseTimeRemainingSec absent ⇒ nil
        normal.ciqSleepExerciseAwarenessEnabled = true
        m.handle(normal)
        #expect(m.controlIQMode == 0)
        #expect(m.exerciseTimeRemainingSec == nil)
        #expect(m.ciqActivityPreset == nil)
        #expect(m.ciqActivityCompactLine == nil)
    }

    /// Watch does not render the Sleep window text (D-09.5 explicit scope) even though it IS
    /// parsed on the shared `RemoteCommandWireFixture` base — this test pins that the DATA is present so a
    /// future Mac-only renderer can read it, while documenting (via the SUMMARY) that no Watch view
    /// consumes it this plan.
    @MainActor
    @Test func sleepWindowFieldsParseOnTheSharedBaseEvenThoughWatchDoesNotRenderThem() {
        let m = RemoteCommandWireFixture(link: FakeLink())
        var cmd = RemoteCommand(kind: .statusRead)
        cmd.inSleepWindow = true
        cmd.sleepWindowStartMinute = 1320
        cmd.sleepWindowEndMinute = 360
        // Phase 09.15-12 (D-07 belt-and-suspenders): see note above.
        cmd.ciqSleepExerciseAwarenessEnabled = true
        m.handle(cmd)
        #expect(m.ciqSleepWindowLine == "Current window: 22:00–06:00")
    }
}
