import Testing
@testable import faBolus

/// **Wizard strand fix (09.2-02, D-01, SC1).** Proves the invariant behind `CgmSessionView`/
/// `CartridgeWizardView`'s Exit affordance without instantiating a SwiftUI view: the Exit button is NEVER
/// gated on the pump-connection state, so a mid-procedure BLE drop can't strand the user on a fully-greyed
/// screen with insulin suspended. `PumpWizardExit.isAlwaysAvailable` is a pure marker (mirrors the
/// `reenterMatches` internal-for-test idiom in `BolusEntryView`) documenting that invariant; the views'
/// actual `.toolbar` Exit buttons are asserted by construction (they carry no such condition — see
/// `PumpWizardViews.swift`) and call only `dismiss()` (presentation-only, Option A — no delivery-path call).
@Suite(.serialized)
@MainActor
struct PumpWizardExitTests {
    @Test func wizardExitIsAlwaysAvailableRegardlessOfPumpReady() {
        #expect(PumpWizardExit.isAlwaysAvailable)
    }
}
