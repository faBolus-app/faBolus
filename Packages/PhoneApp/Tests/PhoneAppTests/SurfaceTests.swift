import Foundation
import PumpScript
import Testing
import Alerts
import WidgetContent
import faBolusCore

@testable import PhoneApp

@MainActor
@Suite struct SurfaceTests {
    /// The backup source hears that the pump's glucose went stale even when no new reading arrives: the
    /// pump keeps answering other reads, and the reading just ages.
    @Test func theBackupSourceIsToldWhenThePumpsGlucoseAgesOut() async {
        let phone = Phone()
        let model = await phone.launch()
        _ = await phone.until(model) { model.pump.link == .connected }
        let source = RecordingSource()
        model.backupSource = source
        await phone.run(model, for: 30)
        #expect(await source.primaryHealthy.last == true)
        phone.mock.pump.glucose = nil
        await phone.run(model, for: model.freshness.glucoseStaleAfter + 60, step: 5)
        #expect(model.pump.isGlucoseStale(thresholds: model.freshness, now: model.now))
        #expect(await source.primaryHealthy.last == false)
        model.backupSource = nil
        await model.shutdown()
    }

    /// Turning the Live Activity on in the foreground starts it, and routine pump reads after that don't
    /// update it again and again.
    @Test func theLiveActivityStartsFromSettingsAndIsntFlooded() async {
        let phone = Phone()
        let activity = RecordingLiveActivity()
        let model = await phone.launch(liveActivity: activity)
        _ = await phone.until(model) { model.pump.link == .connected }
        #expect(activity.shown.isEmpty)
        model.settings.liveActivityEnabled = true
        await phone.settle(model)
        #expect(activity.isRunning)
        #expect(activity.shown.last?.appActive == true)
        // The script re-dates its glucose at every read; a real CGM's reading changes every five minutes.
        phone.mock.pump.glucose = nil
        let before = activity.shown.count
        await phone.run(model, for: 120)
        #expect(activity.shown.count - before <= 3, "updated \(activity.shown.count - before) times in two minutes")
        await model.shutdown()
    }

    /// The Live Activity's plot covers the window the user picked, not just the widgets' two hours.
    @Test func theLiveActivityPlotsItsOwnWindow() async {
        let phone = Phone()
        addGlucoseHistory(phone.mock.pump, count: 72)
        let activity = RecordingLiveActivity()
        let model = await phone.launch(liveActivity: activity)
        _ = await phone.until(model) { model.pump.link == .connected }
        await phone.mock.syncHistory(model)
        model.settings.liveActivityLayout.plotRangeHours = 6
        model.settings.liveActivityEnabled = true
        await phone.settle(model)
        let points = activity.shown.last?.content.snapshot.recent ?? []
        #expect(points.count > 24)
        #expect((points.first?.t).map { model.now.timeIntervalSince($0) > 5 * 3600 } == true)
        await model.shutdown()
    }

    /// A shortcut turns the Live Activity on and off through the settings screen's own switch: the setting
    /// is saved, the Live Activity starts and ends at once, the bolus switch keeps its value and the pump is
    /// sent nothing.
    @Test func aShortcutTurnsTheLiveActivityOnAndOffThroughItsSetting() async {
        let phone = Phone()
        let activity = RecordingLiveActivity()
        let model = await phone.launch(liveActivity: activity)
        _ = await phone.until(model) { model.pump.link == .connected }
        model.settings.liveActivityBolusEnabled = true
        await phone.settle(model)

        model.setLiveActivityEnabled(true)
        #expect(activity.isRunning)
        #expect(activity.shown.last?.appActive == true)
        #expect(AppSettings(defaults: phone.settings).liveActivityEnabled)
        await phone.settle(model)
        #expect(activity.isRunning)

        model.setLiveActivityEnabled(false)
        #expect(!activity.isRunning)
        #expect(!AppSettings(defaults: phone.settings).liveActivityEnabled)
        await phone.settle(model)
        #expect(!activity.isRunning)

        #expect(model.settings.liveActivityBolusEnabled)
        #expect(phone.mock.pump.grantedPermission == nil)
        #expect(phone.mock.pump.released.isEmpty)
        #expect(phone.mock.pump.activeBolus == nil)
        #expect(phone.mock.pump.completed.isEmpty)
        await model.shutdown()
    }

    /// A shortcut run with the app in the background: iOS starts a Live Activity only in the foreground,
    /// so turning it on saves the setting and the Live Activity starts at the next foreground. Turning it
    /// off ends it in the background.
    @Test func aBackgroundShortcutStartsTheLiveActivityAtTheNextForeground() async {
        let phone = Phone()
        let activity = RecordingLiveActivity()
        let model = await phone.launch(appActive: false, liveActivity: activity)
        _ = await phone.until(model) { model.pump.link == .connected }

        model.setLiveActivityEnabled(true)
        await phone.settle(model)
        #expect(model.settings.liveActivityEnabled)
        #expect(!activity.isRunning)

        await model.sceneChanged(active: true)
        #expect(activity.isRunning)

        await model.sceneChanged(active: false)
        model.setLiveActivityEnabled(false)
        #expect(!activity.isRunning)
        #expect(!model.settings.liveActivityEnabled)
        await model.shutdown()
    }

    /// A notification's Clear on a launch whose pump can't be reached in time: the alert's notification
    /// comes back saying to clear it on the pump. One that clears doesn't.
    @Test func aNotificationClearThatCantReachThePumpSaysSo() async throws {
        let phone = Phone()
        phone.mock.pump.alertBitmap = 1 << 7
        let first = await phone.launch()
        _ = await phone.until(first) { first.pump.alerts?.value.isEmpty == false }
        let alert = try #require(first.pump.alerts?.value.first)
        await first.shutdown()

        phone.mock.pump.inRange = false
        let model = await phone.launch(appActive: false)
        var outcome: DismissOutcome?
        await phone.driving(model) { outcome = await model.clearFromNotification(alert) }
        #expect(outcome == .unconfirmed)
        let told = await phone.notifications.added.last { $0.identifier == AlertEngine.pumpAlertIdentifier(alert) }
        #expect(told?.body == AlertEngine.clearFailedBody)
        await model.shutdown()
    }

    @Test func aNotificationClearThatClearsSaysNothingMore() async throws {
        let phone = Phone()
        phone.mock.pump.alertBitmap = 1 << 7
        let model = await phone.launch()
        _ = await phone.until(model) { model.pump.alerts?.value.isEmpty == false }
        let alert = try #require(model.pump.alerts?.value.first)
        var outcome: DismissOutcome?
        await phone.driving(model) { outcome = await model.clearFromNotification(alert) }
        #expect(outcome == .cleared)
        #expect(await phone.notifications.added.allSatisfy { $0.body != AlertEngine.clearFailedBody })
        await model.shutdown()
    }
}
