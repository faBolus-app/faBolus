import Testing
import WatchLink

@testable import PhoneApp

/// What Settings says about the watch link.
struct WatchLinkTextTests {
    /// A watch iOS no longer knows (paired again, Garmin Connect reinstalled) says to choose it again; one
    /// merely out of reach says it isn't connected.
    @Test func aWatchIOSNoLongerKnowsSaysToChooseItAgain() {
        var state = WatchLinkState()
        _ = WatchLinkReducer.reduce(&state, .paired(true), now: 0)
        _ = WatchLinkReducer.reduce(&state, .deviceStatus(.notFound), now: 1)
        #expect(state.phase == .unreachable)
        #expect(state.settingsText == "Watch not found. Choose it again in Garmin Connect.")
        _ = WatchLinkReducer.reduce(&state, .deviceStatus(.notConnected), now: 2)
        #expect(state.settingsText == "Not connected")
    }

    @Test func eachPhaseHasItsWords() {
        var state = WatchLinkState()
        #expect(state.settingsText == "No watch chosen")
        _ = WatchLinkReducer.reduce(&state, .paired(true), now: 0)
        _ = WatchLinkReducer.reduce(&state, .deviceStatus(.connected), now: 1)
        _ = WatchLinkReducer.reduce(&state, .characteristicsDiscovered, now: 2)
        #expect(state.settingsText == "Connected")
    }
}
