import Testing
import Foundation
@testable import faBolus

/// **WR-03 / VA-23 (commit cecd4ad).** Pins `RootTabView.activeAlert(hasRemoteBolus:hasRemoteControl:pumpSwitch:)`
/// — the pure static resolver that arbitrates three stacked SwiftUI `.alert`s (`RootTabView.swift:32-38`)
/// so the high-stakes remote-bolus confirm can never be the one dropped. Priority is a strict cascade:
/// remoteBolus > remoteControl > pumpSwitch.
///
/// LOAD-BEARING INVARIANT: whenever `hasRemoteBolus` is true, the result is `.remoteBolus` regardless of
/// the other two flags. A pending remote-bolus confirmation must NEVER be suppressed by a lower-priority
/// remote-control or pump-switch alert.
@MainActor
@Suite struct RootAlertPriorityTests {

    // MARK: - Single-flag / no-flag base cases

    @Test func noneActiveReturnsNil() {
        #expect(RootTabView.activeAlert(hasRemoteBolus: false,
                                        hasRemoteControl: false,
                                        pumpSwitch: false) == nil)
    }

    @Test func onlyPumpSwitchReturnsPumpSwitch() {
        #expect(RootTabView.activeAlert(hasRemoteBolus: false,
                                        hasRemoteControl: false,
                                        pumpSwitch: true) == RootTabView.RootAlert.pumpSwitch)
    }

    @Test func onlyRemoteControlReturnsRemoteControl() {
        #expect(RootTabView.activeAlert(hasRemoteBolus: false,
                                        hasRemoteControl: true,
                                        pumpSwitch: false) == RootTabView.RootAlert.remoteControl)
    }

    @Test func onlyRemoteBolusReturnsRemoteBolus() {
        #expect(RootTabView.activeAlert(hasRemoteBolus: true,
                                        hasRemoteControl: false,
                                        pumpSwitch: false) == RootTabView.RootAlert.remoteBolus)
    }

    // MARK: - Two-flag priority combinations

    @Test func remoteBolusWinsOverRemoteControl() {
        // Bolus outranks remote-control.
        #expect(RootTabView.activeAlert(hasRemoteBolus: true,
                                        hasRemoteControl: true,
                                        pumpSwitch: false) == RootTabView.RootAlert.remoteBolus)
    }

    @Test func remoteBolusWinsOverPumpSwitch() {
        // KEY SAFETY PROPERTY: a remote-bolus confirm is never suppressed by a pump-switch alert.
        #expect(RootTabView.activeAlert(hasRemoteBolus: true,
                                        hasRemoteControl: false,
                                        pumpSwitch: true) == RootTabView.RootAlert.remoteBolus)
    }

    @Test func remoteControlWinsOverPumpSwitch() {
        #expect(RootTabView.activeAlert(hasRemoteBolus: false,
                                        hasRemoteControl: true,
                                        pumpSwitch: true) == RootTabView.RootAlert.remoteControl)
    }

    // MARK: - All three active

    @Test func allActiveReturnsRemoteBolus() {
        // With every alert pending, the remote-bolus confirm still wins.
        #expect(RootTabView.activeAlert(hasRemoteBolus: true,
                                        hasRemoteControl: true,
                                        pumpSwitch: true) == RootTabView.RootAlert.remoteBolus)
    }

    // MARK: - Invariant sweep

    /// Exhaustively pins the load-bearing invariant across all 8 flag combinations: whenever
    /// `hasRemoteBolus` is true the result is `.remoteBolus`, no matter what the other two flags are.
    @Test func remoteBolusAlwaysWinsWhenPresent() {
        for control in [false, true] {
            for pump in [false, true] {
                #expect(RootTabView.activeAlert(hasRemoteBolus: true,
                                                hasRemoteControl: control,
                                                pumpSwitch: pump) == RootTabView.RootAlert.remoteBolus)
            }
        }
    }
}
