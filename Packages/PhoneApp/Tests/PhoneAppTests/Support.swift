import Foundation
import GlucoseSources
import PumpScript
import RemoteProtocol
import Testing
import WatchLink
import WidgetContent
import faBolusCore

@testable import PhoneApp

/// A temporary folder, a settings suite and a scripted pump: one phone's worth of state, which survives a
/// "relaunch" (a new `AppModel` over the same folder, settings and pump).
@MainActor
final class Phone {
    let directory: URL
    let suiteName = "phoneapp-tests-\(UUID().uuidString)"
    let settings: UserDefaults
    let mock = MockPump(origin: Date(timeIntervalSince1970: 1_800_000_000))
    let notifications = MemoryNotificationScheduler()
    let cgmSecrets = MemorySecretStore()
    let watch = WatchTransportStub()
    var reloads = 0

    init() {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("phoneapp-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        settings = UserDefaults(suiteName: suiteName)!
    }

    deinit {
        try? FileManager.default.removeItem(at: directory)
        UserDefaults().removePersistentDomain(forName: suiteName)
    }

    var historyURL: URL { directory.appendingPathComponent("history.store") }
    var registry: GlucoseSourceRegistry {
        GlucoseSourceRegistry(settings: GlucoseSourceSettings(defaults: settings), secrets: cgmSecrets)
    }

    /// A launched app, in the foreground or (no view at all) in the background.
    func launch(
        paired: Bool = true, appActive: Bool = true, wipe: FirstLaunchWipe? = nil,
        liveActivity: (any LiveActivityHosting)? = nil
    ) async -> AppModel {
        let env = mock.environment(
            directory: directory, settings: settings, paired: paired, historyStoreURL: historyURL, wipe: wipe,
            notifications: notifications, glucoseSources: registry, watchTransport: watch, watchClock: StoppedClock(),
            reloadWidgets: { [weak self] in self?.reloads += 1 }, liveActivity: liveActivity)
        let model = AppModel(environment: env)
        await model.launch(appActive: appActive)
        await settle(model)
        return model
    }

    /// Lets the session, the alerts and the model finish what they're doing.
    func settle(_ model: AppModel, rounds: Int = 400) async {
        for _ in 0..<rounds { await Task.yield() }
        try? await Task.sleep(for: .milliseconds(20))
        for _ in 0..<rounds { await Task.yield() }
    }

    /// Moves the pump's clock on in steps, ticking the session as its timer would.
    func run(_ model: AppModel, for seconds: Double, step: Double = 1) async {
        var elapsed = 0.0
        while elapsed < seconds {
            mock.clock.advance(by: step)
            elapsed += step
            await model.session.tick()
            await settle(model, rounds: 50)
        }
    }

    func until(_ model: AppModel, _ condition: () async -> Bool) async -> Bool {
        for _ in 0..<200 {
            if await condition() { return true }
            await run(model, for: 1)
        }
        return await condition()
    }
}

/// A watch transport that is never connected: the link still holds the config the host gives it.
@MainActor
final class WatchTransportStub: WatchTransport {
    func start(_ handler: @escaping @MainActor (WatchTransportEvent) -> Void) {}
    func transmit(_ message: WireValue, send: Int) {}
    func probeAppStatus(probe: Int) {}
    func reregister() {}
}

final class StoppedClock: WatchLinkClock {
    var now: LinkSeconds = 0
    var epoch: Int? { 1_800_000_000 }
    func schedule(after seconds: LinkSeconds, _ action: @escaping @MainActor () -> Void) -> any WatchLinkTimer {
        Timer()
    }
    final class Timer: WatchLinkTimer { func cancel() {} }
}

/// Glucose records every 5 minutes up to a minute before the pump's clock starts.
@MainActor
func addGlucoseHistory(_ pump: ScriptedPump, count: Int) {
    for i in 0..<count {
        let at = pump.wallClockAtStart - 60 - UInt32((count - 1 - i) * 300)
        pump.appendHistory(typeId: 256, at: at, body: [UInt8](repeating: 0, count: 6) + le16(100 + i % 50))
    }
}

func le16(_ v: Int) -> [UInt8] { [UInt8(v & 0xff), UInt8((v >> 8) & 0xff)] }

extension Phone {
    /// Runs `work` while the pump's clock moves, as it would in real time. Records an issue if it hasn't
    /// returned after 120 s of the pump's clock, rather than waiting on it for good: work stuck on a
    /// deadline would otherwise hang the suite.
    func driving(
        _ model: AppModel, sourceLocation: SourceLocation = #_sourceLocation,
        _ work: @escaping @MainActor () async -> Void
    ) async {
        var done = false
        Task { @MainActor in
            await work()
            done = true
        }
        for _ in 0..<120 where !done { await run(model, for: 1) }
        if !done { Issue.record("didn't return within 120 s of the pump's clock", sourceLocation: sourceLocation) }
    }

    /// `task`'s result once it returns, without moving the clock. Records an issue and returns nil if it
    /// hasn't within `seconds` of real time, so work waiting on a clock nothing moves fails instead of
    /// hanging the suite.
    @discardableResult
    func value<T: Sendable>(
        of task: Task<T, Never>, within seconds: Double = 120, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> T? {
        let result = Finished<T>()
        Task { @MainActor in result.value = await task.value }
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while result.value == nil, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        if result.value == nil {
            Issue.record(
                "didn't return within \(seconds) s with the pump's clock stopped", sourceLocation: sourceLocation)
        }
        return result.value
    }

    /// `value(of:)` for a task that can throw: nil if it threw, or hadn't returned in time.
    @discardableResult
    func value<T: Sendable>(
        of task: Task<T, any Error>, within seconds: Double = 120, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> T? {
        let plain = Task { try? await task.value }
        return await value(of: plain, within: seconds, sourceLocation: sourceLocation) ?? nil
    }
}

/// What a `Phone.value(of:)` task returned, once it has.
@MainActor
private final class Finished<T> {
    var value: T?
}

/// A Live Activity that records what it was asked to show. Like ActivityKit, it starts only in the
/// foreground.
@MainActor
final class RecordingLiveActivity: LiveActivityHosting {
    private(set) var shown: [(content: LiveActivityContent, appActive: Bool)] = []
    private(set) var isRunning = false

    func show(_ content: LiveActivityContent, staleDate: Date?, appActive: Bool) {
        shown.append((content, appActive))
        if appActive { isRunning = true }
    }

    func end() { isRunning = false }
}

/// A backup source that records what it's told about the pump's glucose.
final actor RecordingSource: GlucoseSource {
    nonisolated let id = "test.backup"
    nonisolated let priority = 10
    nonisolated let connectionKind = GlucoseConnectionKind.cloudPoll
    private(set) var primaryHealthy: [Bool] = []
    var state: GlucoseSourceState { GlucoseSourceState(latest: nil, status: .searching) }
    func updates() -> AsyncStream<GlucoseSourceState> { AsyncStream { _ in } }
    func start() {}
    func stop() {}
    func setPrimaryHealthy(_ healthy: Bool) { primaryHealthy.append(healthy) }
}
