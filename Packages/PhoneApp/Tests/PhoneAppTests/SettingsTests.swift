import Alerts
import Foundation
import GlucoseSources
import RemoteHost
import Testing
import WidgetContent
import faBolusCore

@testable import PhoneApp

@MainActor
@Suite struct FirstLaunchWipeTests {
    /// The first launch over the old app removes its settings, App Group files and Keychain items, keeps
    /// this app's own ledger, and runs once.
    @Test func theFirstLaunchRemovesTheOldAppsDataOnce() throws {
        let phone = Phone()
        let domain = "wipe-standard-\(UUID().uuidString)", group = "wipe-group-\(UUID().uuidString)"
        let standard = try #require(UserDefaults(suiteName: domain))
        let groupDefaults = try #require(UserDefaults(suiteName: group))
        defer {
            standard.removePersistentDomain(forName: domain)
            groupDefaults.removePersistentDomain(forName: group)
        }
        standard.set(true, forKey: "garminBolusEnabled")
        groupDefaults.set(Data([1]), forKey: "widgetSnapshot")
        let dir = phone.directory
        for name in ["remote-bolus-ledger.json", "alert-state.json", "bolus-ledger.json"] {
            try Data("{}".utf8).write(to: dir.appendingPathComponent(name))
        }
        var keychainClears = 0
        let wipe = FirstLaunchWipe(
            standard: standard, standardDomain: domain, appGroupID: group, appGroupDirectory: dir,
            clearKeychain: { keychainClears += 1 })
        #expect(wipe.runIfNeeded())
        #expect(standard.object(forKey: "garminBolusEnabled") == nil)
        #expect(UserDefaults(suiteName: group)?.object(forKey: "widgetSnapshot") == nil)
        let left = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(left == ["bolus-ledger.json"])
        #expect(keychainClears == 1)

        standard.set(true, forKey: "garminBolusEnabled")
        #expect(!wipe.runIfNeeded())
        #expect(standard.bool(forKey: "garminBolusEnabled"))
        #expect(keychainClears == 1)
    }

    /// A launch that wiped withdraws every notification the old app left scheduled and clears the history
    /// store; a later launch doesn't.
    @Test func aWipingLaunchWithdrawsTheOldAppsNotifications() async throws {
        let phone = Phone()
        let domain = "wipe-standard-\(UUID().uuidString)"
        let standard = try #require(UserDefaults(suiteName: domain))
        defer { standard.removePersistentDomain(forName: domain) }
        let wipe = FirstLaunchWipe(
            standard: standard, standardDomain: domain, appGroupID: nil, appGroupDirectory: phone.directory,
            clearKeychain: {})
        let first = await phone.launch(wipe: wipe)
        #expect(first.wipedOnLaunch)
        #expect(await phone.notifications.removedAll >= 1)
        let removed = await phone.notifications.removedAll
        await first.shutdown()
        let second = await phone.launch(wipe: wipe)
        #expect(!second.wipedOnLaunch)
        #expect(await phone.notifications.removedAll == removed)
        await second.shutdown()
    }
}

@MainActor
@Suite struct SettingsPersistenceTests {
    @Test func settingsSurviveARelaunch() throws {
        let suite = "settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let s = AppSettings(defaults: defaults)
        s.bolusIncrement = 0.5
        s.carbIncrement = 10
        s.defaultBolusMode = .units
        s.glucoseStaleMinutes = 10
        s.glucoseHideDelayMinutes = 30
        s.pumpStatusStaleMinutes = 30
        s.remoteBolusLimitUnits = 5
        s.garminBolusEnabled = true
        s.liveActivityBolusEnabled = true
        s.detailsOrder = ["autoCorrection", "iob"]
        s.complicationNames = true
        s.watchPlotFloor = 50
        s.watchPlotCeiling = 250
        var layout = LiveActivityLayout()
        layout.style = .classic
        layout.fields = [.glucose, .lastAutoCorrection]
        s.liveActivityLayout = layout
        let r = AppSettings(defaults: defaults)
        #expect(r.bolusIncrement == 0.5)
        #expect(r.carbIncrement == 10)
        #expect(r.defaultBolusMode == .units)
        #expect(r.freshness.glucoseStaleAfter == 600)
        #expect(r.freshness.glucoseHideAfter == 2400)
        #expect(r.freshness.pumpStatusStaleAfter == 1800)
        #expect(r.freshness.insulinOnBoardStaleAfter == FreshnessThresholds.standard.insulinOnBoardStaleAfter)
        #expect(r.freshness.therapyStaleAfter == FreshnessThresholds.standard.therapyStaleAfter)
        #expect(r.remoteBolusLimitUnits == 5)
        #expect(r.garminBolusEnabled)
        #expect(r.liveActivityBolusEnabled)
        #expect(r.access(capabilities: .tslimX2).liveActivityBolusEnabled)
        #expect(r.detailsOrder == ["autoCorrection", "iob"])
        #expect(r.complicationNames)
        #expect(r.watchPlotFloor == 50 && r.watchPlotCeiling == 250)
        #expect(r.liveActivityLayout == layout)
        r.remoteBolusLimitUnits = nil
        #expect(AppSettings(defaults: defaults).remoteBolusLimitUnits == nil)
    }

    /// The defaults a new install starts with: remotes can't bolus, no remote limit, complication names
    /// off, no auto-correction row, no Live Activity and no bolus from it.
    @Test func aNewInstallStartsWithTheSafeDefaults() throws {
        let suite = "settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let s = AppSettings(defaults: defaults)
        #expect(!s.garminBolusEnabled)
        #expect(!s.remotesReadOnly && !s.phoneReadOnly)
        #expect(s.remoteBolusLimitUnits == nil)
        #expect(!s.complicationNames)
        #expect(!s.detailsOrder.contains("autoCorrection"))
        #expect(!s.liveActivityEnabled)
        #expect(!s.liveActivityBolusEnabled)
        #expect(s.freshness == FreshnessThresholds.standard)
        #expect(s.bolusIncrement == 0.05)
    }

    /// A stored value the app can't use reads as its default, never as a dose step it doesn't offer.
    @Test func unusableStoredValuesFallBack() throws {
        let suite = "settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(0.01, forKey: AppSettings.Key.bolusIncrement.rawValue)
        defaults.set(-3.0, forKey: AppSettings.Key.remoteBolusLimitUnits.rawValue)
        defaults.set(["nonsense"], forKey: AppSettings.Key.detailsOrder.rawValue)
        defaults.set(7, forKey: AppSettings.Key.glucoseStaleMinutes.rawValue)
        let s = AppSettings(defaults: defaults)
        #expect(s.bolusIncrement == 0.05)
        #expect(s.remoteBolusLimitUnits == nil)
        #expect(s.detailsOrder == DetailsField.defaultIDs)
        #expect(s.glucoseStaleMinutes == 6)
    }
}

@MainActor
@Suite struct SharedSettingsTests {
    /// The watch's shared preferences are the phone's own settings: a change on the phone reaches the
    /// watch's config, and the windows the watch judges staleness by are the phone's.
    @Test func aPhoneChangeReachesTheWatchConfig() async throws {
        let phone = Phone()
        let model = await phone.launch()
        let before = try #require(model.watch?.config)
        #expect(before.carbStepGrams == 5)
        model.settings.carbIncrement = 10
        model.settings.bolusIncrement = 0.5
        model.settings.glucosePlotCeiling = 400
        model.settings.glucoseStaleMinutes = 10
        model.settings.pumpStatusStaleMinutes = 30
        await phone.settle(model)
        let after = try #require(model.watch?.config)
        #expect(after.carbStepGrams == 10)
        #expect(after.unitsStepMilliunits == 500)
        #expect(after.plotCeilingMgdl == 400)
        #expect(after.glucoseStaleMinutes == 10)
        #expect(after.pumpStatusStaleMinutes == 30)
        #expect(await model.session.freshness == model.settings.freshness)
        #expect(WidgetStore(defaults: phone.settings).load()?.freshness == model.settings.freshness)
        await model.shutdown()
    }

    @Test func watchPreferencesComeFromThePhoneSettings() throws {
        let suite = "settings-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let s = AppSettings(defaults: defaults)
        s.carbIncrement = 15
        s.bolusIncrement = 1
        s.glucosePlotFloor = 50
        s.glucosePlotCeiling = 350
        s.complicationNames = true
        let p = s.watchPreferences
        #expect(p.carbIncrementGrams == 15)
        #expect(p.bolusIncrementUnits == 1)
        #expect(p.glucosePlotFloor == 50 && p.glucosePlotCeiling == 350)
        #expect(p.glucoseDisplayUnit == s.glucoseUnit.wireToken)
        #expect(p.complicationLabels)
    }
}

@MainActor
@Suite struct ShareCredentialTests {
    /// Changing the Share account saves it at once; leaving the password blank keeps the saved one.
    @Test func aShareCredentialChangeIsSavedAndKeepsThePassword() async throws {
        let phone = Phone()
        let model = await phone.launch()
        await model.selectBackupSource(GlucoseSourceRegistry.shareID)
        #expect(model.backupSourceID == GlucoseSourceRegistry.shareID)
        try await model.saveShareAccount(username: "first@example.com", password: "secret-1", region: .us)
        #expect(
            phone.registry.account.credentials
                == ShareCredentials(username: "first@example.com", password: "secret-1", region: .us))
        try await model.saveShareAccount(username: "second@example.com", password: nil, region: .ous)
        #expect(
            phone.registry.account.credentials
                == ShareCredentials(username: "second@example.com", password: "secret-1", region: .ous))
        await model.selectBackupSource(nil)
        #expect(model.backupSourceID == nil)
        await model.shutdown()
    }
}
