import Testing
@testable import faBolusCore

/// P13c-4: the mode-bitmap collision, typed. Pins the wire numbering (so the driver pass-through stays
/// byte-identical), the state↔command distinction the types exist to enforce, and the two inverse
/// Control-IQ preconditions (modes need CIQ on; a temp rate needs CIQ off).
struct ControlIQModeTests {

    @Test func modeCommandBitmapsMatchTheWire() {
        // Raw values ARE the wire bitmap (and match the kit's SetModesRequest.ModeCommand) — do not renumber.
        #expect(ModeCommand.sleepOn.bitmap == 1)
        #expect(ModeCommand.sleepOff.bitmap == 2)
        #expect(ModeCommand.exerciseOn.bitmap == 3)
        #expect(ModeCommand.exerciseOff.bitmap == 4)
    }

    @Test func activityDecodeIsTotalAndDefaultsNormal() {
        #expect(ControlIQActivity(rawMode: 0) == .normal)
        #expect(ControlIQActivity(rawMode: 1) == .sleep)
        #expect(ControlIQActivity(rawMode: 2) == .exercise)
        // Unknown/garbage state reads as normal, never a crash.
        #expect(ControlIQActivity(rawMode: 99) == .normal)
        #expect(ControlIQActivity(rawMode: -1) == .normal)
    }

    @Test func stateAndCommandDoNotCollideThroughTheTypes() {
        // The whole point: raw `1` is ambiguous (sleep STATE vs sleepOn COMMAND); the types disambiguate.
        #expect(ControlIQActivity(rawMode: 1) == .sleep)       // 1 as a state
        #expect(ModeCommand.sleepOn.bitmap == 1)               // 1 as a command
        #expect(ControlIQActivity(rawMode: 2) == .exercise)    // 2 as a state
        #expect(ModeCommand.sleepOff.bitmap == 2)              // 2 as a command — a DIFFERENT meaning
    }

    @Test func clearCommandReturnsToNormal() {
        #expect(ControlIQActivity.normal.clearCommand == nil)          // nothing to clear
        #expect(ControlIQActivity.sleep.clearCommand == .sleepOff)
        #expect(ControlIQActivity.exercise.clearCommand == .exerciseOff)
    }

    @Test func inversePreconditionsForModeAndTempRate() {
        // Modes require Control-IQ ON.
        #expect(ControlIQPrecondition.modeBlockReason(controlIQEnabled: true) == nil)
        #expect(ControlIQPrecondition.modeBlockReason(controlIQEnabled: false) != nil)
        // A temp rate requires Control-IQ OFF — the exact inverse.
        #expect(ControlIQPrecondition.tempRateBlockReason(controlIQEnabled: false) == nil)
        #expect(ControlIQPrecondition.tempRateBlockReason(controlIQEnabled: true) != nil)
    }
}
