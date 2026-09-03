import Testing
import Foundation
@testable import faBolus

/// A pending remote-bolus confirm must never be suppressed by a lower-priority remote-control alert.
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

    // MARK: - Both active

    @Test func remoteBolusWinsOverRemoteControl() {
        // KEY SAFETY PROPERTY: a remote-bolus confirm is never suppressed by a remote-control alert.
        #expect(
            RootTabView.activeAlert(
                hasRemoteBolus: true,
                hasRemoteControl: true) == RootTabView.RootAlert.remoteBolus)
    }

    // MARK: - Invariant sweep

    /// Exhaustively pins the load-bearing invariant across both `hasRemoteControl` values: whenever
    /// `hasRemoteBolus` is true the result is `.remoteBolus`, no matter what the other flag is.
    @Test func remoteBolusAlwaysWinsWhenPresent() {
        for control in [false, true] {
            #expect(
                RootTabView.activeAlert(
                    hasRemoteBolus: true,
                    hasRemoteControl: control) == RootTabView.RootAlert.remoteBolus)
        }
    }
}
