import Foundation
import faBolusCore

/// What the app shows about alerts: the notifications showing (which the watch mirrors), the banners,
/// and the glucose conditions shown in the app only.
public struct AlertSnapshot: Sendable, Hashable {
    public var active: [ActiveAlert]
    public var banners: [InAppBanner]
    /// No fresh glucose from any source. Shown in the app; never a notification this release.
    public var cgmLost: Bool
    public var permission: NotificationPermission
}

/// The phone's alert pipeline, the authority for alerts (R12).
///
/// It follows the pump session's events and the bolus ledger, judges the glucose conditions, and keeps the
/// OS holding exactly the notifications `AlertEngine` derives. Each input runs the engine, saves its state
/// (with the effects it owes the OS) and only then performs those effects, acknowledging each, so a crash
/// can't lose a notification or post one twice. On launch it performs whatever the last process left
/// unacknowledged.
///
/// Build one at launch, before the pump session starts (so no event is missed), and call `start` with the
/// session's event stream.
public actor AlertCoordinator {
    let store: any AlertPersisting
    let scheduler: any NotificationScheduling
    let ledger: DurableBolusLedger
    let clock: @Sendable () -> Date
    /// The app's monotonic clock, when it gave one: with it a phone clock set while the app runs is
    /// followed (`followPhoneClock`).
    private let sessionClock: SessionClock?
    private var clockSteps = ClockStepDetector()

    private(set) var engine: AlertEngine
    /// The state file couldn't be read (or there was none): notifications an earlier process scheduled
    /// aren't known, so the fixed identifiers are withdrawn once at start.
    private var startedFresh: Bool
    /// Nothing is handed to the OS before `start`: inputs that come earlier are applied and owed, and
    /// `start` performs them after its own clean-up, so the clean-up can't remove one of them.
    private var started = false
    private var starting = false
    /// The backup source's state has been given in this process. Until then the glucose conditions aren't
    /// judged: a relaunched process knows nothing of the backup yet, and judging without it would withdraw
    /// an urgent low that is still real.
    private var backupKnown = false
    /// A glucose reading, from the pump or the backup, has been seen in this process. Until then the
    /// conditions the last process left stand: "no reading yet" after a relaunch says nothing about
    /// whether a CGM-lost or urgent low has ended, and withdrawing one only to post it again re-alerts.
    /// If none comes at all, a CGM-lost stays (the data is still lost) and nothing new is posted.
    private var readingSeen = false
    private let tickInterval: TimeInterval?
    private var lastPublished: AlertSnapshot?
    private var draining = false
    private var permission = NotificationPermission.notDetermined

    // Glucose inputs, kept so the conditions can be judged again as readings age.
    private var pumpState = PumpState()
    private var backup: GlucoseSourceState?
    private var thresholds = FreshnessThresholds.standard

    private var listener: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var subscribers: [UUID: AsyncStream<AlertSnapshot>.Continuation] = [:]

    /// - Parameters:
    ///   - tickInterval: how often `tick` runs while the app runs, so ageing readings and notices coming due
    ///     are noticed without an event; `nil` leaves it to the caller.
    ///   - uptime: the app's monotonic clock (`SessionClock.uptime`), which shows when the phone's clock is
    ///     set; without it the wall clock is taken as it is.
    public init(
        store: any AlertPersisting, scheduler: any NotificationScheduling, ledger: DurableBolusLedger,
        tickInterval: TimeInterval? = 30, clock: @escaping @Sendable () -> Date = { Date() },
        uptime: (@Sendable () -> Double)? = nil
    ) {
        sessionClock = uptime.map { SessionClock(now: clock, uptime: $0) }
        self.store = store
        self.scheduler = scheduler
        self.ledger = ledger
        self.tickInterval = tickInterval
        self.clock = clock
        let state = store.loadState()
        startedFresh = state == nil
        engine = AlertEngine(state: state ?? AlertEngine.State(), policy: store.loadPolicy() ?? AlertPolicy())
    }

    /// Start following `events` (the session's `events()` stream, asked for before the session starts).
    /// Reconciles with the ledger as it loaded and performs anything the last process left owed.
    ///
    /// - Parameter pumpPaired: a pump is paired (`session.pairing != nil`). A paired pump this process hasn't
    ///   reached yet counts as down from now, so a pump that never reconnects after a relaunch is announced.
    public func start(events: AsyncStream<PumpEvent>, pumpPaired: Bool = false) async {
        guard !started, !starting else { return }
        starting = true
        if startedFresh {
            await scheduler.remove(identifiers: Self.fixedIdentifiers)
        }
        permission = await scheduler.permission()
        // Only now may effects reach the OS: an input that arrived during the clean-up above is owed, and
        // the launch run below performs it after the clean-up, never before.
        started = true
        starting = false
        await run(.launched(ledgerView(), pumpPaired: pumpPaired))
        await retryRefused()
        listener = Task { [weak self] in
            for await event in events {
                guard let self else { return }
                await self.receive(event)
            }
        }
        if let tickInterval {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(for: .seconds(tickInterval))
                    guard let self else { return }
                    await self.tick()
                }
            }
        }
    }

    public func stop() {
        listener?.cancel()
        listener = nil
        ticker?.cancel()
        ticker = nil
    }

    /// The first launch of the new app (the wipe of the old app's data): remove every notification the
    /// old app left pending or delivered, which survive an update and would otherwise fire, and start from
    /// a fresh state and the default settings. Call before `start`.
    public func resetForFreshInstall() async {
        guard !started, !starting else { return }
        await scheduler.removeAll()
        engine = AlertEngine()
        startedFresh = false
        save()
        do { try store.savePolicy(engine.policy) } catch {
            alertsLog.error("alert policy not saved: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Inputs

    /// One session event. Internal so tests can wait for its effects.
    func receive(_ event: PumpEvent) async {
        if case .readingsChanged(_, let state) = event {
            pumpState = state
            await judgeGlucose()
            return
        }
        await run(.pump(event))
        if case .bolusOutcome = event {
            // The event names one request; the ledger is the authority for all of them.
            await run(.ledger(ledgerView()))
        }
    }

    /// The backup CGM source's state changed. Call it with `nil` at launch when there is no backup source.
    public func backupGlucoseChanged(_ state: GlucoseSourceState?) async {
        backup = state
        backupKnown = true
        await judgeGlucose()
    }

    /// The user forgot the pump (after `session.forgetPairing()`): its disconnect, instability and alerts
    /// are withdrawn.
    public func pairingForgotten() async {
        await run(.unpaired)
    }

    /// The user's freshness windows changed.
    public func freshnessChanged(_ thresholds: FreshnessThresholds) async {
        self.thresholds = thresholds
        await judgeGlucose()
    }

    /// The ledger changed outside a session event: after the user confirms an outcome on the pump.
    public func ledgerChanged() async {
        await run(.ledger(ledgerView()))
    }

    /// The phone refused a remote's bolus request before it reached the pump.
    public func remoteBolusRefused(peerId: String, requestId: String, reason: String) async {
        await run(.remoteBolusRefused(peerId: peerId, requestId: requestId, reason: reason))
    }

    /// A clear from a pump alert's notification didn't clear it; the user is told to clear it on the pump.
    public func pumpClearFailed(_ alert: PumpAlert) async {
        await run(.pumpClearFailed(alert))
    }

    /// Re-judge everything that depends on time: readings ageing, a scheduled notice coming due. Call it
    /// every so often while the app runs, and when it comes to the foreground.
    public func tick() async {
        permission = await scheduler.permission()
        await retryRefused()
        // Notices come due and readings age with no event: the engine runs whether or not glucose can be
        // judged yet.
        if await !judgeGlucose() { await run(.tick) }
    }

    /// Post again what the OS refused, once it lets the app post (authorized, or provisional).
    private func retryRefused() async {
        guard !engine.state.refused.isEmpty else { return }
        switch permission.authorization {
        case .authorized, .provisional, .ephemeral: await run(.notificationsAllowed)
        case .notDetermined, .denied: break
        }
    }

    // MARK: - Policy

    public var policy: AlertPolicy { engine.policy }

    /// Save and apply new settings. Turning a category off withdraws what it is showing; turning one on
    /// posts what it should be showing now.
    public func setPolicy(_ policy: AlertPolicy) async {
        do { try store.savePolicy(policy) } catch {
            alertsLog.error("alert policy not saved: \(String(describing: error), privacy: .public)")
        }
        await run(.policy(policy))
    }

    // MARK: - Reading

    public var snapshot: AlertSnapshot {
        followPhoneClock()
        return AlertSnapshot(
            active: engine.active(now: clock()),
            banners: InAppBanner.current(
                openBolusResult: engine.hasOpenBolusResult, ledgerUnreadable: engine.state.ledgerUnreadable,
                permission: permission),
            cgmLost: engine.state.cgmLost, permission: permission)
    }

    /// Every later snapshot. Each call returns its own stream.
    public func snapshots() -> AsyncStream<AlertSnapshot> {
        let id = UUID()
        let (stream, continuation) = AsyncStream<AlertSnapshot>.makeStream(bufferingPolicy: .bufferingNewest(1))
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        subscribers[id] = continuation
        continuation.yield(snapshot)
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    // MARK: - Running the engine

    /// Returns whether the conditions were judged (and the engine run).
    @discardableResult
    private func judgeGlucose() async -> Bool {
        // A LOW is a reading too: the backup reports it apart, as `belowRangeAt`.
        if pumpState.glucose != nil || backup?.latest != nil || backup?.belowRangeAt != nil { readingSeen = true }
        guard backupKnown, readingSeen else { return false }
        let now = clock()
        let urgentLow = UrgentLowAlarm.isActive(pumpState: pumpState, source: backup, thresholds: thresholds, now: now)
        // Lost when the newest reading from any source is stale; no reading at all is "no data".
        let newest = [pumpState.glucose?.measuredAt, backup?.latest?.date].compactMap { $0 }.max()
        let cgmLost = newest.map { GlucoseFreshness.isStale($0, thresholds: thresholds, now: now) } ?? false
        await run(.glucose(urgentLow: urgentLow, cgmLost: cgmLost))
        return true
    }

    private func ledgerView() async -> LedgerView {
        LedgerView(await ledger.ledger, block: await ledger.block)
    }

    private func run(_ input: AlertInput) async {
        followPhoneClock()
        let before = engine.state
        engine.handle(input, now: clock())
        // Most inputs (a routine reading) change nothing; only a change is written.
        if engine.state != before { save() }
        publish()
        guard started else { return }
        await drain()
    }

    /// The phone's clock being set shows as a change in the wall clock less the monotonic one; the engine's
    /// times move by the same step. A few seconds' change is the clocks drifting.
    private func followPhoneClock() {
        guard let sessionClock, let step = clockSteps.step(sessionClock) else { return }
        engine.phoneClockSet(by: step)
        save()
    }

    private func save() {
        do { try store.saveState(engine.state) } catch {
            // Still perform the effects: an alert that isn't posted is worse than one that might be posted
            // again after a crash.
            alertsLog.error("alert state not saved: \(String(describing: error), privacy: .public)")
        }
    }

    /// Perform the outbox in order, one effect at a time. Only one drain runs; an input that arrives while
    /// one is awaiting the OS adds to the outbox, and the running drain picks it up.
    private func drain() async {
        guard !draining else { return }
        draining = true
        defer { draining = false }
        while let next = engine.state.outbox.first {
            var refusedByOS = false
            switch next.effect {
            case .post(let request):
                do { try await scheduler.add(request, now: clock()) } catch {
                    // Not retried now: the OS refusing a request (notifications not allowed) won't change by
                    // asking again. The banner tells the user, and it is posted again once they're allowed.
                    refusedByOS = true
                    alertsLog.error(
                        "\(request.identifier, privacy: .public) not posted: \(String(describing: error), privacy: .public)"
                    )
                }
            case .withdraw(let identifiers):
                await scheduler.remove(identifiers: identifiers)
            }
            engine.acknowledge(next.sequence, refusedByOS: refusedByOS)
            save()
        }
    }

    /// Publish the snapshot when it differs from the last one, including when only time changed it (a
    /// scheduled notice came due).
    private func publish() {
        let current = snapshot
        guard current != lastPublished else { return }
        lastPublished = current
        for continuation in subscribers.values { continuation.yield(current) }
    }

    /// The identifiers that don't depend on a request or a pump bit.
    static let fixedIdentifiers: [String] =
        DisconnectEscalation.allIds + [
            AlertEngine.connectionUnstableId, UrgentLowAlarm.dedupeKey, AlertEngine.cgmDataLossId,
            RemoteBolusLedger.unreadableLedgerReconciliationDedupeKey
        ]
}
