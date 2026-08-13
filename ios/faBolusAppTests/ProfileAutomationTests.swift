import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// `ProfileAutomation` (999.2, D-02) — proves the `.unverifiedAck` gate (`AccessPolicy.swift:229-232`) is
/// preserved, not weakened, for a headless `ActivateProfileIntent` run: a call with NO fresh in-app
/// acknowledgment reaches the backend ZERO times and returns an honest "open faBolus and confirm to
/// switch profiles" refusal (mirrors `everyTherapyWriteEntryPointIsCentrallyGated`,
/// `AppModelBehaviorTests.swift:692-729`, for this one specific entry point). Also pins setting/bench/
/// capability inertness and the interactive-ack success path, mirroring `TempRateAutomationTests`'
/// injectable-model/clock/capturing-poster harness and `MockBackend(isMobi:)`/`AppSettings` save-restore
/// pattern.
@MainActor
@Suite(.serialized) struct ProfileAutomationTests {

    /// Configure the AppSettings the apply path needs: advanced control on (Gate 5's opt-in axis),
    /// autoProfileActivation on (except the setting-off case, which flips it back), reminders on, nothing
    /// read-only / child-locked. Returns a restore closure so the global singleton is left as found.
    private func configureSettings(autoProfileActivation: Bool = true) -> () -> Void {
        let s = AppSettings.shared
        let saved = (s.advancedControlEnabled, s.appMode, s.autoProfileActivation, s.modeReminders,
                     s.phoneReadOnly, s.childModeEnabled)
        s.advancedControlEnabled = true
        s.appMode = .advanced
        s.autoProfileActivation = autoProfileActivation
        s.modeReminders = true
        s.phoneReadOnly = false
        s.childModeEnabled = false
        return {
            s.advancedControlEnabled = saved.0; s.appMode = saved.1
            s.autoProfileActivation = saved.2; s.modeReminders = saved.3
            s.phoneReadOnly = saved.4; s.childModeEnabled = saved.5
        }
    }

    /// A connected model. `isMobi: false` (`.full` capabilities, `supportsProfiles == false`) exercises
    /// the capability-inert case; `isMobi: true` (`.mobiAdvanced`, `supportsProfiles == true`) exercises
    /// every other case. `MockBackend.setActiveProfile` increments `idpWriteCount` — the same counter
    /// `everyTherapyWriteEntryPointIsCentrallyGated` uses to prove the ack gate bites.
    private func makeConnectedModel(isMobi: Bool) async -> (AppModel, MockBackend) {
        let backend = MockBackend(isMobi: isMobi)
        let model = AppModel(source: backend)
        await backend.connect()
        return (model, backend)
    }

    @Test func settingOffRefusesHonestlyWithoutTouchingTheBackend() async {
        let restore = configureSettings(autoProfileActivation: false); defer { restore() }
        let (model, backend) = await makeConnectedModel(isMobi: true)
        defer { backend.disconnect() }

        let result = await ProfileAutomation.request(idpId: 1, model: model, benchVerified: true)

        #expect(result.contains("turned off"))
        #expect(backend.idpWriteCount == 0)
    }

    @Test func benchUnverifiedShipsInertRegardlessOfCapability() async {
        let restore = configureSettings(); defer { restore() }
        let (model, backend) = await makeConnectedModel(isMobi: true)
        defer { backend.disconnect() }

        // benchVerified defaults to `ProfileAutomation.profileBenchVerifiedDefault` (false) when omitted.
        let result = await ProfileAutomation.request(idpId: 1, model: model)

        #expect(result.contains("bench validation"))
        #expect(backend.idpWriteCount == 0)
    }

    @Test func capabilityUnsupportedRefusesHonestly() async {
        let restore = configureSettings(); defer { restore() }
        let (model, backend) = await makeConnectedModel(isMobi: false)   // .full caps: supportsProfiles == false
        defer { backend.disconnect() }

        let result = await ProfileAutomation.request(idpId: 1, model: model, benchVerified: true)

        #expect(result.contains("doesn't support"))
        #expect(backend.idpWriteCount == 0)
    }

    /// The load-bearing case (D-02, §13): a headless run — no `model.acknowledgeUnverifiedTherapy()`
    /// call anywhere in this test — must fail closed at the SAME centralized `.unverifiedAck` gate every
    /// interactive caller goes through, reaching the backend zero times, with the failure surfaced (never
    /// a silent no-op) and an honest dialog telling the user how to actually complete it.
    @Test func headlessCallWithNoAckRefusesHonestlyAndNeverReachesTheBackend() async {
        let restore = configureSettings(); defer { restore() }
        let (model, backend) = await makeConnectedModel(isMobi: true)
        defer { backend.disconnect() }

        let result = await ProfileAutomation.request(idpId: 1, model: model, benchVerified: true)

        #expect(backend.idpWriteCount == 0)
        #expect(model.lastError != nil)
        #expect(result.contains("open faBolus and confirm to switch profiles"))
    }

    /// The ONLY success route (D-02): documents that the refusal above is the missing ack, not a broken
    /// write path — with a fresh interactive acknowledgment already on record, the exact same call
    /// reaches the backend exactly once.
    @Test func interactiveAckPathReachesTheBackendExactlyOnce() async {
        let restore = configureSettings(); defer { restore() }
        let (model, backend) = await makeConnectedModel(isMobi: true)
        defer { backend.disconnect() }

        model.acknowledgeUnverifiedTherapy()
        let result = await ProfileAutomation.request(idpId: 1, model: model, benchVerified: true)

        #expect(backend.idpWriteCount == 1)
        #expect(model.lastError == nil)
        #expect(result.contains("switched"))
    }
}
