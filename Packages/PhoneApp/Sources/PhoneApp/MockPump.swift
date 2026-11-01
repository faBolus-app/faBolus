#if DEBUG
import Alerts
import Foundation
import GlucoseSources
import PumpScript
import PumpSession
import TandemBLE
import WatchLink
import WidgetContent
import faBolusCore

/// A scripted t:slim X2 under the real session and link, for the simulator and the tests. Debug builds
/// only: a release build has no mock pump.
@MainActor
public final class MockPump {
    public let clock: ScriptClock
    public let pump: ScriptedPump
    public let transport: ScriptedTransport
    public let secrets = MemorySecretStore()
    private var ticker: Task<Void, Never>?

    public static let pairing = StoredPairing(
        peripheralID: ScriptedPump.peripheralID, model: .tslimX2, scheme: .legacy, advertisedName: "tslim X2 ***693",
        trustedSerial: 1693, pairedAt: Date(timeIntervalSince1970: 1_800_000_000))

    public init(origin: Date = Date()) {
        clock = ScriptClock(origin: origin)
        pump = ScriptedPump(clock: clock)
        // Reads the scripted pump answers, as an API 2.5 pump would.
        pump.unsupportedReads = []
        transport = ScriptedTransport(pump: pump)
    }

    /// The app over this pump, its files in `directory`.
    /// - Parameter paired: the pump's pairing is stored, as after onboarding.
    public func environment(
        directory: URL, settings: UserDefaults, paired: Bool, historyStoreURL: URL? = nil, wipe: FirstLaunchWipe? = nil,
        notifications: any NotificationScheduling = MemoryNotificationScheduler(),
        glucoseSources: GlucoseSourceRegistry? = nil, watchTransport: (any WatchTransport)? = nil,
        watchClock: (any WatchLinkClock)? = nil, widgetStore: WidgetStore? = nil,
        reloadWidgets: @escaping () -> Void = {},
        liveActivity: (any LiveActivityHosting)? = nil, runsTimers: Bool = false
    ) -> AppEnvironment {
        let pairingSecrets = PairingSecrets(store: secrets)
        if paired {
            let store = FilePumpSessionStore(url: directory.appendingPathComponent("pump-session.json"))
            if store.load()?.pairing == nil { try? store.save(PumpSessionRecord(pairing: Self.pairing)) }
            if pairingSecrets.credentials(for: .legacy) == nil {
                try? pairingSecrets.store(.legacy(code: ScriptedPump.code))
            }
        }
        let transport = transport
        let clock = clock
        var env = AppEnvironment(
            appGroupID: nil, dataDirectory: directory, settingsDefaults: settings, historyStoreURL: historyStoreURL,
            wipe: wipe,
            makeConnection: {
                let connection = PumpConnection(transport: transport, clock: clock)
                transport.start()
                return connection
            },
            pairingSecrets: pairingSecrets, notifications: notifications,
            glucoseSources: glucoseSources
                ?? GlucoseSourceRegistry(
                    settings: GlucoseSourceSettings(defaults: settings), secrets: MemorySecretStore()),
            watchTransport: watchTransport, watchClock: watchClock,
            widgetStore: widgetStore ?? WidgetStore(defaults: settings), reloadWidgets: reloadWidgets,
            liveActivity: liveActivity)
        env.runsTimers = runsTimers
        env.clock = { clock.date }
        env.isMock = true
        return env
    }

    /// Moves the scripted pump's clock with the wall clock, for the simulator.
    public func runInRealTime() {
        guard ticker == nil else { return }
        let clock = clock
        ticker = Task { @MainActor in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                clock.advance(by: 0.25)
            }
        }
    }
}

/// Notifications in memory: what was posted and removed.
public actor MemoryNotificationScheduler: NotificationScheduling {
    public private(set) var added: [AlertRequest] = []
    public private(set) var removed: [String] = []
    public private(set) var removedAll = 0
    public var current = NotificationPermission(authorization: .authorized, alerts: .enabled, timeSensitive: .enabled)

    public init() {}

    public func add(_ request: AlertRequest, now: Date) async throws { added.append(request) }
    public func remove(identifiers: [String]) async { removed += identifiers }
    public func removeAll() async { removedAll += 1 }
    public func permission() async -> NotificationPermission { current }
}
#endif

/// Secrets in memory, for the debug mock and the tests.
public final class MemorySecretStore: SecretStore, @unchecked Sendable {
    // @unchecked Sendable: guarded by `lock`.
    private let lock = NSLock()
    private var values: [String: String] = [:]
    public init() {}
    public func secret(for account: String) -> String? { lock.withLock { values[account] } }
    public func setSecret(_ value: String?, for account: String) throws { lock.withLock { values[account] = value } }
}

#if DEBUG
extension MockPump {
    /// Moves the scripted pump's clock on in steps, ticking the session as its timer would: for tests and
    /// snapshot fixtures that run without timers.
    public func run(_ model: AppModel, for seconds: Double, step: Double = 1) async {
        var elapsed = 0.0
        while elapsed < seconds {
            clock.advance(by: step)
            elapsed += step
            await model.session.tick()
            for _ in 0..<50 { await Task.yield() }
        }
    }

    /// Syncs the pump's history while its clock runs.
    public func syncHistory(_ model: AppModel) async {
        let sync = Task { await model.syncHistory() }
        await run(model, for: 10)
        await sync.value
    }
}
#endif
