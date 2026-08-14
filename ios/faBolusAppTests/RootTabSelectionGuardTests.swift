import Testing
import Foundation
@testable import faBolus

/// **SC3 (Phase 09.2, D-03; T-09.2-07/T-09.2-08).** Pins `RootTabView.resolveSelection(current:phoneReadOnly:)`
/// — the pure guard behind the `.onChange(of: settings.phoneReadOnly)` wiring that stops the user being
/// stranded on the Bolus tab (`tag(1)`) once `phoneReadOnly` hides it. Only tag `1` is conditionally
/// removed (`RootTabView.swift:23-26`); tags 0/2/3/4 are always present and must never be disturbed.
@MainActor
@Suite struct RootTabSelectionGuardTests {

    // MARK: - phoneReadOnly turning ON

    @Test func bolusTabJustHidReturnsDashboard() {
        // Bolus (tag 1) just hid → land on Dashboard (tag 0), never a nonexistent tab.
        #expect(RootTabView.resolveSelection(current: 1, phoneReadOnly: true) == 0)
    }

    @Test func dashboardUnaffectedWhenReadOnlyTurnsOn() {
        #expect(RootTabView.resolveSelection(current: 0, phoneReadOnly: true) == 0)
    }

    @Test func alertsUnaffectedWhenReadOnlyTurnsOn() {
        #expect(RootTabView.resolveSelection(current: 2, phoneReadOnly: true) == 2)
    }

    @Test func settingsUnaffectedWhenReadOnlyTurnsOn() {
        #expect(RootTabView.resolveSelection(current: 4, phoneReadOnly: true) == 4)
    }

    // MARK: - phoneReadOnly OFF / re-enable direction — never disruptive

    @Test func bolusStillValidWhenNotReadOnly() {
        #expect(RootTabView.resolveSelection(current: 1, phoneReadOnly: false) == 1)
    }

    @Test func reenableDirectionDoesNotDisruptCurrentSelection() {
        // Bolus reappearing (phoneReadOnly going false) must not yank the user off whatever tab
        // they're currently on.
        #expect(RootTabView.resolveSelection(current: 0, phoneReadOnly: false) == 0)
    }
}
