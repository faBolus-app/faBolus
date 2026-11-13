import Foundation
import TandemBLE
import TandemLink
import TandemMessages
import faBolusCore
import os

let sessionLog = Logger(subsystem: "com.fabolus.app", category: "session")

/// The one owner of everything the app does with the pump.
///
/// It runs TandemKit's link (`PumpConnection`), keeps `PumpState`, reads the pump on a priority queue,
/// delivers boluses through the durable ledger, syncs history into the history store, reads and dismisses
/// the pump's alerts, and reports every change as a `PumpEvent`. Nothing about the pump is kept anywhere
/// else: the link's own state lives in `PumpConnection`, the bolus outcomes in `DurableBolusLedger`, and
/// everything the session knows here, in this actor.
///
/// One request goes to the pump at a time, in priority order: cancel, then the steps of a delivery, then
/// a dose's input refresh, the user's own actions, alerts, routine status, settings, history. A delivery
/// holds the link from permission to InitiateBolus, so no read slips between its steps; only a cancel
/// goes ahead of it.
///
/// The session never times anything with a sleeping task: a tick (`tick()`, run by `start` every few
/// seconds while the app runs, and after every link event) does whatever has come due by the clock. A
/// suspended app gets no ticks; the next link event or foreground catches up.
///
/// The delegate shape follows LoopKit's `PumpManager` (state, events, deliver, cancel), so a LoopKit
/// adapter stays possible.
public actor PumpSession {
    public struct Configuration: Sendable {
        /// Status reads: alerts every 15 s, the rest every 60 s, settings every 10 min (the old app's
        /// cadence).
        public var alertInterval: TimeInterval = 15
        public var statusInterval: TimeInterval = 60
        public var settingsInterval: TimeInterval = 10 * 60
        /// How often a delivering bolus's status is read.
        public var deliveryPollInterval: TimeInterval = 1
        /// A delivering bolus with no successful status read for this long has an unknown outcome. A lost reply
        /// is given up on only at its `requestDeadline`, so this lies halfway between one deadline and two: one
        /// lost reply never makes the outcome unknown, and two in a row do, whatever the deadline.
        public var deliveryStatusSilence: TimeInterval { requestDeadline * 1.5 }
        /// A bolus still reported active after this long is left to history. Guess: far past any bolus.
        public var deliveryTrackingLimit: TimeInterval = 30 * 60
        /// Routine history sync, and the most pages one sync fetches (255 records each).
        public var historySyncInterval: TimeInterval = 15 * 60
        public var historyMaxPages = 20
        /// When a sync stopped at its page limit, how soon the next one continues.
        public var historyContinueAfter: TimeInterval = 60
        /// In the background, history syncs stop once the pump's battery is at this percent or below, and
        /// start again once it is above `lowBatteryResumeAbove` (Mobi's low-power mode). A sync in the
        /// foreground, and a search that settles a bolus, still run.
        public var lowBatteryPauseAt = 20
        public var lowBatteryResumeAbove = 30
        /// A history page is complete when every record arrived, or when frames stop for this long.
        public var historyPageQuiet: TimeInterval = 2.5
        public var historyPageLimit: TimeInterval = 15
        /// Settling an unknown bolus from history: how many pages back, how far before the acceptance
        /// the search must reach to call the bolus absent, how often, and how many tries a connection.
        public var reconcileMaxPages = 8
        public var reconcileMargin: UInt32 = 10 * 60
        public var reconcileInterval: TimeInterval = 2 * 60
        public var reconcileAttemptsPerConnection = 5
        /// How soon an unknown bolus the pump still reports active is looked at again.
        public var reconcileWhileDelivering: TimeInterval = 15
        /// How often a bolus outcome that couldn't be saved is saved again (the old app's interval).
        public var ledgerSaveRetry: TimeInterval = 5
        /// The ticker's rhythm while nothing is in flight, and while a bolus or history page is.
        public var idleTick: TimeInterval = 5
        public var busyTick: TimeInterval = 0.5
        /// Whether each class of pump acts on a remote clear (`RemoteClearing.knownClasses`; tests set rows).
        public var remoteClearClasses = RemoteClearing.knownClasses
        /// How long the pump has to answer a request, any request: t:connect's one 60 s timer. One request
        /// is on the wire at a time, so a cancel queued behind a request the pump doesn't answer waits up to
        /// this long.
        public var requestDeadline: TimeInterval = 60

        public init() {}
    }

    enum Priority: Int, Comparable {
        case cancel = 0, delivery, doseInputs, user, essential, reconcile, alerts, status, settings, history, probe

        static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }
    }

    struct Job {
        let id: UInt64
        let message: any TandemMessages.Message
        let allowing: OperationRisk
        let priority: Priority
        let owner: UUID?
        let deadline: Double
        /// Nil for a read nobody waits on: its reply still updates the state.
        let continuation: CheckedContinuation<RequestResult, Never>?
    }

    // MARK: Dependencies

    let connection: PumpConnection
    let ledger: DurableBolusLedger
    let store: any PumpSessionPersisting
    let secrets: PairingSecrets
    let historySink: (any PumpHistorySink)?
    /// The phone's wall clock, for stamps only (`SessionClock`).
    let clock: @Sendable () -> Date
    private let monotonic: @Sendable () -> Double
    let config: Configuration

    // MARK: State

    public internal(set) var state = PumpState()
    /// The windows readings are judged on, the user's choice.
    public internal(set) var freshness: FreshnessThresholds
    var record: PumpSessionRecord
    var alertLists = PumpAlertLists()
    /// A remote-clear trial whose alert was still showing on the read right after the clear, waiting for a
    /// later read to say whether it stayed.
    var pendingTrial: PendingRemoteClearTrial?
    var clockSteps = ClockStepDetector()
    /// The pump's clock as last read, and when by `uptime`.
    var pumpClock: (pumpTime: UInt32, at: Uptime)?
    /// The identity the link reported for the current connection; nil while not ready.
    var identity: TandemLink.PumpIdentity?
    /// The connection's identity checks passed: a t:slim X2 with the trusted serial.
    var identityTrusted = false
    var pendingPairing: PendingPairing?
    var retriedRejectedPairing = false
    /// Whether the app is in the foreground, as last told.
    var appActive = false
    /// The pump's battery fell to the pause level and hasn't yet climbed past the resume level.
    var batteryLow = false
    /// When the last bolus was sent to the pump, and who sent it (its ledger peer ID).
    var lastDelivery: (at: Uptime, peerId: String)?
    /// The phone-clock time the last bolus was sent to the pump, placed by the monotonic time since: a phone
    /// clock set since moves it too, so it stays comparable with a remote's stamp, which a watch takes from
    /// the phone's clock.
    public var lastDeliveryAt: Date? {
        lastDelivery.map { clock().addingTimeInterval(-uptime().timeIntervalSince($0.at)) }
    }

    // Send queue
    var queue: [Job] = []
    var sending = false
    var nextJobID: UInt64 = 1
    var exclusiveOwner: UUID?

    // Timing
    var due: [ReadGroup: Uptime] = [:]
    var lastGlucoseRead: Uptime?
    /// Routine reads the pump has left unanswered since it last answered them, this connection: how many in a
    /// row, and when the last one was given up on.
    var unanswered: [MessageKey: (count: Int, at: Uptime)] = [:]
    var connectedAt: Uptime?
    /// The link's hold window: until a connection has held this long, it holds back untested commands.
    var holdWindow: TimeInterval = 10
    var onceThisConnection: Set<ReadGroup> = []

    // Delivery
    var delivery: DeliveryInProgress?
    var tracked: TrackedBolus?

    // History
    var historyBusy = false
    var historyWaiters: [CheckedContinuation<Void, Never>] = []
    /// Clears waiting for the pump to be reachable, each until its deadline.
    var linkWaiters: [(deadline: Uptime, continuation: CheckedContinuation<Void, Never>)] = []
    var page: PageCollector?
    public internal(set) var historySync: HistorySyncState = .idle(lastSynced: nil)
    public internal(set) var historyEvents: [HistoryEvent] = []
    var reconcileAttempts = 0
    var reconciling = false
    var nextReconcileAt: Uptime?
    var nextLedgerSaveAt: Uptime?
    var savingLedger = false
    /// The last retry failed too; logged once, not every retry.
    var ledgerSaveFailing = false

    // Events
    var subscribers: [UUID: AsyncStream<PumpEvent>.Continuation] = [:]
    var linkEvents: Task<Void, Never>?
    var ticker: Task<Void, Never>?

    struct PendingPairing {
        let peripheralID: UUID
        let model: faBolusCore.PumpModel
        let advertisedName: String?
        let credentials: PairingCredentials
    }

    /// - Parameters:
    ///   - connection: the app's one link, created at launch with the pump's restore identifier.
    ///   - ledger: the app's one durable ledger.
    ///   - clock: the wall clock and the monotonic one. Tests pass the scripted clock's.
    public init(
        connection: PumpConnection, ledger: DurableBolusLedger, store: any PumpSessionPersisting,
        secrets: PairingSecrets, historySink: (any PumpHistorySink)?, freshness: FreshnessThresholds = .standard,
        configuration: Configuration = Configuration(), clock: SessionClock = .system
    ) {
        self.connection = connection
        self.ledger = ledger
        self.store = store
        self.secrets = secrets
        self.historySink = historySink
        self.freshness = freshness
        self.config = configuration
        self.clock = clock.now
        monotonic = clock.uptime
        record = store.load() ?? PumpSessionRecord()
        if let pairing = record.pairing { state.model = pairing.model }
        historySync = .idle(lastSynced: record.lastHistorySync)
    }

    // MARK: - Lifecycle

    /// Starts listening to the link and reconnects to the stored pairing. Call once, at launch, before
    /// any view appears, and then `setAppActive` on every scene change.
    ///
    /// - Parameter runTicker: run the clock-driven work on a timer. Tests drive `tick()` themselves.
    public func start(runTicker: Bool = true) async {
        guard linkEvents == nil else { return }
        let stream = await connection.events
        linkEvents = Task { [weak self] in
            for await event in stream {
                guard let self else { return }
                await self.handle(event)
            }
        }
        if runTicker {
            ticker = Task { [weak self] in
                while !Task.isCancelled {
                    guard let self else { return }
                    let interval = await self.tickInterval
                    try? await Task.sleep(for: .seconds(interval))
                    await self.tick()
                }
            }
        }
        await loadSavedEvents()
        await connectToStoredPairing()
    }

    /// Closes the link and stops the session's work. Waiting requests are answered.
    public func stop() async {
        ticker?.cancel()
        ticker = nil
        await connection.stop()
        // After the link is closed, so a clear waiting for the pump ends as not reachable.
        resumeLinkWaiters(all: true)
    }

    /// Tell the session whenever the app enters or leaves the foreground, including `true` at launch in
    /// the foreground: the link assumes the background until told, because a background relaunch may
    /// never be told.
    public func setAppActive(_ active: Bool) async {
        appActive = active
        await connection.setAppActive(active)
        // The stored pairing's code rejected once is tried once more on the next foreground: one
        // misread rejection mustn't leave the app with no pump until a relaunch.
        if active, !retriedRejectedPairing, pendingPairing == nil,
            case .failed(.authenticationRejected) = await connection.state.phase
        {
            retriedRejectedPairing = true
            await connectToStoredPairing()
        }
        tick()
    }

    /// Changes the freshness windows (a user setting).
    public func setFreshness(_ thresholds: FreshnessThresholds) {
        freshness = thresholds
    }

    /// Forget the recorded support evidence for a command, so it is tried again (a developer setting).
    /// The pairing's copy is replaced at once, so a reconnect can't merge the forgotten evidence back.
    public func retest(_ key: MessageKey) async {
        await connection.retest(key)
        record.support = await connection.state.support
        saveRecord()
    }

    /// A command the developer retest setting offers.
    public struct RetestableCommand: Sendable, Equatable, Identifiable {
        public enum Reason: Sendable, Equatable {
            /// This pump is recorded not to answer it, so it's never sent.
            case unsupported
            /// A drop after an error counted one strike against it; another makes it unsupported.
            case suspected
            /// It drew the undefined error code past the retry budget on this connection.
            case sittingOut
        }
        public let key: MessageKey
        /// The request's name where the session sends it, else its opcode.
        public let name: String
        public let reason: Reason
        public var id: MessageKey { key }
    }

    /// What the retest setting lists for the last pump the link identified, by name.
    public func retestableCommands() async -> [RetestableCommand] {
        let link = await connection.state
        // Field by field, as the link's own retest does: a connection still in its handshake hasn't read
        // the unit yet.
        let current = link.connection?.identity
        guard let unit = current?.unit ?? link.lastIdentity?.unit else { return [] }
        let model = current?.model ?? link.lastIdentity?.model
        let apiVersion = current?.apiVersion ?? link.lastIdentity?.apiVersion
        var reasons: [MessageKey: RetestableCommand.Reason] = [:]
        for key in (link.support.recorded[unit] ?? [:]).keys {
            let entry = link.support.entry(for: key, unit: unit, model: model, apiVersion: apiVersion)
            if entry.status == .unsupported {
                reasons[key] = .unsupported
            } else if entry.suspected {
                reasons[key] = .suspected
            }
        }
        for key in link.sittingOut where reasons[key] == nil { reasons[key] = .sittingOut }
        return reasons.map { key, reason in
            RetestableCommand(
                key: key, name: Self.commandNames[key] ?? "opcode \(key.opCode) (\(key.characteristic))",
                reason: reason)
        }
        .sorted { $0.name < $1.name }
    }

    /// Every command the session sends, by name.
    static let commandNames: [MessageKey: String] = {
        var names: [MessageKey: String] = [:]
        for read in ReadGroup.allCases.flatMap(\.reads) {
            names[MessageKey(read)] = String(describing: type(of: read))
        }
        let others: [any TandemMessages.Message.Type] = [
            DismissNotificationRequest.self, HistoryLogRequest.self, HistoryLogStatusRequest.self,
            LastBolusStatusV2Request.self, CancelBolusRequest.self, BolusPermissionRequest.self,
            BolusPermissionReleaseRequest.self, InitiateBolusRequest.self, RemoteBgEntryRequest.self,
            RemoteCarbEntryRequest.self
        ]
        for type in others { names[MessageKey(type)] = String(describing: type) }
        return names
    }()

    /// The link's own state, for diagnostics: phase, telemetry and the reconnect ladder.
    public func linkState() async -> LinkState { await connection.state }

    public var pairing: StoredPairing? { record.pairing }

    // MARK: - Events

    /// Every later event, in order. Each call returns its own stream.
    public func events() -> AsyncStream<PumpEvent> {
        let id = UUID()
        // Unbounded: a consumer that falls behind must still get every bolus outcome and disconnect.
        let (stream, continuation) = AsyncStream<PumpEvent>.makeStream(bufferingPolicy: .unbounded)
        continuation.onTermination = { [weak self] _ in Task { await self?.unsubscribe(id) } }
        subscribers[id] = continuation
        return stream
    }

    private func unsubscribe(_ id: UUID) { subscribers[id] = nil }

    func emit(_ event: PumpEvent) {
        for c in subscribers.values { c.yield(event) }
    }

    func emitReadings(_ changed: Set<PumpState.Reading>) {
        guard !changed.isEmpty else { return }
        emit(.readingsChanged(changed, state))
        if changed.contains(.alerts) {
            emit(.alertsChanged(state.alerts?.value ?? []))
            resumeLinkWaiters()
        }
    }

    /// Now, on the session's monotonic clock: what every interval and deadline is timed on.
    func uptime() -> Uptime { Uptime(seconds: monotonic()) }

    /// The phone's clock being set shows as a change in the wall clock less the monotonic one. The readings'
    /// stamps, which are the phone's clock where the pump gives no time of its own (IOB, the calculator
    /// settings), move by the same step, so none looks younger than it is after the clock is set back, and a
    /// reading taken before a dose's refresh still reads as before it. Called before anything is stamped or
    /// judged; a few seconds' change is the clocks drifting.
    func followPhoneClock() {
        guard let step = clockSteps.step(SessionClock(now: clock, uptime: monotonic)) else { return }
        sessionLog.log("phone clock set by \(step, privacy: .public) s")
        state.phoneClockSet(by: step)
        // The readings themselves didn't change, so no alerts-changed event: only their times did.
        emit(.readingsChanged(Set(PumpState.Reading.allCases), state))
    }

    /// The pump-clock anchor as of now: the last clock read, placed by the monotonic time since it, before
    /// the phone's clock now. A phone clock set since the read moves no pump-stamped time, so a reading's age
    /// stays the pump's own (`now` minus its placed time is the pump's time since it).
    var anchor: PumpClockAnchor? {
        guard let pumpClock else { return nil }
        return PumpClockAnchor(
            pumpTime: pumpClock.pumpTime,
            phoneTime: clock().addingTimeInterval(-uptime().timeIntervalSince(pumpClock.at)))
    }

    // MARK: - Persistence

    func saveRecord() {
        do { try store.save(record) } catch {
            sessionLog.error("pump session record not saved: \(String(describing: error), privacy: .public)")
        }
    }

    // MARK: - Send queue

    /// Sends `message` when its turn comes and returns how it ended. Every request goes through here, so
    /// priorities hold at each slot and a delivery's steps can't be interleaved.
    func exchange(
        _ message: any TandemMessages.Message, allowing: OperationRisk = .read, priority: Priority,
        owner: UUID? = nil
    ) async -> RequestResult {
        await withCheckedContinuation { continuation in
            append(
                message, allowing: allowing, priority: priority, owner: owner, deadline: config.requestDeadline,
                continuation)
        }
    }

    /// Queues reads nobody waits on, in order.
    func enqueue(_ reads: [any TandemMessages.Message], priority: Priority) {
        for read in reads {
            append(read, allowing: .read, priority: priority, owner: nil, deadline: config.requestDeadline, nil)
        }
    }

    private func append(
        _ message: any TandemMessages.Message, allowing: OperationRisk, priority: Priority, owner: UUID?,
        deadline: Double, _ continuation: CheckedContinuation<RequestResult, Never>?
    ) {
        let id = nextJobID
        nextJobID += 1
        queue.append(
            Job(
                id: id, message: message, allowing: allowing, priority: priority, owner: owner, deadline: deadline,
                continuation: continuation))
        runQueue()
    }

    func resumeQueue() { runQueue() }

    private func runQueue() {
        guard !sending, let index = nextJobIndex() else { return }
        let job = queue.remove(at: index)
        sending = true
        if job.message is HistoryLogRequest { pageRequestSent() }
        let connection = connection
        Task {
            let result = await connection.send(job.message, allowing: job.allowing, deadline: job.deadline)
            self.finished(job, result)
        }
    }

    private func finished(_ job: Job, _ result: RequestResult) {
        sending = false
        if case .reply(let reply) = result {
            unanswered[MessageKey(job.message)] = nil
            applyReply(reply.message)
        } else if job.continuation == nil, case .unknown(.timedOut) = result {
            let key = MessageKey(job.message)
            let misses = (unanswered[key]?.count ?? 0) + 1
            unanswered[key] = (misses, uptime())
            // A copy queued while this one waited (its group came due meanwhile) rests too.
            if restingAfterNoAnswer(job.message, now: uptime()) {
                queue.removeAll { $0.continuation == nil && MessageKey($0.message) == key }
            }
        }
        job.continuation?.resume(returning: result)
        runQueue()
    }

    /// While a delivery holds the link only its own steps and a cancel go; otherwise the highest priority,
    /// first come first served within one.
    ///
    /// Until the connection has held, only what's needed now goes out: a cancel, a delivery, a dose's
    /// inputs, the user's own actions and the essential reads. The rest waits for the hold, so a new
    /// connection never starts with a burst (P1 drops 2 s after pairing, cause unknown), and an untested
    /// command waits for it here rather than in the link, where it would hold up everything behind it, a
    /// cancel included. While a bolus is being followed no untested read goes out either: a probe's op-77
    /// can drop the link. A delivery's own steps are left to the link: holding one back here would let a
    /// cancel overtake the InitiateBolus it is meant to stop. A tick sends what has come due.
    func nextJobIndex() -> Int? {
        let held = connectedAt.map { uptime().timeIntervalSince($0) >= holdWindow } ?? true
        let eligible = queue.indices.filter { i in
            let job = queue[i]
            if job.owner == nil {
                if !held, job.priority > .essential { return false }
                // A cancel and a bolus's own status reads are never held back.
                if !held || tracked != nil, job.priority > .delivery, isUntested(job.message) { return false }
            }
            guard let owner = exclusiveOwner else { return true }
            return queue[i].owner == owner || queue[i].priority == .cancel
        }
        return eligible.min { (queue[$0].priority, queue[$0].id) < (queue[$1].priority, queue[$1].id) }
    }

    func isSuspected(_ message: any TandemMessages.Message) -> Bool {
        guard let identity else { return false }
        let entry = record.support.entry(
            for: MessageKey(message), unit: identity.unit, model: identity.model, apiVersion: identity.apiVersion)
        return entry.status == .untested && entry.suspected
    }

    func isUntested(_ message: any TandemMessages.Message) -> Bool {
        guard let identity else { return false }
        return record.support.entry(
            for: MessageKey(message), unit: identity.unit, model: identity.model, apiVersion: identity.apiVersion
        ).status == .untested
    }

    /// Answers every queued request that hasn't gone out, as the link would for a dropped connection.
    func failQueued() {
        let waiting = queue
        queue.removeAll()
        for job in waiting { job.continuation?.resume(returning: .notSent(.connectionLost)) }
    }

    /// A routine read the pump left unanswered twice in a row isn't asked again for one request deadline. One
    /// request is on the wire at a time and the essential reads come due every deadline, so without the gap a
    /// read the pump never answers would hold the wire for good, and nothing below it (the alert reads, the
    /// history search that settles an unknown bolus) would ever go. One lost reply alone rests nothing: the
    /// read goes again at its next turn.
    func restingAfterNoAnswer(_ read: any TandemMessages.Message, now: Uptime) -> Bool {
        guard let miss = unanswered[MessageKey(read)], miss.count >= 2 else { return false }
        return now.timeIntervalSince(miss.at) < config.requestDeadline
    }

    func isQueued(_ type: (some TandemMessages.Message).Type) -> Bool {
        let key = MessageKey(type)
        return queue.contains { MessageKey($0.message) == key }
    }

    /// Applies any reply that carries pump state, whoever asked for it.
    func applyReply(_ message: any TandemMessages.Message) {
        followPhoneClock()
        let now = clock()
        if let time = message as? TimeSinceResetResponse { pumpClock = (time.currentTime, uptime()) }
        if message is CurrentEGVGuiDataResponse { lastGlucoseRead = uptime() }
        let changed = PumpReadings.apply(
            message, to: &state, alerts: &alertLists, context: .init(receivedAt: now, anchor: anchor))
        emitReadings(changed)
        settleRemoteClearTrial(after: message, now: uptime())
    }

    // MARK: - Link events

    func handle(_ event: LinkEvent) async {
        switch event {
        case .phase(let phase):
            await phaseChanged(phase)
        case .discovered(let id, let name, let model, let rssi):
            emit(.pumpFound(peripheralID: id, name: name, model: Self.model(model), rssi: rssi))
        case .paired(let credentials):
            await paired(credentials)
        case .ready(let identity):
            await ready(identity)
        case .disconnected(let reason, _):
            disconnected(reason)
        case .connectionUnstable:
            emit(.connectionUnstable)
        case .connectionRestored:
            emit(.connectionRestored)
        case .supportMatrixChanged(let matrix):
            record.support = matrix
            saveRecord()
        case .unsolicited(let reply):
            if let frame = reply.message as? HistoryLogStreamResponse { historyFrame(frame) }
        case .cancelledRequestAnswered:
            // The session never cancels a request it sent, so no answer can arrive for one.
            break
        case .qualifyingEvents(let events):
            qualifyingEvents(events)
        }
        tick()
    }

    /// A first JPAKE pairing succeeded. The derived secret is what every later connection authenticates
    /// with, so it is kept the moment the pump reports it, and with it the pairing it belongs to: the secret
    /// and the record are written together, so neither can name a pump the other doesn't. The serial is
    /// trusted on the first connection that reports it.
    private func paired(_ credentials: PairingCredentials) async {
        guard let pending = pendingPairing else { return }
        pendingPairing = nil
        do { try secrets.store(credentials) } catch {
            sessionLog.error("pairing secret not stored: \(String(describing: error), privacy: .public)")
            await abandonPairing()
            return
        }
        let support = await connection.state.support
        await clearLogbook()
        record = PumpSessionRecord(
            pairing: StoredPairing(
                peripheralID: pending.peripheralID, model: pending.model, scheme: .jpake,
                advertisedName: pending.advertisedName, pairedAt: clock()),
            support: support)
        saveRecord()
    }

    private func phaseChanged(_ phase: LinkPhase) async {
        let link = Self.linkState(phase)
        if link != state.link {
            state.link = link
            emit(.linkChanged(link))
        }
        switch phase {
        case .failed(let failure):
            emit(.linkFailed(Self.failure(failure)))
            // A pairing that failed leaves the pump that was paired before as it was: go back to it. So does
            // a pairing scan that found nothing.
            if pendingPairing != nil {
                pendingPairing = nil
                state.model = record.pairing?.model ?? .unknown
                await connectToStoredPairing()
            } else if case .pumpNotFound = failure {
                await connectToStoredPairing()
            }
        default:
            break
        }
    }

    private func ready(_ identity: TandemLink.PumpIdentity) async {
        followPhoneClock()
        let now = clock()
        let started = uptime()
        // Everything per connection is set before the first suspension, so a tick that runs meanwhile sees
        // this connection, not the last one.
        self.identity = identity
        refreshRemoteClear()
        connectedAt = started
        onceThisConnection = []
        unanswered = [:]
        reconcileAttempts = 0
        nextReconcileAt = started
        for group in ReadGroup.allCases { due[group] = started }
        if let pending = pendingPairing {
            pendingPairing = nil
            let paired = PumpSessionRecord(
                pairing: StoredPairing(
                    peripheralID: pending.peripheralID, model: pending.model,
                    scheme: {
                        if case .legacy = pending.credentials { return .legacy }
                        return .jpake
                    }(),
                    advertisedName: pending.advertisedName, trustedSerial: identity.unit?.serialNumber,
                    pairedAt: now),
                support: await connection.state.support)
            if case .legacy = pending.credentials {
                do { try secrets.store(pending.credentials) } catch {
                    sessionLog.error("pairing code not stored: \(String(describing: error), privacy: .public)")
                    await abandonPairing()
                    return
                }
            }
            await clearLogbook()
            record = paired
            saveRecord()
            // A new pairing's record starts with no remote-clear trial, so its alerts are decided again.
            refreshRemoteClear()
        } else if var pairing = record.pairing, pairing.trustedSerial == nil, let serial = identity.unit?.serialNumber {
            pairing.trustedSerial = serial
            record.pairing = pairing
            saveRecord()
        }
        retriedRejectedPairing = false
        identityTrusted = Self.isTrusted(identity, pairing: record.pairing)
        if let serial = identity.unit?.serialNumber, let trusted = record.pairing?.trustedSerial, serial != trusted {
            // A different pump answers for this pairing: its readings aren't the user's pump, so the link
            // is closed rather than shown or dosed.
            sessionLog.error("pump serial changed under the pairing; closing the link")
            emit(.linkFailed(.identityMismatch))
            await connection.stop()
            return
        }
        if let model = record.pairing?.model { state.model = model }
        if let api = identity.apiVersion {
            state.apiVersion = Observed(
                PumpAPIVersion(major: api.major, minor: api.minor), measuredAt: now, receivedAt: now)
        }
        pumpClock = await handshakeClock()
        holdWindow = await connection.state.config.holdWindow
        emit(.identified(state.model))
        resumeLinkWaiters()
    }

    /// The pump clock from the handshake's TimeSinceReset, which the link read before it was ready.
    private func handshakeClock() async -> (pumpTime: UInt32, at: Uptime)? {
        let (clockReading, linkNow) = await (connection.state.connection?.clock, connection.now)
        guard let clockReading else { return nil }
        return (clockReading.pumpTime, uptime().addingTimeInterval(-(linkNow - clockReading.receivedAt)))
    }

    private func disconnected(_ reason: DisconnectReason) {
        identity = nil
        identityTrusted = false
        connectedAt = nil
        pendingTrial = nil
        failQueued()
        emit(.disconnected(Self.reason(reason)))
        deliveryLinkDropped()
        historyLinkDropped()
    }

    private func qualifyingEvents(_ events: QualifyingEvent) {
        let now = uptime()
        // The comms-suspended bit (19) pauses nothing: t:connect only logs it (UNVERIFIED-GUESSES #22).
        // Before the link is ready nothing can be read; becoming ready reads everything.
        guard identity != nil else { return }
        // What each bit names is read now, as t:connect does, rather than waiting for its timed group.
        for (read, priority) in NoticeReads.reads(for: events)
        where !queue.contains(where: { MessageKey($0.message) == MessageKey(read) }) {
            enqueue([read], priority: isSuspected(read) ? .probe : priority)
        }
        // t:connect reads a profile change's ProfileStatus, which faBolus doesn't send; the settings
        // group holds what a profile changes here.
        if events.contains(.profileChange) { due[.settings] = now }
        // And a history sync after every notice (t:connect's), one at a time: one asked for during a sync
        // runs after it. The routine sync stays as the backstop for a missed notice. A sync cut short at
        // its page limit keeps its pause before continuing, so a run of notices can't make it back to back.
        if let at = due[.history], at > now, at.timeIntervalSince(now) <= config.historyContinueAfter { return }
        due[.history] = now
    }

    // MARK: - Pairing

    /// Scans for pumps to pair with; each one found comes as `.pumpFound`.
    /// Looks for pumps in pairing mode. The scan closes the link to the paired pump; it comes back when
    /// the scan ends without a pairing (`endPairingScan`, or the scan timing out).
    public func scanForPairing() async {
        await connection.scanForPairing()
    }

    /// The user left pairing without pairing: a pairing under way is abandoned, and the link goes back
    /// to the pump paired before. Nothing changes once the scan has ended without one.
    public func endPairingScan() async {
        if pendingPairing != nil {
            pendingPairing = nil
            state.model = record.pairing?.model ?? .unknown
            await connection.stop()
            await connectToStoredPairing()
            return
        }
        guard case .scanning(forPairing: true) = await connection.state.phase else { return }
        await connectToStoredPairing()
    }

    public enum PairingRefusal: Error, Sendable, Equatable {
        /// The code is neither a 6-digit nor a 16-character pairing code.
        case invalidCode
        /// The pump's name says it's a Mobi, which this release doesn't pair with.
        case mobiNotSupported
        /// The pump's name doesn't say it's a t:slim X2, so the app won't pair with it.
        case unknownModel
    }

    /// Pairs with a pump found by `scanForPairing`. The pairing is stored once the pump authenticates
    /// and identifies itself (`.identified`); a rejected code comes as `.linkFailed(.pairingRejected)`.
    public func pair(peripheralID: UUID, advertisedName: String?, code: String) async throws(PairingRefusal) {
        guard let credentials = PumpPairingCode.credentials(for: code) else { throw .invalidCode }
        let model = advertisedName.map(faBolusCore.PumpModel.init(advertisedName:)) ?? .unknown
        switch model {
        case .tslimX2: break
        case .mobi: throw .mobiNotSupported
        case .unknown: throw .unknownModel
        }
        pendingPairing = PendingPairing(
            peripheralID: peripheralID, model: model, advertisedName: advertisedName, credentials: credentials)
        state = PumpState()
        state.model = model
        alertLists = PumpAlertLists()
        await connection.connect(
            to: PumpTarget(peripheralID: peripheralID, model: .tslim, credentials: credentials),
            support: SupportMatrix())
    }

    /// Forgets the pump: closes the link and removes the pairing, its secret, the support evidence,
    /// history coverage and the logbook. The ledger is kept: an unknown outcome stays blocking until the
    /// user confirms on the pump, because the forgotten pump's history can no longer settle it.
    public func forgetPairing() async {
        pendingPairing = nil
        await connection.stop()
        // Under the history lock, so a page being saved now can't write the forgotten pump's coverage or
        // events after they're gone.
        await acquireHistory()
        do { try secrets.clear() } catch {
            sessionLog.error("pairing secret not removed: \(String(describing: error), privacy: .public)")
        }
        record = PumpSessionRecord()
        saveRecord()
        state = PumpState()
        alertLists = PumpAlertLists()
        pumpClock = nil
        await dropLogbook()
        releaseHistory()
        historySync = .idle(lastSynced: nil)
        emit(.linkChanged(.disconnected))
        emit(.readingsChanged(Set(PumpState.Reading.allCases), state))
    }

    /// A new pairing whose secret couldn't be stored can't be reconnected later, so it isn't kept: the
    /// link goes back to the pump paired before, and the user is told the pairing didn't take.
    private func abandonPairing() async {
        record = store.load() ?? PumpSessionRecord()
        state.model = record.pairing?.model ?? .unknown
        identity = nil
        identityTrusted = false
        emit(.linkFailed(.pairingRejected))
        await connection.stop()
        await connectToStoredPairing()
    }

    private func connectToStoredPairing() async {
        guard let pairing = record.pairing, let credentials = secrets.credentials(for: pairing.scheme) else { return }
        guard pairing.model == .tslimX2 else { return }
        await connection.connect(
            to: PumpTarget(peripheralID: pairing.peripheralID, model: .tslim, credentials: credentials),
            support: record.support)
    }

    // MARK: - Mapping the link's vocabulary

    static func model(_ model: TandemMessages.PumpModel?) -> faBolusCore.PumpModel {
        switch model {
        case .tslim: return .tslimX2
        case .mobi: return .mobi
        case nil: return .unknown
        }
    }

    static func linkState(_ phase: LinkPhase) -> PumpLinkState {
        switch phase {
        case .idle, .failed, .waitingForBluetooth, .backingOff: return .disconnected
        case .scanning: return .scanning
        case .connecting, .discovering: return .connecting
        case .authenticating, .handshaking: return .authenticating
        case .ready: return .connected
        }
    }

    static func reason(_ reason: DisconnectReason) -> PumpDisconnectReason {
        switch reason {
        case .requested: return .requested
        case .bluetoothUnavailable: return .bluetoothUnavailable
        case .linkLost(let error): return .linkLost(code: error?.code)
        case .afterUnsupportedRequest(let key, _): return .afterUnsupportedRequest(opcode: Int(key.opCode))
        case .authenticationFailed: return .authenticationFailed
        case .afterErrorReply, .establishmentTimedOut, .setupFailed, .handshakeFailed, .servicesInvalidated,
            .subscriptionLost, .identityRejected:
            return .linkLost(code: nil)
        }
    }

    static func failure(_ failure: LinkFailure) -> PumpLinkFailure {
        switch failure {
        case .authenticationRejected: return .pairingRejected
        case .unsupportedModel(let model): return .unsupportedModel(Self.model(model))
        case .identityMismatch: return .identityMismatch
        case .pumpNotFound: return .pumpNotFound
        }
    }

    /// A connection may deliver only to a t:slim X2 that identified itself by its advertised name, with
    /// the serial the pairing trusts. Until then nothing that could deliver is sent.
    static func isTrusted(_ identity: TandemLink.PumpIdentity, pairing: StoredPairing?) -> Bool {
        guard identity.model == .tslim, let pairing, pairing.model == .tslimX2, let serial = identity.unit?.serialNumber
        else { return false }
        return pairing.trustedSerial == serial
    }
}
