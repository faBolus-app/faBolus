import Foundation
import faBolusCore

/// One poll's readings: in-range samples, and the times of readings below the measurable range.
public struct GlucosePoll: Sendable, Equatable {
    public var samples: [GlucoseSample]
    public var belowRange: [Date]

    public init(samples: [GlucoseSample], belowRange: [Date] = []) {
        self.samples = samples
        self.belowRange = belowRange
    }
}

/// Why a poll failed. `needsSetup` is not an endpoint failure, so it doesn't widen the backoff.
public enum GlucosePollError: Error, Equatable {
    case needsSetup
    case unavailable(GlucoseSourceProblem)
}

/// Fetches a cloud source's recent readings.
public protocol GlucosePoller: Sendable {
    func poll() async throws -> GlucosePoll
}

/// A cloud follower: polls on a cadence, holds the readings and reports status. Read-only.
///
/// While the pump's own CGM feed is healthy it polls rarely (`idleInterval`) to keep a warm value;
/// when that feed goes stale it polls at once and then every `activeInterval`. Consecutive failures
/// widen the wait (doubling, up to 8 times) and a success resets it, so an outage or a wrong password
/// doesn't hit the sign-in endpoint every minute; Dexcom locks an account after repeated failed
/// sign-ins.
public actor PollingGlucoseSource: GlucoseSource {
    public nonisolated let id: String
    public nonisolated let priority: Int
    public nonisolated let connectionKind: GlucoseConnectionKind = .cloudPoll

    public static let maxBackoffMultiplier = 8

    let activeInterval: TimeInterval
    let idleInterval: TimeInterval
    private let poller: any GlucosePoller
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private var buffer = GlucoseSourceBuffer()
    private var link: GlucoseSourceStatus = .idle
    private var subscribers = GlucoseSourceUpdates()
    private var loop: Task<Void, Never>?
    private var started = false
    private var primaryHealthy = false
    /// A poll is in flight. A second one would sign in again alongside it.
    private var polling = false
    private(set) var consecutiveFailures = 0

    public init(
        id: String, priority: Int, poller: any GlucosePoller, activeInterval: TimeInterval = 60,
        idleInterval: TimeInterval = 600, clock: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.id = id
        self.priority = priority
        self.poller = poller
        self.activeInterval = activeInterval
        self.idleInterval = idleInterval
        self.clock = clock
        self.sleep = sleep
    }

    public var state: GlucoseSourceState {
        GlucoseSourceState(
            latest: buffer.latest, history: buffer.history,
            status: reportedStatus(buffer, link: link, now: clock()), belowRangeAt: buffer.belowRangeAt)
    }

    public func updates() -> AsyncStream<GlucoseSourceState> {
        subscribers.stream { [weak self] id in Task { await self?.endUpdates(id) } }
    }

    private func endUpdates(_ id: UUID) { subscribers.remove(id) }

    public func start() {
        guard !started else { return }
        started = true
        link = .searching
        publish()
        restartLoop(pollNow: true)
    }

    public func stop() {
        started = false
        loop?.cancel()
        loop = nil
        link = .idle
        publish()
    }

    /// Ramps up when the pump's feed goes stale (poll now, then fast) and backs off when it recovers.
    public func setPrimaryHealthy(_ healthy: Bool) {
        guard started, healthy != primaryHealthy else { return }
        primaryHealthy = healthy
        restartLoop(pollNow: !healthy)
    }

    /// Polls now and restarts the cadence: after a credential change, or for the CGM test.
    public func pollNow() {
        guard started else { return }
        restartLoop(pollNow: true)
    }

    /// The wait before the next poll: the base cadence doubled per consecutive failure, capped.
    public static func effectiveInterval(base: TimeInterval, failures: Int) -> TimeInterval {
        base * Double(min(maxBackoffMultiplier, 1 << min(max(failures, 0), 20)))
    }

    private func restartLoop(pollNow: Bool) {
        loop?.cancel()
        loop = Task { [weak self] in
            guard let self else { return }
            if pollNow { await self.tick() }
            while !Task.isCancelled {
                let delay = await self.nextDelay()
                do { try await self.sleep(delay) } catch { return }
                guard !Task.isCancelled else { return }
                await self.tick()
            }
        }
    }

    private func nextDelay() -> TimeInterval {
        Self.effectiveInterval(base: primaryHealthy ? idleInterval : activeInterval, failures: consecutiveFailures)
    }

    func tick() async {
        guard !polling else { return }
        polling = true
        defer { polling = false }
        let result: Result<GlucosePoll, Error>
        do {
            result = .success(try await poller.poll())
        } catch {
            result = .failure(error)
        }
        // A poll that finishes after `stop` changes nothing. One whose loop was restarted meanwhile (the
        // pump's feed changed health) still counts: dropping it would leave no reading until the next poll.
        guard started else { return }
        switch result {
        case .success(let poll):
            consecutiveFailures = 0
            buffer.add(poll.samples, belowRange: poll.belowRange, now: clock())
            link = .connected
        case .failure(GlucosePollError.needsSetup):
            link = .needsSetup
        case .failure(GlucosePollError.unavailable(let problem)):
            consecutiveFailures += 1
            link = .unavailable(problem)
        case .failure(let error):
            consecutiveFailures += 1
            link = .unavailable(.network(error.localizedDescription))
        }
        publish()
    }

    /// Feeds readings in directly, as a poll would. For tests.
    func ingest(_ poll: GlucosePoll) {
        buffer.add(poll.samples, belowRange: poll.belowRange, now: clock())
        link = .connected
        publish()
    }

    private func publish() {
        subscribers.yield(state)
    }
}
