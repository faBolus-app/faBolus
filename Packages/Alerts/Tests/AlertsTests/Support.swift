import Foundation
import faBolusCore

@testable import Alerts

/// The ledger in memory, as a file store would hold it between launches.
final class MemoryLedgerStore: RemoteBolusLedgerPersisting, @unchecked Sendable {
    // @unchecked Sendable: tests touch it from the ledger actor and the test, never at once.
    var saved: RemoteBolusLedger?
    var corrupt = false
    init(_ ledger: RemoteBolusLedger? = nil) { saved = ledger }
    func loadOutcome() -> RemoteBolusLedgerStore.LoadOutcome {
        .init(ledger: corrupt ? RemoteBolusLedger() : (saved ?? RemoteBolusLedger()), failedClosed: corrupt)
    }
    func save(_ ledger: RemoteBolusLedger) throws { saved = ledger }
}

/// The alert state and policy in memory, surviving a "relaunch" (a new coordinator on the same store).
final class MemoryAlertStore: AlertPersisting, @unchecked Sendable {
    // @unchecked Sendable: guarded by `lock`.
    private let lock = NSLock()
    private var state: AlertEngine.State?
    private var policy: AlertPolicy?
    /// Every state saved, in order, so a test can look at what was on disk before an effect ran.
    private(set) var history: [AlertEngine.State] = []

    func loadState() -> AlertEngine.State? { lock.withLock { state } }
    func saveState(_ state: AlertEngine.State) throws {
        lock.withLock {
            self.state = state
            history.append(state)
        }
    }
    func loadPolicy() -> AlertPolicy? { lock.withLock { policy } }
    func savePolicy(_ policy: AlertPolicy) throws { lock.withLock { self.policy = policy } }
    var savedState: AlertEngine.State? { lock.withLock { state } }
}

/// The notification center, recorded. `held` is what it holds by identifier (pending or delivered).
actor FakeScheduler: NotificationScheduling {
    enum Call: Equatable {
        case add(AlertRequest)
        case remove([String])
    }
    private(set) var calls: [Call] = []
    private(set) var held: [String: AlertRequest] = [:]
    var permissionValue = NotificationPermission(authorization: .authorized, alerts: .enabled, timeSensitive: .enabled)
    /// Called with each add before it is recorded, to look at the store at that moment.
    var onAdd: (@Sendable (AlertRequest) -> Void)?

    /// Refuse every add, as iOS does when notifications aren't allowed.
    private(set) var refuseAdds = false
    func setRefuseAdds(_ value: Bool) { refuseAdds = value }
    struct NotAllowed: Error {}

    func add(_ request: AlertRequest, now: Date) async throws {
        if refuseAdds { throw NotAllowed() }
        onAdd?(request)
        calls.append(.add(request))
        held[request.identifier] = request
    }
    /// How long a remove takes, to let other work interleave as with the real center.
    var removeDelay: Duration?
    func setRemoveDelay(_ value: Duration?) { removeDelay = value }

    func remove(identifiers: [String]) async {
        if let removeDelay { try? await Task.sleep(for: removeDelay) }
        calls.append(.remove(identifiers))
        for id in identifiers { held[id] = nil }
    }
    private(set) var removedAll = 0
    func removeAll() async {
        removedAll += 1
        held = [:]
    }
    /// Notifications the OS holds before the app runs (left by an earlier app or process).
    func preload(_ request: AlertRequest) { held[request.identifier] = request }
    func permission() async -> NotificationPermission { permissionValue }

    func setPermission(_ value: NotificationPermission) { permissionValue = value }
    func setOnAdd(_ hook: (@Sendable (AlertRequest) -> Void)?) { onAdd = hook }
    func clearCalls() { calls = [] }
    var adds: [AlertRequest] {
        calls.compactMap {
            if case .add(let r) = $0 { return r }
            return nil
        }
    }
    var removed: [String] {
        calls.flatMap {
            if case .remove(let ids) = $0 { return ids }
            return []
        }
    }
}

/// A clock the test moves.
final class TestClock: @unchecked Sendable {
    // @unchecked Sendable: guarded by `lock`.
    private let lock = NSLock()
    private var current: Date
    private var elapsed = 0.0
    init(_ start: Date = Date(timeIntervalSince1970: 1_800_000_000)) { current = start }
    var now: Date { lock.withLock { current } }
    /// The monotonic time, which `set(by:)` doesn't move.
    var uptime: Double { lock.withLock { elapsed } }
    func advance(_ seconds: TimeInterval) {
        lock.withLock {
            current = current.addingTimeInterval(seconds)
            elapsed += seconds
        }
    }
    /// The phone's clock set by hand: the wall clock moves, time doesn't pass.
    func set(by seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }
}

enum Fixtures {
    static func request(_ peer: String = "garmin", _ id: String = "r1", units: Double = 2) -> DoseRequest {
        let origin: DoseRequest.Origin =
            peer == DoseRequest.Origin.phonePeerId
            ? .phone : .remote(peerId: peer, sentAt: Date(timeIntervalSince1970: 1_800_000_000))
        return DoseRequest(id: id, origin: origin, shape: .now(units: units))
    }

    /// A ledger with one bolus at `outcome`, reached the way the session gets there.
    static func ledger(
        _ outcome: BolusOutcome, request: DoseRequest = request(), confirmed: Bool = false, at now: Date
    ) -> RemoteBolusLedger {
        var ledger = RemoteBolusLedger()
        _ = ledger.begin(request, now: now)
        let key = request.ledgerKey
        switch outcome {
        case .requested:
            break
        case .refused(let reason):
            ledger.markRefused(key, reason: reason, now: now)
        case .failed(let reason):
            ledger.markFailed(key, reason: reason, now: now)
        default:
            ledger.markAccepted(key, bolusId: 7, pumpKey: "pump", pumpClock: 100, now: now)
            if outcome == .accepted { break }
            switch outcome {
            case .delivering: ledger.markDelivering(key, now: now)
            case .delivered(let units): ledger.markDelivered(key, units: units, now: now)
            case .unknown:
                ledger.markUnknown(key, now: now)
                if confirmed { ledger.confirmOnPump(key, now: now) }
            default: break
            }
        }
        return ledger
    }
}

/// A coordinator with its fakes, and a way to feed it pump events.
struct Harness {
    let store: MemoryAlertStore
    let ledgerStore: MemoryLedgerStore
    let ledger: DurableBolusLedger
    let scheduler: FakeScheduler
    let clock: TestClock
    let coordinator: AlertCoordinator
    let events: AsyncStream<PumpEvent>.Continuation

    /// Launch: a new coordinator over `store` and `ledgerStore`, as a relaunched process builds it.
    static func launch(
        store: MemoryAlertStore = MemoryAlertStore(), ledgerStore: MemoryLedgerStore = MemoryLedgerStore(),
        scheduler: FakeScheduler = FakeScheduler(), clock: TestClock = TestClock(), pumpPaired: Bool = false,
        reportNoBackup: Bool = true, before: (AlertCoordinator) async -> Void = { _ in }
    ) async -> Harness {
        let ledger = DurableBolusLedger(store: ledgerStore, now: clock.now)
        let coordinator = AlertCoordinator(
            store: store, scheduler: scheduler, ledger: ledger, tickInterval: nil, clock: { clock.now },
            uptime: { clock.uptime })
        let (stream, continuation) = AsyncStream<PumpEvent>.makeStream()
        await before(coordinator)
        await coordinator.start(events: stream, pumpPaired: pumpPaired)
        // As the app does at launch when no backup source is configured.
        if reportNoBackup { await coordinator.backupGlucoseChanged(nil) }
        return Harness(
            store: store, ledgerStore: ledgerStore, ledger: ledger, scheduler: scheduler, clock: clock,
            coordinator: coordinator, events: continuation)
    }

    /// Hand an event to the coordinator and wait until it has handled it and drained.
    func send(_ event: PumpEvent) async {
        await coordinator.receive(event)
    }

    /// The same process relaunched: the stores (and the OS's notifications) survive, nothing else.
    func relaunch(reportNoBackup: Bool = true) async -> Harness {
        events.finish()
        await coordinator.stop()
        return await Harness.launch(
            store: store, ledgerStore: ledgerStore, scheduler: scheduler, clock: clock, reportNoBackup: reportNoBackup)
    }
}
