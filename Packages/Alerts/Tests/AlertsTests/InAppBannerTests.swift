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
            InAppBanner.current(openBolusResult: true, ledgerUnreadable: false, permission: off) == [
                .unknownBolusOutcome, .notificationsOff
            ])
        #expect(
            InAppBanner.current(openBolusResult: true, ledgerUnreadable: false, permission: on) == [
                .unknownBolusOutcome
            ])
        #expect(InAppBanner.current(openBolusResult: false, ledgerUnreadable: false, permission: on).isEmpty)
        #expect(!InAppBanner.unknownBolusOutcome.opensSettings)
    }

    /// A notice the OS refused while notifications were off is posted once they're allowed again, if its
    /// condition still holds; one whose condition ended meanwhile isn't.
    @Test func whatTheOSRefusedIsPostedOnceNotificationsAreAllowed() async {
        let scheduler = FakeScheduler()
        await scheduler.setPermission(P(authorization: .denied, alerts: .disabled, timeSensitive: .disabled))
        await scheduler.setRefuseAdds(true)
        let h = await Harness.launch(scheduler: scheduler)
        await h.send(.connectionUnstable)
        await h.send(.alertsChanged([PumpAlert(id: 0, kind: .alert, title: "Low insulin")]))
        await h.coordinator.remoteBolusRefused(peerId: "garmin", requestId: "r1", reason: "Read-only.")
        await h.send(.alertsChanged([]))
        #expect(await scheduler.held.isEmpty)
        await scheduler.setRefuseAdds(false)
        await scheduler.setPermission(P(authorization: .authorized, alerts: .enabled, timeSensitive: .enabled))
        await h.coordinator.tick()
        let held = await scheduler.held
        #expect(held[AlertEngine.connectionUnstableId] != nil, "the open condition is posted")
        #expect(held["remoteBolusRejected-garmin-r1"] != nil, "the announcement is posted")
        #expect(held.count == 2, "the pump alert that cleared meanwhile isn't")
        await scheduler.clearCalls()
        await h.coordinator.tick()
        #expect(await scheduler.adds.isEmpty, "once")
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

    /// Events reach the coordinator through the stream `start` subscribes to.
    @Test func eventsArriveThroughTheSessionStream() async throws {
        let h = await Harness.launch()
        h.events.yield(.connectionUnstable)
        for _ in 0..<200 where await h.scheduler.held[AlertEngine.connectionUnstableId] == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(await h.scheduler.held[AlertEngine.connectionUnstableId] != nil)
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
