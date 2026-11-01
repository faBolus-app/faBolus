import Alerts
import Foundation
import GlucoseSources
import PumpSession
import TandemBLE
import WatchLink
import WidgetContent

/// Everything the app's state is built from. The app passes the real parts (`AppEnvironment.device`); tests
/// and the debug-only mock pass a scripted pump, files in a temporary folder and fakes.
@MainActor
public struct AppEnvironment {
    public var appGroupID: String?
    /// Where the ledger, the session's record and the alert files live: the App Group container.
    public var dataDirectory: URL?
    public var settingsDefaults: UserDefaults
    /// The history store's file; `nil` is SwiftData's default location.
    public var historyStoreURL: URL?
    public var historyInMemory = false
    /// The first-launch wipe, run before anything else is built; `nil` skips it.
    public var wipe: FirstLaunchWipe?
    /// The one pump link, created once at launch with the pump's restore identifier.
    public var makeConnection: () -> PumpConnection
    public var pairingSecrets: PairingSecrets
    public var notifications: any NotificationScheduling
    public var glucoseSources: GlucoseSourceRegistry
    /// Makes the watch's transport, `nil` when this build has none. Called once, after the first-launch wipe,
    /// because the transport reads the user's settings.
    public var makeWatchTransport: () -> (any WatchTransport)?
    public var watchClock: (any WatchLinkClock)?
    public var widgetStore: WidgetStore
    /// Asks WidgetKit to re-read the snapshot.
    public var reloadWidgets: () -> Void
    public var liveActivity: (any LiveActivityHosting)?
    public var sessionConfiguration = PumpSession.Configuration()
    /// The session and alerts run their own timers; tests drive them instead.
    public var runsTimers = true
    public var clock: @Sendable () -> Date = { Date() }
    /// Turned on by the debug-only mock pump.
    public var isMock = false

    public init(
        appGroupID: String?, dataDirectory: URL?, settingsDefaults: UserDefaults, historyStoreURL: URL? = nil,
        wipe: FirstLaunchWipe?, makeConnection: @escaping () -> PumpConnection, pairingSecrets: PairingSecrets,
        notifications: any NotificationScheduling, glucoseSources: GlucoseSourceRegistry,
        watchTransport: (any WatchTransport)?, watchClock: (any WatchLinkClock)? = nil, widgetStore: WidgetStore,
        reloadWidgets: @escaping () -> Void, liveActivity: (any LiveActivityHosting)?
    ) {
        self.appGroupID = appGroupID
        self.dataDirectory = dataDirectory
        self.settingsDefaults = settingsDefaults
        self.historyStoreURL = historyStoreURL
        self.wipe = wipe
        self.makeConnection = makeConnection
        self.pairingSecrets = pairingSecrets
        self.notifications = notifications
        self.glucoseSources = glucoseSources
        self.makeWatchTransport = { watchTransport }
        self.watchClock = watchClock
        self.widgetStore = widgetStore
        self.reloadWidgets = reloadWidgets
        self.liveActivity = liveActivity
    }

    /// The app on a phone: the real pump link, notifications, CGM sources and stores.
    public static func device(
        makeWatchTransport: @escaping () -> (any WatchTransport)?, reloadWidgets: @escaping () -> Void,
        liveActivity: (any LiveActivityHosting)?
    ) -> AppEnvironment {
        let group = WidgetStore.appGroupID
        let directory = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: group)
        return AppEnvironment(
            appGroupID: group, dataDirectory: directory, settingsDefaults: .standard,
            wipe: FirstLaunchWipe(appGroupID: group, appGroupDirectory: directory),
            makeConnection: { PumpConnection(restoreIdentifier: AppModel.pumpRestoreIdentifier) },
            pairingSecrets: PairingSecrets(), notifications: UserNotificationScheduler(),
            glucoseSources: GlucoseSourceRegistry(), watchTransport: nil, widgetStore: WidgetStore(),
            reloadWidgets: reloadWidgets, liveActivity: liveActivity
        ).with { $0.makeWatchTransport = makeWatchTransport }
    }

    private func with(_ change: (inout AppEnvironment) -> Void) -> AppEnvironment {
        var copy = self
        change(&copy)
        return copy
    }
}

/// Starts, updates and ends the Live Activity. The app's implementation uses ActivityKit.
@MainActor
public protocol LiveActivityHosting: AnyObject {
    /// Whether one is showing.
    var isRunning: Bool { get }
    /// Shows `content`, starting the Live Activity if there is none. Starting only works with the app in
    /// the foreground; an update works in the background too.
    func show(_ content: LiveActivityContent, staleDate: Date?, appActive: Bool)
    func end()
}
