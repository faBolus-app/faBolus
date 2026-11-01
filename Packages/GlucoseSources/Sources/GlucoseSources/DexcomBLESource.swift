import DexcomBLE
import DexcomG6
import DexcomG7
import Foundation
import faBolusCore

/// What `DexcomBLESource` drives. `DexcomCentral` in the app; a recording fake in tests.
public protocol DexcomTransport: Sendable {
    func start()
    func perform(_ commands: [DexcomCommand])
    func stop()
}

extension DexcomCentral: DexcomTransport {}

/// A direct-Bluetooth Dexcom source: one observer (G6 or G7) over its own central. Events arrive in
/// order on one stream and are handled one at a time on this actor, so the observer's state is only
/// ever touched here. Local Bluetooth runs continuously, whatever the pump's feed is doing, so a
/// failover is instant.
public actor DexcomBLESource<Observer: DexcomObserver>: GlucoseSource {
    public typealias TransportFactory =
        @Sendable (_ emit: @escaping @Sendable (DexcomEvent) -> Void) -> any DexcomTransport

    public nonisolated let id: String
    public nonisolated let priority: Int = 100
    public nonisolated let connectionKind: GlucoseConnectionKind = .localBLE

    /// How often the observer is woken to notice silence (a transmitter that hasn't come back).
    static var tickInterval: TimeInterval { 60 }

    private var observer: Observer
    private let makeTransport: TransportFactory
    private let remember: @Sendable (DexcomMemory) -> Void
    private let clock: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    private var transport: (any DexcomTransport)?
    private var consumer: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var started = false
    private var buffer = GlucoseSourceBuffer()
    private var subscribers = GlucoseSourceUpdates()
    private var remembered: DexcomMemory

    /// - Parameters:
    ///   - makeTransport: builds the central once, on the first `start`; it lives as long as the source.
    ///   - remember: called when the observer learns a peripheral or sensor worth keeping across launches.
    public init(
        id: String, observer: Observer, makeTransport: @escaping TransportFactory,
        remember: @escaping @Sendable (DexcomMemory) -> Void = { _ in },
        clock: @escaping @Sendable () -> Date = { Date() },
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        self.id = id
        self.observer = observer
        self.makeTransport = makeTransport
        self.remember = remember
        self.clock = clock
        self.sleep = sleep
        self.remembered = observer.memory
    }

    public var state: GlucoseSourceState {
        let now = clock()
        return GlucoseSourceState(
            latest: buffer.latest, history: buffer.history,
            status: reportedStatus(buffer, link: Self.status(observer.status(now: now)), now: now),
            belowRangeAt: buffer.belowRangeAt)
    }

    public func updates() -> AsyncStream<GlucoseSourceState> {
        subscribers.stream { [weak self] id in Task { await self?.endUpdates(id) } }
    }

    private func endUpdates(_ id: UUID) { subscribers.remove(id) }

    public func start() {
        guard !started else { return }
        started = true
        if transport == nil {
            let (stream, continuation) = AsyncStream<DexcomEvent>.makeStream()
            consumer = Task { [weak self] in
                for await event in stream { await self?.handle(event) }
            }
            transport = makeTransport { continuation.yield($0) }
        }
        transport?.perform(observer.start(now: clock()))
        transport?.start()
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                do { try await self.sleep(Self.tickInterval) } catch { return }
                await self.handle(.tick)
            }
        }
        publish()
    }

    public func stop() {
        guard started else { return }
        started = false
        ticker?.cancel()
        ticker = nil
        transport?.perform(observer.stop())
        transport?.stop()
        publish()
    }

    /// Bluetooth runs regardless of the pump's feed.
    public func setPrimaryHealthy(_ healthy: Bool) {}

    func handle(_ event: DexcomEvent) {
        guard started else { return }
        let now = clock()
        let observation = observer.handle(event, now: now)
        transport?.perform(observation.commands)
        if !observation.readings.isEmpty {
            let (samples, belowRange) = GlucoseSourceBuffer.partition(
                observation.readings.map {
                    (mgdl: Int($0.glucose), date: $0.measuredAt, trend: CgmTrend.dexcom(rate: $0.trendRate))
                },
                sourceID: id)
            buffer.add(samples, belowRange: belowRange, now: now)
        }
        if observer.memory != remembered {
            remembered = observer.memory
            remember(remembered)
        }
        publish()
    }

    /// Applies a change to the observer (a new transmitter ID) and carries out what it asks for.
    func reconfigure(_ change: (inout Observer, Date) -> [DexcomCommand]) {
        let commands = change(&observer, clock())
        if started { transport?.perform(commands) }
        publish()
    }

    private func publish() {
        subscribers.yield(state)
    }

    static func status(_ link: DexcomLinkStatus) -> GlucoseSourceStatus {
        switch link {
        case .stopped: return .idle
        case .searching, .waiting: return .searching
        case .reading: return .connected
        case .problem(let problem):
            switch problem {
            case .bluetoothOff: return .unavailable(.bluetoothOff)
            case .bluetoothNotAllowed: return .unavailable(.bluetoothNotAllowed)
            case .bluetoothUnsupported: return .unavailable(.bluetoothUnsupported)
            case .notFound: return .unavailable(.sensorNotFound)
            case .dexcomAppNotConnected: return .unavailable(.dexcomAppNotConnected)
            case .notReady(let detail): return .unavailable(.sensorNotReady(detail))
            case .connectionFailed(let detail): return .unavailable(.connectionFailed(detail))
            }
        }
    }
}

extension DexcomBLESource where Observer == G6Observer {
    /// Updates the transmitter ID to match: one typed in settings wins over the pump's.
    public func setTransmitterID(entered: String?, fromPump: String?) {
        let id = G6TransmitterID.preferred(entered: entered, fromPump: fromPump)
        reconfigure { observer, now in observer.setTransmitterID(id, now: now) }
    }
}
