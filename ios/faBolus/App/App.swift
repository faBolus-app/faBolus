import Alerts
import PhoneApp
import SwiftUI
import UserNotifications
import WatchLink
import WidgetContent
import WidgetKit
import faBolusCore

@main
struct FaBolusApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            RootView(model: delegate.model)
                .environment(\.watchSetup, delegate.watch)
                .onOpenURL { url in delegate.open(url) }
                .onChange(of: scenePhase, initial: true) { _, phase in
                    let model = delegate.model
                    Task { await model.sceneChanged(active: phase == .active) }
                }
        }
    }
}

/// Builds the app's state when the process starts, so a background relaunch (CoreBluetooth restoring the
/// pump or a CGM, with no view at all) runs the same session, notifications and watch link as a launch
/// the user opens.
@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate, UNUserNotificationCenterDelegate {
    /// Made by the model, when it builds the watch link.
    private(set) var watch: WatchSetup?
    let liveActivity = LiveActivityHost()
    lazy var model: AppModel = AppModel(environment: environment())

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions options: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.setNotificationCategories(AlertNotificationCategories.registered())
        let model = model
        // Before the launch, so a Live Activity tap that launched the app waits for no one. The model
        // judges each tap from its own state, whatever that is when it arrives.
        LiveActivityActions.handler = { tap, unlocked in await model.liveActivityTapped(tap, unlocked: unlocked) }
        // `.inactive` during a launch the user opened, `.background` for a relaunch with no view (Bluetooth
        // restoration). The scene's own phase follows and wins.
        let active = application.applicationState != .background
        Task {
            await model.launch(appActive: active)
            // After the alert pipeline has started, so a first-launch prompt can't race its clean-up. No
            // critical alerts in this release.
            _ = try? await center.requestAuthorization(options: [.alert, .sound, .badge])
        }
        return true
    }

    private func environment() -> AppEnvironment {
        let reload = { WidgetCenter.shared.reloadAllTimelines() }
        let makeWatch: () -> (any WatchTransport)? = { [weak self] in
            guard let self else { return nil }
            watch = WatchSetup.make()
            return watch?.transport
        }
        #if DEBUG
        if DebugMock.isOn {
            let mock = DebugMock.pump
            mock.runInRealTime()
            var env = mock.environment(
                directory: DebugMock.directory, settings: .standard, paired: true,
                notifications: UserNotificationScheduler(), widgetStore: WidgetStore(), reloadWidgets: reload,
                liveActivity: liveActivity, runsTimers: true)
            env.makeWatchTransport = makeWatch
            return env
        }
        #endif
        return .device(makeWatchTransport: makeWatch, reloadWidgets: reload, liveActivity: liveActivity)
    }

    func applicationWillTerminate(_ application: UIApplication) { model.willTerminate() }

    func open(_ url: URL) {
        if url.scheme == DeepLink.scheme {
            if url.host == "bolus" { model.openBolusRequested = true }
        } else {
            watch?.handleOpenURL(url)
        }
    }

    // MARK: Notifications

    /// Apple calls this only in the foreground; the alert shows there too.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }

    /// "Clear" on a pump alert's notification clears it on the pump.
    nonisolated func userNotificationCenter(
        _ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse
    )
        async
    {
        let action = response.actionIdentifier
        let info = response.notification.request.content.userInfo
        guard let alert = AlertNotificationCategories.pumpAlertToClear(actionIdentifier: action, userInfo: info) else {
            return
        }
        // Awaited, so iOS keeps a background launch running while the clear waits for the pump and is sent.
        guard let model = await MainActor.run(body: { [weak self] in self?.model }) else { return }
        _ = await model.clearFromNotification(alert)
    }
}
