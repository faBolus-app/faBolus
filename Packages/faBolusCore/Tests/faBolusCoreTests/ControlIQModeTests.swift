import Testing
@testable import faBolusCore

/// The reported Control-IQ activity, typed so a state is never confused with a mode command.
struct ControlIQModeTests {

    @Test func activityDecodeIsTotalAndDefaultsNormal() {
        #expect(ControlIQActivity(rawMode: 0) == .normal)
        #expect(ControlIQActivity(rawMode: 1) == .sleep)
        #expect(ControlIQActivity(rawMode: 2) == .exercise)
        // Unknown/garbage state reads as normal, never a crash.
        #expect(ControlIQActivity(rawMode: 99) == .normal)
        #expect(ControlIQActivity(rawMode: -1) == .normal)
    }
}
