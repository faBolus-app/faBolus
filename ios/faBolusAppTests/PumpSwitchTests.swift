import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// B4 (owner 2026-08-09): switching to a DIFFERENT pump (sim↔real, or a different real pump) must reset
/// pump-specific state so two pumps' settings never mix. Pins: the pure 3-way switch decision; that a
/// first-ever connect only records identity (no prompt), a same-pump reconnect stays silent, and a
/// genuinely different pump raises the reset prompt (advancing the handled-identity marker); and that the
/// settings reset turns off the pump-specific prefs AND clears the therapy change-log (whose revert
/// targets are keyed to the PREVIOUS pump). The in-flight-delivery defer uses the SAME predicate as the F1
/// erase gate (`inFlightDeliveryKey` / `computeDeliveryBlockReason`), which is covered by the erase tests.
@Suite(.serialized) @MainActor
struct PumpSwitchTests {

    @Test func decideIsThreeWay() {
        #expect(PumpSwitchStore.decide(current: "sim|mobi", lastHandled: nil) == .firstConnect)
        #expect(PumpSwitchStore.decide(current: "sim|mobi", lastHandled: "sim|mobi") == .samePump)
        #expect(PumpSwitchStore.decide(current: "real|A", lastHandled: "real|B") == .switched)
        #expect(PumpSwitchStore.decide(current: "sim|mobi", lastHandled: "real|A") == .switched)
    }

    private func makeModel() async -> (AppModel, MockBackend) {
        let s = AppSettings.shared
        s.phoneReadOnly = false
        s.childModeEnabled = false
        let backend = MockBackend()
        let ledgerURL = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
            "b4-l-\(UUID().uuidString).json")
        let model = AppModel(source: backend, ledgerStoreURL: ledgerURL)
        model.settingChangeStore = StoredSettingChangeStore(
            url: URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("b4-s-\(UUID().uuidString).json"))
        return (model, backend)
    }

    /// `advancedControlEnabled` is the observable for "did the pump-switch reset run?": it is the one
    /// assignment in `resetPumpRelevantSettings()` with an observable effect (`AccessPolicy` Gate 5's
    /// input). It replaces the old `pendingPumpSwitch` flag, which existed only to drive a prompt that has
    /// since been removed — so a reset that fired spuriously would now be SILENT, and these two tests are
    /// the only thing standing between that and a shipped regression.
    @Test func firstConnectRecordsIdentityWithoutResetting() async {
        PumpSwitchStore.clear()
        defer { PumpSwitchStore.clear() }
        let s = AppSettings.shared
        let saved = s.advancedControlEnabled
        defer { s.advancedControlEnabled = saved }
        let (model, backend) = await makeModel()
        _ = model
        defer { backend.disconnect() }
        s.advancedControlEnabled = true
        await backend.connect()
        #expect(s.advancedControlEnabled == true)  // no prior pump ⇒ nothing to reset
        #expect(PumpSwitchStore.lastHandled() != nil)  // …but the identity is now recorded
    }

    @Test func sameIdentityReconnectDoesNotReset() async {
        PumpSwitchStore.clear()
        defer { PumpSwitchStore.clear() }
        let s = AppSettings.shared
        let saved = s.advancedControlEnabled
        defer { s.advancedControlEnabled = saved }
        let (model, backend) = await makeModel()
        _ = model
        defer { backend.disconnect() }
        await backend.connect()  // firstConnect records identity
        backend.disconnect()
        s.advancedControlEnabled = true
        await backend.connect()  // same pump reconnect → not a switch
        #expect(s.advancedControlEnabled == true)
    }

    @Test func differentPumpIsDetectedAndHandled() async {
        PumpSwitchStore.setHandled("real|SOME-OLD-PUMP-UUID")
        defer { PumpSwitchStore.clear() }
        let (model, backend) = await makeModel()
        defer { backend.disconnect() }
        await backend.connect()  // a sim now, but the marker says a real pump ⇒ switch
        #expect(PumpSwitchStore.lastHandled() != "real|SOME-OLD-PUMP-UUID")  // marker advanced to current
    }

    /// The reset runs AUTOMATICALLY on a confirmed switch (the "Keep everything" prompt was removed —
    /// both effects are safety defaults the user should not be able to decline). ⚠ `remoteBolusCeiling` is
    /// deliberately EXCLUDED: it is a user-set dose cap that survives a pump swap (owner decision
    /// 2026-08-30), and clearing it used to be this function's only observable effect.
    @Test func resetTurnsOffPumpPrefsAndClearsTheChangeLogButKeepsTheDoseCeiling() async {
        let s = AppSettings.shared
        let saved = (
            s.advancedControlEnabled, s.autoSyncPumpTime, s.autoSleepMode,
            s.autoExerciseMode, s.modeReminders, s.remoteBolusCeiling, s.alertRules
        )
        defer {
            s.advancedControlEnabled = saved.0
            s.autoSyncPumpTime = saved.1
            s.autoSleepMode = saved.2
            s.autoExerciseMode = saved.3
            s.modeReminders = saved.4
            s.remoteBolusCeiling = saved.5
            s.alertRules = saved.6
        }
        PumpSwitchStore.clear()
        defer { PumpSwitchStore.clear() }
        let (model, backend) = await makeModel()
        defer { backend.disconnect() }

        s.advancedControlEnabled = true
        s.autoSyncPumpTime = true
        s.autoSleepMode = true
        s.autoExerciseMode = true
        s.modeReminders = true
        s.remoteBolusCeiling = 5
        model.settingChangeStore.record(
            StoredSettingChange(
                key: .global("maxBolus"), before: .double(10), after: .double(12), provenance: .selfSet, atSeconds: 1))
        #expect(!model.settingChangeStore.load().log.isEmpty)

        model.resetPumpRelevantSettingsAfterSwitch()

        #expect(!s.advancedControlEnabled && !s.autoSyncPumpTime && !s.autoSleepMode)
        #expect(!s.autoExerciseMode && !s.modeReminders)
        #expect(s.alertRules.isEmpty)
        #expect(model.settingChangeStore.load().log.isEmpty)  // old pump's revert targets cleared
        // The user's dose CAP survives the switch — it is their safety preference, not pump-derived state.
        #expect(s.remoteBolusCeiling == 5)
    }
}
