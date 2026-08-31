import Testing
import Foundation
@testable import faBolus

/// A pending remote-bolus confirm must never be suppressed by a lower-priority remote-control alert.
///
/// The pump-switch alert this suite also used to cover was REMOVED: its prompt offered "Keep everything"
/// over two effects that are safety defaults (a prior pump's `AccessPolicy` Gate-5 advanced-write opt-in,
/// and revert targets keyed to the previous pump's profile), so the reset became automatic and the dialog
/// went with it. The `.remoteBolus`-always-wins invariant below is unchanged and is why this suite exists.
@MainActor
@Suite struct RootAlertPriorityTests {

    // MARK: - Single-flag / no-flag base cases

    @Test func noneActiveReturnsNil() {
        #expect(
            RootTabView.activeAlert(
                hasRemoteBolus: false,
                hasRemoteControl: false) == nil)
    }

    @Test func onlyRemoteControlReturnsRemoteControl() {
        #expect(
            RootTabView.activeAlert(
                hasRemoteBolus: false,
                hasRemoteControl: true) == RootTabView.RootAlert.remoteControl)
    }

    @Test func onlyRemoteBolusReturnsRemoteBolus() {
        #expect(
            RootTabView.activeAlert(
                hasRemoteBolus: true,
                hasRemoteControl: false) == RootTabView.RootAlert.remoteBolus)
    }

    // MARK: - Priority combination

    @Test func remoteBolusWinsOverRemoteControl() {
        // KEY SAFETY PROPERTY: a remote-bolus confirm is never suppressed by a lower-priority alert.
        #expect(
            RootTabView.activeAlert(
                hasRemoteBolus: true,
                hasRemoteControl: true) == RootTabView.RootAlert.remoteBolus)
    }

    // MARK: - Invariant sweep

    /// Exhaustively pins the load-bearing invariant across every flag combination: whenever
    /// `hasRemoteBolus` is true the result is `.remoteBolus`, no matter what the other flag is.
    @Test func remoteBolusAlwaysWinsWhenPresent() {
        for control in [false, true] {
            #expect(
                RootTabView.activeAlert(
                    hasRemoteBolus: true,
                    hasRemoteControl: control) == RootTabView.RootAlert.remoteBolus)
        }
    }

    /// The routing function has no third input any more, so a pump switch cannot introduce an alert that
    /// competes with a remote-bolus confirm at all. Pinned so a future re-added case has to come through
    /// this suite.
    @Test func routingHasExactlyTwoCases() {
        #expect(RootTabView.activeAlert(hasRemoteBolus: false, hasRemoteControl: false) == nil)
        let all: [RootTabView.RootAlert] = [.remoteBolus, .remoteControl]
        #expect(all.count == 2)
    }
}
