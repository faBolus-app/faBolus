import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// P16 S3 — manual precedence for scheduled activity/sleep mode automation. Drives the REAL
/// `ModeAutomation.request` path against a connected `MockBackend`, with an injected clock and a capturing
/// notification poster, to pin the safety behavior: a scheduled switch DEFERS (queues + posts a
/// suppressible informational reminder) when the user acted manually inside the 60-min window, and applies
/// normally otherwise. It never blocks a user action and never changes a dose — the only difference is
/// whether the automatic switch is withheld and the user is asked. (Mode automation is Mobi-only in
/// practice; the MockBackend presents as a Mobi so the apply path is reachable.)
@MainActor
@Suite(.serialized) struct ModeAutomationPrecedenceTests {

    private let store = UserDefaults(suiteName: WidgetStore.appGroup)
    private let pendingKeys = ["pendingMode.exercise", "pendingMode.exercise.ts",
                               "pendingMode.sleep", "pendingMode.sleep.ts"]
    private func clearPending() { pendingKeys.forEach { store?.removeObject(forKey: $0) } }

    /// Configure the AppSettings the apply path needs: advanced control on + Advanced mode (so the
    /// `.setMode` funnel gate clears), auto-sleep + reminders on, nothing read-only / child-locked.
    /// Returns a restore closure so the global singleton is left as we found it (ModeStoreTests pattern).
    private func configureSettings() -> () -> Void {
        let s = AppSettings.shared
        let saved = (s.advancedControlEnabled, s.appMode, s.autoSleepMode, s.autoExerciseMode,
                     s.modeReminders, s.phoneReadOnly, s.childModeEnabled)
        s.advancedControlEnabled = true
        s.appMode = .advanced
        s.autoSleepMode = true
        s.autoExerciseMode = true
        s.modeReminders = true
        s.phoneReadOnly = false
        s.childModeEnabled = false
        return {
            s.advancedControlEnabled = saved.0; s.appMode = saved.1
            s.autoSleepMode = saved.2; s.autoExerciseMode = saved.3
            s.modeReminders = saved.4; s.phoneReadOnly = saved.5; s.childModeEnabled = saved.6
        }
    }

    /// A connected Mobi-capable model whose setting-change store points at a fresh temp file (empty log),
    /// so `lastManualTherapyActionAt` is governed only by the inputs the test controls.
    private func makeConnectedModel() async -> (AppModel, MockBackend) {
        let backend = MockBackend(isMobi: true)
        let model = AppModel(source: backend)
        model.settingChangeStore = StoredSettingChangeStore(
            url: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("s3-mode-test-\(UUID().uuidString).json"))
        await backend.connect()
        return (model, backend)
    }

    @Test func defersAndNotifiesWhenAManualChangeIsRecent() async {
        let restore = configureSettings(); defer { restore() }
        clearPending(); defer { clearPending() }
        let (model, backend) = await makeConnectedModel()
        defer { backend.disconnect() }

        // The user changed the mode by hand 10 minutes before the scheduled automation fires.
        let manualAt = Date()
        model.noteManualModeChange(at: manualAt)

        var posted: [NotificationBroker.Message] = []
        let result = await ModeAutomation.request(.sleep, enabled: true, model: model,
                                                  now: manualAt.addingTimeInterval(10 * 60),
                                                  post: { posted.append($0) })

        // Did NOT apply — the pump's mode is untouched (still Normal).
        #expect(backend.snapshot.controlIQMode == ControlIQActivity.normal.rawValue)
        // Queued (harmless — the drain also honors precedence) and a SUPPRESSIBLE informational reminder.
        #expect(store?.object(forKey: "pendingMode.sleep") != nil)
        #expect(posted.count == 1)
        #expect(posted.first?.category == .modeReminder)
        #expect(posted.first?.severity == .info)
        #expect(posted.first?.body.contains("wasn't applied") == true)
        #expect(result.contains("manual change recently"))
    }

    @Test func appliesNormallyWhenNoRecentManualChange() async {
        let restore = configureSettings(); defer { restore() }
        clearPending(); defer { clearPending() }
        let (model, backend) = await makeConnectedModel()
        defer { backend.disconnect() }

        // The only manual action is over the window ago (stamp, then advance the clock past 60 min).
        let manualAt = Date()
        model.noteManualModeChange(at: manualAt)

        var posted: [NotificationBroker.Message] = []
        let result = await ModeAutomation.request(.sleep, enabled: true, model: model,
                                                  now: manualAt.addingTimeInterval(60 * 60 + 60),
                                                  post: { posted.append($0) })

        // Applied on the pump — Sleep mode is now active — with no defer/queue and no reminder.
        #expect(backend.snapshot.controlIQMode == ControlIQActivity.sleep.rawValue)
        #expect(store?.object(forKey: "pendingMode.sleep") == nil)
        #expect(posted.isEmpty)
        #expect(result.contains("set on your pump"))
    }
}
