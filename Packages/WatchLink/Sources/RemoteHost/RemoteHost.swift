import Alerts
import Foundation
import PumpSession
import RemoteProtocol
import WatchLink
import faBolusCore
import os

let hostLog = Logger(subsystem: "com.fabolus.app", category: "remote")

/// What the host reads and does. `SessionRemoteServices` is the app's; tests use a fake.
public protocol RemoteHostServices: Sendable {
    /// The pump's state with glucose merged from any backup source, and where the glucose came from.
    func pump() async -> (PumpState, GlucoseProvenance)
    func bolusBlock() async -> BolusBlock?
    func ledgerEntry(_ key: RemoteBolusLedger.Key) async -> RemoteBolusLedger.Entry?
    /// Refresh the dose inputs and compose the request (`PumpSession.prepareDose`, `DoseComposer.composeRemote`).
    func compose(
        _ request: RemoteDoseRequest, access: AccessPolicy.AccessContext, remoteSizeLimitUnits: Double?
    ) async -> RemoteDoseDecision
    func deliver(_ dose: ComposedDose) async -> DeliveryResult
    func cancelBolus() async -> CancelResult
    func dismiss(_ alert: PumpAlert) async -> DismissOutcome
    func refreshGlucose() async
    func glucoseHistory(since: Date) async -> [faBolusCore.GlucoseReading]
    /// When Control-IQ last auto-corrected: the newest such event in the session's logbook projection,
    /// `nil` when none is known.
    func lastAutoCorrection() async -> Date?
    /// A remote's request refused before the ledger: for the "Remote bolus refused" notification.
    func remoteBolusRefused(requestId: String, reason: String) async
    /// A refusal the ledger holds for a request that never became an entry.
    func ledgerRefusal(_ key: RemoteBolusLedger.Key) async -> RemoteBolusLedger.RemoteRefusal?
    /// Record a refusal in the ledger, so the request's resend gets it after a restart too.
    func recordRefusal(_ key: RemoteBolusLedger.Key, reason: String, confirmations: [DoseConfirmation.Kind]) async
}

/// The phone's settings the remote depends on.
public struct RemoteSettings: Sendable {
    public var access: AccessPolicy.AccessContext
    public var remoteSizeLimitUnits: Double?
    public var preferences: WatchPreferences
    /// The freshness windows the phone uses (`PumpSession.freshness`); the watch's staleness follows them.
    public var freshness: FreshnessThresholds

    public init(
        access: AccessPolicy.AccessContext, remoteSizeLimitUnits: Double?, preferences: WatchPreferences,
        freshness: FreshnessThresholds = .standard
    ) {
        self.access = access
        self.remoteSizeLimitUnits = remoteSizeLimitUnits
        self.preferences = preferences
        self.freshness = freshness
    }
}

/// Answers one remote from the pump session, the ledger and the alerts, through its link.
///
/// What it holds in memory only makes a repeated message harmless while this process runs: the requests
/// being worked on now. Everything a relaunched phone needs to answer a watch that was waiting is durable
/// elsewhere, written before the watch is told:
/// - A bolus's every move is in the ledger before it is sent, and an outcome the watch asks for again, by a
///   poll or a resent request, comes from there. A request the ledger has is never delivered again, and
///   one left in flight by a dead process reads back as unknown, which blocks until history settles it.
/// - A request refused before it became an entry, or cancelled before it reached the session, is recorded
///   in the ledger as refused, so a copy that arrives later gets the same answer.
/// - A request the phone said it had but hadn't recorded when it died was never sent to the pump; the
///   watch's poll gets no answer, and a copy that comes later is a new attempt, delivered at most once.
/// - The last few dismiss results are saved (`DismissResultPersisting`), because a dismiss judged again
///   could clear the same alert raised again since.
/// A status is built from the session's state each time.
public actor RemoteHost {
    public let peerId: String
    private let link: WatchLink
    private let services: any RemoteHostServices
    private let dismissStore: (any DismissResultPersisting)?
    private let clock: @Sendable () -> Date

    private var settings: RemoteSettings
    private var config: WatchConfig
    private var alerts: [ActiveAlert] = []
    /// Bolus requests being composed or delivered, and the furthest outcome sent for each.
    private var boluses: [String: OutcomeToken] = [:]
    /// Requests still being composed, not yet handed to the session. A cancel can't reach the session for
    /// these (it has no bolus yet), so it stops them here.
    private var composing: Set<String> = []
    private var cancelledBeforeStart: Set<String> = []
    /// Orders status refreshes: one that started earlier and finished later is dropped.
    private var statusTicket = 0
    private var lastStatus: StatusPayload?
    private var dismissing: Set<String> = []
    private var dismissResults: [(requestId: String, payload: DismissResultPayload)] = []
    private var cancelling = false
    /// A cancel arrived while one was with the session: it runs again once that one returns, because the
    /// first may have found nothing to stop before a delivery started.
    private var cancelAgain = false
    /// Bolus requests a cancel named before they reached the phone, as when the watch's first send was lost
    /// and the user cancelled while it was still resending: a copy that arrives later is refused, not
    /// delivered. The ledger records each as a refusal; this is its synchronous copy, for a copy that
    /// arrives before that record is written.
    private var cancelledRequests: [String] = []
    /// A cancel the session couldn't confirm is tried again this many more times, this far apart, while the
    /// pump may still be delivering.
    var cancelRetries = 3
    var cancelRetryDelay: Duration = .seconds(2)
    private var started = false

    static let maxDismissResults = 16
    static let maxCancelledRequests = 16
    static let historySpan: TimeInterval = 24 * 3600

    /// - Parameter dismissResults: where the last dismiss results are kept across launches; `nil` keeps them
    ///   in memory only.
    public init(
        link: WatchLink, services: any RemoteHostServices, settings: RemoteSettings, peerId: String = "garmin",
        dismissResults: (any DismissResultPersisting)? = nil, clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.link = link
        self.services = services
        self.settings = settings
        self.peerId = peerId
        self.clock = clock
        dismissStore = dismissResults
        self.dismissResults = (dismissResults?.load() ?? []).suffix(Self.maxDismissResults).map {
            (requestId: $0.requestId, payload: $0)
        }
        config = ConfigComposer.compose(settings.preferences, access: settings.access, freshness: settings.freshness)
    }

    /// Start answering the watch. Call once, after the link is started.
    public func start() async {
        guard !started else { return }
        started = true
        let config = config
        await submit(.setConfig(config))
        await refreshStatus()
        let requests = await MainActor.run { link.hostRequests }
        Task { [weak self] in
            for await request in requests {
                guard let self else { return }
                await self.accept(request)
            }
        }
    }

    // MARK: From the app

    public func settingsChanged(_ settings: RemoteSettings) async {
        self.settings = settings
        let next = ConfigComposer.compose(settings.preferences, access: settings.access, freshness: settings.freshness)
        if next != config {
            config = next
            await submit(.setConfig(next))
        }
        await refreshStatus()
    }

    /// The pump was forgotten: the dismiss results named its alerts.
    public func forgetDismissResults() {
        dismissResults = []
        saveDismissResults()
    }

    /// A backup glucose source has a new reading. The pump's own changes come as pump events; this one
    /// doesn't, so the app calls it.
    public func glucoseChanged() async { await refreshStatus() }

    /// `AlertSnapshot.active`, on every snapshot.
    public func alertsChanged(_ active: [ActiveAlert]) async {
        guard active != alerts else { return }
        alerts = active
        await refreshStatus()
    }

    /// Every pump session event. Any of them can change the status; a bolus outcome for this remote is
    /// also sent as the bolus's own message.
    public func pumpEvent(_ event: PumpEvent) async {
        switch event {
        // A finished sync may have found a newer auto-correction; the sync's other steps change nothing
        // the status shows.
        case .historySync(.idle): break
        case .historySync, .pumpFound: return
        default: break
        }
        if case .bolusOutcome(let key, let outcome) = event, key.peerId == peerId {
            let entry = await services.ledgerEntry(key)
            await sendOutcome(
                BolusOutcomePayload(
                    requestId: key.requestId, outcome: outcome, requestedUnits: entry?.request.totalUnits,
                    sentAt: now))
        }
        await refreshStatus()
    }

    // MARK: From the watch

    /// Takes one request in the order the watch sent it. The bookkeeping that makes a duplicate harmless
    /// happens here, before any wait, so a resend that arrives while the first is being worked on is
    /// recognized; the slow part then runs on its own.
    func accept(_ request: HostRequest) {
        switch request {
        case .bolus(let p):
            if let current = boluses[p.requestId] {
                Task { await self.answerDuplicate(p.requestId, current) }
                return
            }
            boluses[p.requestId] = .received
            composing.insert(p.requestId)
            Task { await self.bolus(p) }
        case .cancel(let p):
            // Never gated. A bolus still being composed is stopped here; one with the session is the
            // session's to stop; one that hasn't arrived yet is refused when it does.
            cancelledBeforeStart.formUnion(composing)
            // What this cancel stops before it reaches the session: every request being composed, and the
            // one it names if that hasn't arrived.
            var stopped = composing
            if let id = p.bolusRequestId, boluses[id] == nil { stopped.insert(id) }
            for id in stopped.sorted() where !cancelledRequests.contains(id) {
                cancelledRequests.append(id)
                if cancelledRequests.count > Self.maxCancelledRequests { cancelledRequests.removeFirst() }
                // Durable, so a copy that arrives after a relaunch is refused too, one being composed when
                // the phone died included. The ledger keeps an entry's answer over this, should the request
                // turn out to have reached the session.
                Task {
                    await self.services.recordRefusal(self.key(id), reason: Self.cancelledMessage, confirmations: [])
                }
            }
            guard !cancelling else {
                cancelAgain = true
                return
            }
            cancelling = true
            Task { await self.cancel() }
        case .dismiss(let p):
            if let done = dismissResults.first(where: { $0.requestId == p.requestId }) {
                Task { await self.submit(.sendResult(.dismissResult(done.payload))) }
                return
            }
            guard dismissing.insert(p.requestId).inserted else { return }
            Task { await self.dismiss(p) }
        case .outcome(let id):
            Task { await self.resendOutcome(id) }
        case .history:
            Task { await self.sendHistory() }
        case .refreshGlucose:
            Task {
                await self.services.refreshGlucose()
                await self.refreshStatus()
            }
        case .unreadableBolus(let id):
            Task { await self.unreadable(id) }
        }
    }

    private func bolus(_ p: BolusRequestPayload) async {
        defer {
            boluses[p.requestId] = nil
            composing.remove(p.requestId)
            cancelledBeforeStart.remove(p.requestId)
        }
        // A request the ledger has an entry for is answered from it, below. One it holds as refused before,
        // perhaps by the phone's last run, gets the same answer again, never a second attempt; the composer
        // would refuse it too, but this skips the pump reads and the "received". One a cancel named before it
        // arrived is refused, but only without an entry: a delivery that started stays its own answer.
        if await services.ledgerEntry(key(p.requestId)) == nil {
            if let refusal = await services.ledgerRefusal(key(p.requestId)) {
                await sendRefusal(p.requestId, refusal)
                return
            }
            if cancelledRequests.contains(p.requestId) {
                await refused(p.requestId, Self.cancelledMessage, announce: false)
                return
            }
        }
        // The watch learns at once that the phone has it, so it stops resending.
        await sendOutcome(
            BolusOutcomePayload(
                requestId: p.requestId, outcome: .received, requestedMilliunits: nil, deliveredMilliunits: nil,
                message: nil, sentAt: now))
        let request = RemoteDoseRequest(v2: p, peerId: peerId, surface: .garmin)
        let decision = await services.compose(
            request, access: settings.access, remoteSizeLimitUnits: settings.remoteSizeLimitUnits)
        switch decision {
        case .refused(.refusedBefore(let reason)):
            if let refusal = await services.ledgerRefusal(key(p.requestId)) {
                await sendRefusal(p.requestId, refusal)
            } else {
                await sendRefusal(p.requestId, reason)
            }
        case .refused where cancelledBeforeStart.contains(p.requestId):
            // The user cancelled it first: that's the answer, now and to a copy after a relaunch, which the
            // cancel's record gives.
            await refused(p.requestId, Self.cancelledMessage, announce: false)
        case .refused(let refusal) where !refusal.confirmationKinds.isEmpty:
            // The watch asks the user; that isn't a refusal to announce on the phone.
            await refused(p.requestId, refusal.userMessage, confirm: refusal.confirmationKinds, announce: false)
        case .refused(let refusal):
            await refused(p.requestId, refusal.userMessage)
        case .alreadyRecorded(let outcome):
            await sendRecorded(p.requestId, outcome)
        case .deliver(let dose):
            // Checked with no wait before the hand-off, so a cancel is either seen here or reaches the
            // session's delivery.
            composing.remove(p.requestId)
            if cancelledBeforeStart.contains(p.requestId) {
                await refused(p.requestId, Self.cancelledMessage, announce: false)
                break
            }
            switch await services.deliver(dose) {
            case .started(let key, let outcome):
                await sendOutcome(
                    BolusOutcomePayload(
                        requestId: key.requestId, outcome: outcome, requestedUnits: dose.request.totalUnits,
                        sentAt: now))
            case .alreadyRecorded(let outcome):
                await sendRecorded(p.requestId, outcome)
            case .notStarted(let refusal):
                await refused(p.requestId, Self.message(refusal))
            }
        }
        await refreshStatus()
    }

    private func answerDuplicate(_ id: String, _ current: OutcomeToken) async {
        if let entry = await services.ledgerEntry(.init(peerId: peerId, requestId: id)) {
            await sendRecorded(id, entry.outcome)
        } else {
            await sendOutcome(
                BolusOutcomePayload(
                    requestId: id, outcome: current, requestedMilliunits: nil, deliveredMilliunits: nil, message: nil,
                    sentAt: now))
        }
    }

    /// The watch's poll names the request it's waiting on. The phone answers only what it knows: from the
    /// ledger, or "received" while it's being worked on. A request it has never seen gets no answer,
    /// because the message carrying it may still arrive; the watch stops waiting once it would be refused
    /// as too old anyway.
    private func resendOutcome(_ id: String) async {
        if let entry = await services.ledgerEntry(.init(peerId: peerId, requestId: id)) {
            await sendRecorded(id, entry.outcome)
        } else if let current = boluses[id] {
            await sendOutcome(
                BolusOutcomePayload(
                    requestId: id, outcome: current, requestedMilliunits: nil, deliveredMilliunits: nil, message: nil,
                    sentAt: now))
        } else if let refusal = await services.ledgerRefusal(key(id)) {
            await sendRefusal(id, refusal)
        }
    }

    private func unreadable(_ id: String) async {
        if let entry = await services.ledgerEntry(.init(peerId: peerId, requestId: id)) {
            await sendRecorded(id, entry.outcome)
            return
        }
        // A readable copy of this request is being worked on (or was refused): that one answers. A damaged
        // duplicate must not call it failed.
        if boluses[id] != nil { return }
        if let refusal = await services.ledgerRefusal(key(id)) {
            await sendRefusal(id, refusal)
            return
        }
        await refused(id, "The phone couldn't read this request. Nothing was delivered — update the watch app.")
    }

    /// - Parameter announce: post the "Remote bolus refused" notification; not for one the user cancelled.
    /// - Parameter confirm: what the watch may ask the user to confirm and send again.
    private func refused(
        _ id: String, _ reason: String, confirm: [DoseConfirmation.Kind] = [], announce: Bool = true
    ) async {
        // In the ledger before the answer goes, so a resend after a relaunch finds it.
        await services.recordRefusal(key(id), reason: reason, confirmations: confirm)
        await sendRefusal(id, reason, confirm: confirm)
        if announce { await services.remoteBolusRefused(requestId: id, reason: reason) }
    }

    /// "Not delivered", with the reason the request was refused for. Not announced: that's `refused`'s, once.
    private func sendRefusal(_ id: String, _ reason: String, confirm: [DoseConfirmation.Kind] = []) async {
        await sendOutcome(.notDelivered(requestId: id, reason: reason, confirm: confirm, sentAt: now))
    }

    /// The same answer as when it was refused.
    private func sendRefusal(_ id: String, _ refusal: RemoteBolusLedger.RemoteRefusal) async {
        await sendRefusal(id, refusal.reason, confirm: refusal.confirmations ?? [])
    }

    private func sendRecorded(_ id: String, _ outcome: BolusOutcome) async {
        let entry = await services.ledgerEntry(.init(peerId: peerId, requestId: id))
        await sendOutcome(
            BolusOutcomePayload(requestId: id, outcome: outcome, requestedUnits: entry?.request.totalUnits, sentAt: now)
        )
    }

    private func sendOutcome(_ payload: BolusOutcomePayload) async {
        if let current = boluses[payload.requestId], current.canMove(to: payload.outcome) {
            boluses[payload.requestId] = payload.outcome
        }
        await submit(.sendResult(.bolusOutcome(payload)))
    }

    private func cancel() async {
        defer { cancelling = false }
        var retries = cancelRetries
        repeat {
            cancelAgain = false
            var result = await services.cancelBolus()
            // No definite answer, or no pump to ask: a bolus may still be going in, so it's asked again.
            while result == .unconfirmed || result == .notConnected, retries > 0 {
                retries -= 1
                try? await Task.sleep(for: cancelRetryDelay)
                result = await services.cancelBolus()
            }
        } while cancelAgain
        await refreshStatus()
    }

    private func dismiss(_ p: DismissPayload) async {
        defer { dismissing.remove(p.requestId) }
        let result: DismissResultToken
        if let alert = alerts.first(where: { StatusComposer.wireId($0.identifier) == p.alertId }) {
            // A remote clears only what the session says can be cleared remotely; the first try on a pump
            // not yet known is the phone's, never a remote's.
            if let pump = alert.pumpAlert, pump.remoteClear == .available, !pump.isMalfunction {
                switch await services.dismiss(pump) {
                case .cleared: result = .cleared
                case .refused: result = .refused
                case .unconfirmed: result = .unconfirmed
                case .unsupported, .notCleared: result = .unsupported
                }
            } else {
                result = .unsupported
            }
        } else {
            result = .notFound
        }
        let payload = DismissResultPayload(requestId: p.requestId, alertId: p.alertId, result: result)
        // Only a definite answer is kept for a resend; an unconfirmed one may be tried again. Saved before
        // the answer goes, so a copy that reaches a relaunched phone gets it too.
        if result != .unconfirmed {
            dismissResults.append((p.requestId, payload))
            if dismissResults.count > Self.maxDismissResults { dismissResults.removeFirst() }
            saveDismissResults()
        }
        await submit(.sendResult(.dismissResult(payload)))
        await refreshStatus()
    }

    private func sendHistory() async {
        let readings = await services.glucoseHistory(since: now.addingTimeInterval(-Self.historySpan))
        let points = readings.compactMap { r in epoch(r.date).map { HistoryPayload.Point(at: $0, mgdl: r.mgdl) } }
            .filter { (0...WireLimits.maxGlucose).contains($0.mgdl) }
        // One point per time, so the watch's strictly increasing check holds.
        var seen = Set<Int>()
        let unique = points.sorted { $0.at > $1.at }.filter { seen.insert($0.at).inserted }
        await submit(.setHistory(.newest(unique, sentAt: wireEpoch(now))))
    }

    // MARK: Status

    private func refreshStatus() async {
        statusTicket += 1
        let ticket = statusTicket
        let (pump, provenance) = await services.pump()
        let block = await services.bolusBlock()
        let autoCorrection = await services.lastAutoCorrection()
        // A refresh that started later has already sent a newer snapshot.
        guard ticket == statusTicket else { return }
        let status = StatusComposer.compose(
            StatusInputs(
                pump: pump, glucoseProvenance: provenance, access: settings.access, bolusBlock: block, alerts: alerts,
                lastAutoCorrection: autoCorrection, configRevision: config.revision,
                remoteSizeLimitUnits: settings.remoteSizeLimitUnits, now: now))
        // Nothing the watch would see changed: leave the one already queued or delivered.
        var unchanged = status
        unchanged.sentAt = lastStatus?.sentAt ?? status.sentAt
        guard unchanged != lastStatus else { return }
        lastStatus = status
        await submit(.setStatus(status))
    }

    private var now: Date { clock() }

    /// A save that fails still lets the answer go: it's true, and only a copy arriving after a relaunch would
    /// be judged again.
    private func saveDismissResults() {
        do { try dismissStore?.save(dismissResults.map(\.payload)) } catch {
            hostLog.error("watch dismiss results not saved: \(String(describing: error), privacy: .public)")
        }
    }

    private func key(_ requestId: String) -> RemoteBolusLedger.Key { .init(peerId: peerId, requestId: requestId) }

    private func submit(_ input: WatchLinkInput) async {
        let link = link
        await MainActor.run { link.submit(input) }
    }

    /// For tests: how long a cancel waits before it's tried again.
    func setCancelRetryDelay(_ delay: Duration) { cancelRetryDelay = delay }

    public static let cancelledMessage = "Cancelled before it started. Nothing was delivered."

    /// The session's refusal in the words a remote shows.
    public static func message(_ refusal: DeliveryRefusal) -> String {
        switch refusal {
        case .notConnected: return "Pump not connected."
        case .pumpNotTrusted: return "The connected pump isn't the paired t:slim X2."
        case .blocked(let block): return block.userMessage
        case .requestIdReused: return DoseRefusal.requestIdReused.userMessage
        case .notRecorded: return "The phone couldn't record the bolus, so it wasn't started."
        case .invalidDose: return DoseRefusal.invalidAmount.userMessage
        }
    }
}

extension BolusOutcomePayload {
    fileprivate init(requestId: String, outcome: BolusOutcome, requestedUnits: Double?, sentAt: Date) {
        self.init(requestId: requestId, outcome: outcome, requestedUnits: requestedUnits, sentAt: wireEpoch(sentAt))
    }

    fileprivate static func notDelivered(
        requestId: String, reason: String, confirm: [DoseConfirmation.Kind], sentAt: Date
    ) -> BolusOutcomePayload {
        .notDelivered(requestId: requestId, reason: reason, confirm: confirm, sentAt: wireEpoch(sentAt))
    }

    fileprivate init(
        requestId: String, outcome: OutcomeToken, requestedMilliunits: Int?, deliveredMilliunits: Int?,
        message: String?, sentAt: Date
    ) {
        self.init(
            requestId: requestId, outcome: outcome, requestedMilliunits: requestedMilliunits,
            deliveredMilliunits: deliveredMilliunits, message: message, sentAt: wireEpoch(sentAt))
    }
}
