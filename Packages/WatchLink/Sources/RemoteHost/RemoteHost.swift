import Alerts
import Foundation
import PumpSession
import RemoteProtocol
import WatchLink
import faBolusCore

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
}

/// The phone's settings the remote depends on.
public struct RemoteSettings: Sendable {
    public var access: AccessPolicy.AccessContext
    public var remoteSizeLimitUnits: Double?
    public var preferences: WatchPreferences

    public init(access: AccessPolicy.AccessContext, remoteSizeLimitUnits: Double?, preferences: WatchPreferences) {
        self.access = access
        self.remoteSizeLimitUnits = remoteSizeLimitUnits
        self.preferences = preferences
    }
}

/// Answers one remote from the pump session, the ledger and the alerts, through its link.
///
/// It keeps only what makes a repeated message harmless: the requests being worked on now, and the last
/// few dismiss results. Everything else is read when needed: an outcome the watch asks for again comes from
/// the ledger, and a status is built from the session's state. So a relaunched phone answers a watch that
/// was waiting before it went away.
public actor RemoteHost {
    public let peerId: String
    private let link: WatchLink
    private let services: any RemoteHostServices
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
    /// Refusals given before the ledger, which has no entry for them, so a watch that missed one and asks
    /// again gets it.
    private var refusals: [(requestId: String, payload: BolusOutcomePayload)] = []
    private var dismissing: Set<String> = []
    private var dismissResults: [(requestId: String, payload: DismissResultPayload)] = []
    private var cancelling = false
    private var started = false

    static let maxDismissResults = 16
    static let maxRefusals = 16
    static let historySpan: TimeInterval = 24 * 3600

    public init(
        link: WatchLink, services: any RemoteHostServices, settings: RemoteSettings, peerId: String = "garmin",
        clock: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.link = link
        self.services = services
        self.settings = settings
        self.peerId = peerId
        self.clock = clock
        config = ConfigComposer.compose(settings.preferences)
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
        let next = ConfigComposer.compose(settings.preferences)
        if next != config {
            config = next
            await submit(.setConfig(next))
        }
        await refreshStatus()
    }

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
            if let refusal = refusals.first(where: { $0.requestId == p.requestId }) {
                // Refused before the ledger: the same answer again, not a second attempt.
                Task { await self.submit(.sendResult(.bolusOutcome(refusal.payload))) }
                return
            }
            boluses[p.requestId] = .received
            composing.insert(p.requestId)
            Task { await self.bolus(p) }
        case .cancel:
            // Never gated. A bolus still being composed is stopped here; one with the session is the
            // session's to stop.
            cancelledBeforeStart.formUnion(composing)
            guard !cancelling else { return }
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
        // The watch learns at once that the phone has it, so it stops resending.
        await sendOutcome(
            BolusOutcomePayload(
                requestId: p.requestId, outcome: .received, requestedMilliunits: nil, deliveredMilliunits: nil,
                message: nil, sentAt: now))
        let request = RemoteDoseRequest(v2: p, peerId: peerId, surface: .garmin)
        let decision = await services.compose(
            request, access: settings.access, remoteSizeLimitUnits: settings.remoteSizeLimitUnits)
        switch decision {
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
        } else if let refusal = refusals.first(where: { $0.requestId == id }) {
            await submit(.sendResult(.bolusOutcome(refusal.payload)))
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
        if let refusal = refusals.first(where: { $0.requestId == id }) {
            await submit(.sendResult(.bolusOutcome(refusal.payload)))
            return
        }
        await refused(id, "The phone couldn't read this request. Nothing was delivered — update the watch app.")
    }

    /// - Parameter announce: post the "Remote bolus refused" notification; not for one the user cancelled.
    private func refused(_ id: String, _ reason: String, announce: Bool = true) async {
        let payload = BolusOutcomePayload.notDelivered(requestId: id, reason: reason, sentAt: now)
        refusals.removeAll { $0.requestId == id }
        refusals.append((id, payload))
        if refusals.count > Self.maxRefusals { refusals.removeFirst() }
        await sendOutcome(payload)
        if announce { await services.remoteBolusRefused(requestId: id, reason: reason) }
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
        _ = await services.cancelBolus()
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
        // Only a definite answer is kept for a resend; an unconfirmed one may be tried again.
        if result != .unconfirmed {
            dismissResults.append((p.requestId, payload))
            if dismissResults.count > Self.maxDismissResults { dismissResults.removeFirst() }
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

    private func submit(_ input: WatchLinkInput) async {
        let link = link
        await MainActor.run { link.submit(input) }
    }

    static let cancelledMessage = "Cancelled before it started. Nothing was delivered."

    static func message(_ refusal: DeliveryRefusal) -> String {
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

    fileprivate static func notDelivered(requestId: String, reason: String, sentAt: Date) -> BolusOutcomePayload {
        .notDelivered(requestId: requestId, reason: reason, sentAt: wireEpoch(sentAt))
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
