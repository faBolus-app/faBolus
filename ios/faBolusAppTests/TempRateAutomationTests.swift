import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// 06-01 tracer — `TempRateAutomation` (999.2, D-01/D-03/D-04 REVISED). Drives the REAL
/// `TempRateAutomation.request` path against a connected `MockBackend`, with an injected clock and a
/// capturing notification poster, pinning: (1) setting/bench/capability inertness, (2) the D-04 REVISED
/// firmware-range validation (refuse out-of-range, NEVER clamp — the same 0-250%/15min-72h bounds the
/// official Tandem Mobi app uses), (3) in-range pass-through to `AppModel.setTempBasal`, and (4) P16-S3
/// manual precedence. Mirrors `ModeAutomationPrecedenceTests`' injectable-model/clock/capturing-poster
/// harness + MockBackend(isMobi:)/AppSettings save-restore pattern.
@MainActor
@Suite(.serialized) struct TempRateAutomationTests {

    /// Configure the AppSettings the apply path needs: advanced control on (Gate 5's opt-in axis),
    /// autoTempRate on (except the setting-off case, which flips it back), reminders on, nothing
    /// read-only / child-locked. Returns a restore closure so the global singleton is left as found.
    private func configureSettings(autoTempRate: Bool = true) -> () -> Void {
        let s = AppSettings.shared
        let saved = (s.advancedControlEnabled, s.appMode, s.autoTempRate, s.modeReminders,
                     s.phoneReadOnly, s.childModeEnabled)
        s.advancedControlEnabled = true
        s.appMode = .advanced
        s.autoTempRate = autoTempRate
        s.modeReminders = true
        s.phoneReadOnly = false
        s.childModeEnabled = false
        return {
            s.advancedControlEnabled = saved.0; s.appMode = saved.1
            s.autoTempRate = saved.2; s.modeReminders = saved.3
            s.phoneReadOnly = saved.4; s.childModeEnabled = saved.5
        }
    }

    /// A connected model whose setting-change store points at a fresh temp file (empty log), so
    /// `lastManualTherapyActionAt` is governed only by the inputs the test controls. `isMobi: false`
    /// (`.full` capabilities, `supportsTempBasal == false`) exercises the capability-inert case;
    /// `isMobi: true` (`.mobiAdvanced`, `supportsTempBasal == true`) exercises every other case.
    /// Control-IQ is turned OFF directly on the backend (mirrors `AppModelBehaviorTests`'
    /// `inverseControlIQPreconditionsRefusedAtFunnel`) since `setTempBasal`'s pre-flight refuses
    /// pre-flight otherwise (D-03a) — MockBackend seeds `controlIQEnabled = true` by default.
    private func makeConnectedModel(isMobi: Bool) async -> (AppModel, MockBackend) {
        let backend = MockBackend(isMobi: isMobi)
        let model = AppModel(source: backend)
        model.settingChangeStore = StoredSettingChangeStore(
            url: URL(fileURLWithPath: NSTemporaryDirectory())
                .appendingPathComponent("temprate-test-\(UUID().uuidString).json"))
        await backend.connect()
        try? await backend.setControlIQ(enabled: false, weightLbs: 0, totalDailyInsulinUnits: 0)
        return (model, backend)
    }

    @Test func settingOffRefusesHonestlyWithoutTouchingTheBackend() async {
        let restore = configureSettings(autoTempRate: false); defer { restore() }
        let (model, backend) = await makeConnectedModel(isMobi: true)
        defer { backend.disconnect() }

        let result = await TempRateAutomation.request(percent: 100, duration: 60, model: model, benchVerified: true)

        #expect(result.contains("turned off"))
        #expect(backend.tempRateWriteCount == 0)
    }

    @Test func benchUnverifiedShipsInertRegardlessOfCapability() async {
        let restore = configureSettings(); defer { restore() }
        let (model, backend) = await makeConnectedModel(isMobi: true)
        defer { backend.disconnect() }

        // benchVerified defaults to `TempRateAutomation.benchVerifiedDefault` (false) when omitted.
        let result = await TempRateAutomation.request(percent: 100, duration: 60, model: model)

        #expect(result.contains("bench validation"))
        #expect(backend.tempRateWriteCount == 0)
    }

    @Test func capabilityUnsupportedRefusesHonestly() async {
        let restore = configureSettings(); defer { restore() }
        let (model, backend) = await makeConnectedModel(isMobi: false)   // .full caps: supportsTempBasal == false
        defer { backend.disconnect() }

        let result = await TempRateAutomation.request(percent: 100, duration: 60, model: model, benchVerified: true)

        #expect(result.contains("doesn't support"))
        #expect(backend.tempRateWriteCount == 0)
    }

    @Test func refusesOverPercentNamingTheAcceptedRangeNeverClamped() async {
        let restore = configureSettings(); defer { restore() }
        let (model, backend) = await makeConnectedModel(isMobi: true)
        defer { backend.disconnect() }

        let result = await TempRateAutomation.request(percent: 300, duration: 60, model: model, benchVerified: true)

        #expect(result.contains("0-250%"))
        #expect(backend.tempRateWriteCount == 0)
    }

    @Test func refusesOverDurationNamingTheAcceptedRange() async {
        let restore = configureSettings(); defer { restore() }
        let (model, backend) = await makeConnectedModel(isMobi: true)
        defer { backend.disconnect() }

        let result = await TempRateAutomation.request(percent: 100, duration: 4321, model: model, benchVerified: true)

        #expect(result.contains("15-4320 minutes"))
        #expect(backend.tempRateWriteCount == 0)
    }

    @Test func refusesUnderDuration() async {
        let restore = configureSettings(); defer { restore() }
        let (model, backend) = await makeConnectedModel(isMobi: true)
        defer { backend.disconnect() }

        let result = await TempRateAutomation.request(percent: 100, duration: 10, model: model, benchVerified: true)

        #expect(result.contains("15-4320 minutes"))
        #expect(backend.tempRateWriteCount == 0)
    }

    @Test func inRangeAppliesPassesThroughToSetTempBasal() async {
        let restore = configureSettings(); defer { restore() }
        let (model, backend) = await makeConnectedModel(isMobi: true)
        defer { backend.disconnect() }

        let result = await TempRateAutomation.request(percent: 150, duration: 60, model: model, benchVerified: true)

        #expect(backend.tempRateWriteCount == 1)
        #expect(model.lastError == nil)
        #expect(result.contains("150% temp rate set for 60 minutes"))
    }

    @Test func atBoundaryInclusiveApplies() async {
        let restore = configureSettings(); defer { restore() }
        let (model, backend) = await makeConnectedModel(isMobi: true)
        defer { backend.disconnect() }

        // Exactly the max of both firmware bounds (250%, 72h = 4320 min) — inclusive, must apply.
        let result = await TempRateAutomation.request(percent: 250, duration: 4320, model: model, benchVerified: true)

        #expect(backend.tempRateWriteCount == 1)
        #expect(model.lastError == nil)
        #expect(result.contains("250% temp rate set for 4320 minutes"))
    }

    @Test func manualPrecedenceDefersAndPostsASuppressibleReminder() async {
        let restore = configureSettings(); defer { restore() }
        let (model, backend) = await makeConnectedModel(isMobi: true)
        defer { backend.disconnect() }

        // The user changed a therapy setting by hand 10 minutes before the macro fires.
        let manualAt = Date()
        model.noteManualModeChange(at: manualAt)

        var posted: [NotificationBroker.Message] = []
        let result = await TempRateAutomation.request(
            percent: 150, duration: 60, model: model,
            now: manualAt.addingTimeInterval(10 * 60), benchVerified: true,
            post: { posted.append($0) })

        #expect(backend.tempRateWriteCount == 0)
        #expect(posted.count == 1)
        #expect(posted.first?.category == .modeReminder)
        #expect(posted.first?.severity == .info)
        #expect(result.contains("manual change recently"))
    }
}
