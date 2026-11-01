import Foundation
import Testing
import faBolusCore

@testable import Alerts

/// The in-app banners. Without the Critical Alerts entitlement iOS settings can silence any alert, so the
/// app says so when notifications can't reach the user, and shows an open bolus result in the app whatever
/// the settings.
@Suite struct InAppBannerTests {
    typealias P = NotificationPermission

    @Test func theBannerShowsWhenNotificationsAreDenied() async {
        let scheduler = FakeScheduler()
        await scheduler.setPermission(P(authorization: .denied, alerts: .disabled, timeSensitive: .disabled))
        let h = await Harness.launch(scheduler: scheduler)
        let snapshot = await h.coordinator.snapshot
        #expect(snapshot.banners == [.notificationsOff])
        let banner = InAppBanner.notificationsOff
        #expect(banner.title == "Notifications are off")
        #expect(banner.opensSettings)
    }

    /// Turning notifications back on in Settings clears it at the next check (the app checks on every
    /// foreground through `tick`).
    @Test func theBannerClearsWhenNotificationsComeBack() async {
        let scheduler = FakeScheduler()
        await scheduler.setPermission(P(authorization: .denied, alerts: .disabled, timeSensitive: .disabled))
        let h = await Harness.launch(scheduler: scheduler)
        await scheduler.setPermission(P(authorization: .authorized, alerts: .enabled, timeSensitive: .enabled))
        await h.coordinator.tick()
        #expect(await h.coordinator.snapshot.banners.isEmpty)
    }

    @Test func everyWayNotificationsCantReachTheUserCountsAsOff() {
        #expect(P(authorization: .denied, alerts: .enabled, timeSensitive: .enabled).isOff)
        #expect(P(authorization: .provisional, alerts: .enabled, timeSensitive: .enabled).isOff, "quiet delivery")
        #expect(P(authorization: .ephemeral, alerts: .enabled, timeSensitive: .enabled).isOff)
        #expect(P(authorization: .authorized, alerts: .disabled, timeSensitive: .enabled).isOff)
        #expect(P(authorization: .authorized, alerts: .enabled, timeSensitive: .disabled).isOff, "Focus can hold them")
        // Allowed: authorized with alerts on, with or without the time-sensitive entitlement; and not asked yet.
        #expect(!P(authorization: .authorized, alerts: .enabled, timeSensitive: .enabled).isOff)
        #expect(!P(authorization: .authorized, alerts: .enabled, timeSensitive: .notSupported).isOff)
        #expect(!P.notDetermined.isOff)
    }

    /// An open bolus result shows in the app whether or not notifications are allowed, and ahead of the
    /// notifications banner.
    @Test func anOpenBolusResultShowsWhateverTheSettings() {
        let off = P(authorization: .denied, alerts: .disabled, timeSensitive: .disabled)
        let on = P(authorization: .authorized, alerts: .enabled, timeSensitive: .enabled)
        #expect(
            InAppBanner.current(openBolusResult: true, permission: off) == [.unknownBolusOutcome, .notificationsOff])
        #expect(InAppBanner.current(openBolusResult: true, permission: on) == [.unknownBolusOutcome])
        #expect(InAppBanner.current(openBolusResult: false, permission: on).isEmpty)
        #expect(!InAppBanner.unknownBolusOutcome.opensSettings)
    }

    /// A routine reading that changes nothing isn't written to disk.
    @Test func anInputThatChangesNothingIsNotSaved() async {
        let h = await Harness.launch()
        await h.send(.connectionUnstable)
        let saves = h.store.history.count
        for _ in 0..<5 { await h.coordinator.backupGlucoseChanged(nil) }
        await h.send(.connectionUnstable)
        #expect(h.store.history.count == saves)
    }

    @Test func snapshotsArePublishedAsTheyChange() async {
        let h = await Harness.launch()
        let stream = await h.coordinator.snapshots()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.active.isEmpty == true)
        await h.send(.connectionUnstable)
        #expect(await iterator.next()?.active.map(\.identifier) == [AlertEngine.connectionUnstableId])
    }
}
