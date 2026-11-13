import Foundation
import faBolusCore

/// What the engine reads from the bolus ledger at one moment.
public struct LedgerView: Sendable, Hashable {
    public var entries: [RemoteBolusLedger.Entry]
    /// The ledger file can't be read, so it may be hiding an unknown outcome.
    public var unreadable: Bool
    /// The entries are everything there is: false when the ledger can't be read or has no store, so an
    /// empty ledger says nothing about the boluses being followed.
    public var isComplete: Bool

    public init(entries: [RemoteBolusLedger.Entry], unreadable: Bool, isComplete: Bool? = nil) {
        self.entries = entries
        self.unreadable = unreadable
        self.isComplete = isComplete ?? !unreadable
    }

    public init(_ ledger: RemoteBolusLedger, block: BolusBlock?) {
        self.init(
            entries: ledger.allEntries, unreadable: block == .ledgerUnreadable,
            isComplete: block != .ledgerUnreadable && block != .noDurableStore)
    }
}

/// Everything that can change which notifications should be showing.
public enum AlertInput: Sendable {
    /// The app process started. Comes first, with the ledger as it loaded and whether a pump is paired:
    /// a paired pump that this process hasn't reached yet is down until it connects.
    case launched(LedgerView, pumpPaired: Bool)
    /// The user forgot the pump: nothing about it is alerted any more.
    case unpaired
    /// An event from the pump session.
    case pump(PumpEvent)
    /// The ledger changed outside a session event (the user confirmed an outcome on the pump).
    case ledger(LedgerView)
    /// The glucose conditions, judged by the caller from measurement times.
    case glucose(urgentLow: Bool, cgmLost: Bool)
    /// The user changed the alert settings.
    case policy(AlertPolicy)
    /// The phone refused a remote's bolus request before it reached the pump.
    case remoteBolusRefused(peerId: String, requestId: String, reason: String)
    /// A clear the user asked for from a pump alert's notification didn't clear it (the pump wasn't
    /// reachable in time, or didn't act on it): they're told to clear it on the pump.
    case pumpClearFailed(PumpAlert)
    /// Time passed; nothing else changed.
    case tick
    /// Notifications are allowed again after being off: post again what the OS refused meanwhile.
    case notificationsAllowed
}

/// The alert state machine. Pure: it holds the conditions that matter for alerts, works out from them
/// and the user's policy which notifications should be held by the OS, and returns the posts and
/// withdrawals that get the OS there. Every condition lives here and nowhere else.
///
/// Conditions are declarative: the requests that should be held are derived from the state every time,
/// and compared with what was last handed to the OS (`State.posted`), so a repeated or reordered input
/// can't post a notification twice or leave one behind. One-off announcements (how a bolus settled, a
/// refused bolus) are posted once and not tracked.
///
/// Every effect waits in `State.outbox` until the driver acknowledges that it was performed. The driver
/// saves the state before performing anything, so an effect cut off by a crash is performed again on the
/// next launch, and nothing is lost. A post replaces the request with its identifier, so a repeat leaves one
/// notification; a crash between the OS taking a post and the save that acknowledges it shows that one
/// notification twice, the price of never losing one.
public struct AlertEngine: Sendable {
    /// Where one bolus request stands, for alerts.
    public enum BolusPhase: String, Sendable, Hashable, Codable {
        /// Being worked on.
        case inFlight
        /// Its outcome is unknown and nobody has confirmed it on the pump: the notice and the banner show.
        case unknown
        /// Unknown, but the user confirmed on the pump. Nothing shows; if history settles it later, that's
        /// announced.
        case confirmed
    }

    public struct TrackedBolus: Sendable, Hashable, Codable {
        public var key: RemoteBolusLedger.Key
        public var phase: BolusPhase
    }

    public struct Pending: Sendable, Hashable, Codable {
        public var sequence: UInt64
        public var effect: AlertEffect
    }

    /// The durable part: saved after every input.
    public struct State: Sendable, Hashable, Codable {
        public internal(set) var boluses: [RemoteBolusLedger.Key: TrackedBolus] = [:]
        public internal(set) var ledgerUnreadable = false
        /// When the pump stopped being reachable without being asked to disconnect; nil while connected.
        public internal(set) var linkDownSince: Date?
        /// The least time after `linkDownSince` before the first disconnect notice, whatever the user's
        /// delay: a drop the app expects to recover from in seconds (after a probe, or at launch before the
        /// first connection) isn't announced at once even with "immediately".
        public internal(set) var linkDownGrace: TimeInterval = 0
        /// The session closed the link because something was wrong (a different pump answered), so the
        /// requested disconnect that follows is not the user's choice and leaves the pump down.
        public internal(set) var closedAfterFailure = false
        public internal(set) var connectionUnstable = false
        public internal(set) var urgentLow = false
        public internal(set) var cgmLost = false
        public internal(set) var pumpAlerts: [PumpAlert] = []
        /// The pump alerts (by notification identifier) a clear from their notification didn't clear: their
        /// notification is shown again saying to clear it on the pump, until the alert ends.
        public internal(set) var clearFailed: Set<String> = []
        /// What was last handed to the OS for the conditions, by identifier.
        public internal(set) var posted: [String: AlertRequest] = [:]
        /// Effects not yet acknowledged as performed, in order.
        public internal(set) var outbox: [Pending] = []
        /// Posts the OS refused (notifications not allowed), by identifier, to post again once allowed.
        public internal(set) var refused: [String: AlertRequest] = [:]
        /// The identifiers of the latest bolus settlements and announcements, newest last, so a stale event
        /// or a remote's resent request can't announce one again.
        public internal(set) var recentlyAnnounced: [String] = []
        var nextSequence: UInt64 = 1

        public init() {}

        // Each field decodes on its own and falls back to empty, the house pattern for persisted blobs: a
        // field added or changed by a later build must not make the whole file unreadable and lose what
        // the last process owed the OS.
        private enum CodingKeys: String, CodingKey {
            case boluses, ledgerUnreadable, linkDownSince, linkDownGrace, closedAfterFailure, connectionUnstable
            case urgentLow, cgmLost, pumpAlerts, clearFailed, posted, outbox, refused, recentlyAnnounced, nextSequence
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            func field<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
                ((try? c.decodeIfPresent(T.self, forKey: key)) ?? nil) ?? fallback
            }
            boluses = field(.boluses, [:])
            ledgerUnreadable = field(.ledgerUnreadable, false)
            linkDownSince = (try? c.decodeIfPresent(Date.self, forKey: .linkDownSince)) ?? nil
            linkDownGrace = field(.linkDownGrace, 0)
            closedAfterFailure = field(.closedAfterFailure, false)
            recentlyAnnounced = field(.recentlyAnnounced, [])
            connectionUnstable = field(.connectionUnstable, false)
            urgentLow = field(.urgentLow, false)
            cgmLost = field(.cgmLost, false)
            pumpAlerts = field(.pumpAlerts, [])
            clearFailed = field(.clearFailed, [])
            posted = field(.posted, [:])
            outbox = field(.outbox, [])
            refused = field(.refused, [:])
            // Never reuse a sequence number still in the outbox.
            nextSequence = max(field(.nextSequence, 1), (outbox.map(\.sequence).max() ?? 0) + 1)
        }
    }

    public private(set) var state: State
    public private(set) var policy: AlertPolicy

    public init(state: State = State(), policy: AlertPolicy = AlertPolicy()) {
        self.state = state
        self.policy = policy
    }

    /// The phone's clock was set by `seconds` (back when negative) while the app ran. The link-down time and
    /// every held fire date move with it, so a disconnect notice still comes the time it should after the
    /// drop, by the real time that passed. The OS was given each fire date as an interval from when it was
    /// posted, so the notifications it holds already fire at those real times.
    public mutating func phoneClockSet(by seconds: TimeInterval) {
        func move(_ request: inout AlertRequest) { request.fireDate?.addTimeInterval(seconds) }
        state.linkDownSince?.addTimeInterval(seconds)
        for id in state.posted.keys { move(&state.posted[id]!) }
        for id in state.refused.keys { move(&state.refused[id]!) }
        for i in state.outbox.indices {
            if case .post(var request) = state.outbox[i].effect {
                move(&request)
                state.outbox[i].effect = .post(request)
            }
        }
    }

    // MARK: - Inputs

    /// Apply `input` at `now`. Returns the effects it added to the outbox, in the order to perform them.
    @discardableResult
    public mutating func handle(_ input: AlertInput, now: Date) -> [Pending] {
        var announcements: [AlertRequest] = []
        switch input {
        case .launched(let ledger, let pumpPaired):
            // The link's instability is per process: a new process's link starts stable and would never
            // report it restored. If the link is still bad, the new one says so again.
            state.connectionUnstable = false
            // A new process reports no drop for a pump it never reached (a pending connect never fails), so
            // a paired pump is down from launch until it connects.
            if pumpPaired, state.linkDownSince == nil { linkWentDown(now, grace: Self.expectedRecoveryGrace) }
            reconcile(ledger, afterRelaunch: true, into: &announcements)
        case .unpaired:
            state.linkDownSince = nil
            state.linkDownGrace = 0
            state.closedAfterFailure = false
            state.connectionUnstable = false
            state.pumpAlerts = []
            state.clearFailed = []
        case .ledger(let ledger):
            reconcile(ledger, afterRelaunch: false, into: &announcements)
        case .pump(let event):
            apply(event, now: now, into: &announcements)
        case .glucose(let urgentLow, let cgmLost):
            state.urgentLow = urgentLow
            state.cgmLost = cgmLost
        case .policy(let next):
            policy = next
        case .remoteBolusRefused(let peerId, let requestId, let reason):
            // A remote resends the same request after a reconnect; it is announced once.
            let id = "remoteBolusRejected-\(peerId)-\(requestId)"
            if !state.recentlyAnnounced.contains(id) {
                remember(id)
                announcements += announce(
                    .remoteBolusRejected, .warning, id: id, title: "Remote bolus not delivered", body: reason)
            }
        case .pumpClearFailed(let alert):
            // The alert's own notification comes back saying so (the one the user acted on is gone), at its
            // own level, and goes when the alert does.
            state.clearFailed.insert(Self.pumpAlertIdentifier(alert))
            state.posted[Self.pumpAlertIdentifier(alert)] = nil
        case .tick:
            break
        case .notificationsAllowed:
            // A refused condition comes off `posted`, so the diff posts it again if it still holds; a refused
            // announcement is posted again as it was.
            for (id, request) in state.refused.sorted(by: { $0.key < $1.key }) {
                if request.presentsLike(state.posted[id]) {
                    state.posted[id] = nil
                } else if state.posted[id] == nil {
                    announcements.append(request)
                }
            }
            state.refused = [:]
        }
        return commit(announcements, now: now)
    }

    /// The driver performed the effect with this sequence number. `refusedByOS` when the OS refused a
    /// post (notifications not allowed): it is kept to post again once they are.
    public mutating func acknowledge(_ sequence: UInt64, refusedByOS: Bool = false) {
        if refusedByOS, let pending = state.outbox.first(where: { $0.sequence == sequence }),
            case .post(let request) = pending.effect
        {
            state.refused[request.identifier] = request
        }
        state.outbox.removeAll { $0.sequence == sequence }
    }

    private mutating func apply(_ event: PumpEvent, now: Date, into announcements: inout [AlertRequest]) {
        switch event {
        case .linkChanged(let link):
            if link == .connected {
                state.linkDownSince = nil
                state.linkDownGrace = 0
                state.closedAfterFailure = false
            }
        case .disconnected(let reason):
            switch reason {
            case .requested where state.closedAfterFailure:
                // The session closed the link over a failure: the pump is still unreachable.
                state.closedAfterFailure = false
            case .requested:
                // The user or the app closed the link: nothing to alert about.
                state.linkDownSince = nil
                state.linkDownGrace = 0
                state.connectionUnstable = false
            case .afterUnsupportedRequest:
                // Expected after a probe; the pending connect brings it back in seconds.
                linkWentDown(now, grace: Self.expectedRecoveryGrace)
            case .bluetoothUnavailable, .linkLost, .authenticationFailed:
                linkWentDown(now, grace: 0)
            }
        case .linkFailed(.identityMismatch):
            // A different pump answered under the pairing and the session closes the link: the user's pump
            // can't be reached.
            linkWentDown(now, grace: 0)
            state.closedAfterFailure = true
        case .connectionUnstable:
            state.connectionUnstable = true
        case .connectionRestored:
            state.connectionUnstable = false
        case .alertsChanged(let alerts):
            state.pumpAlerts = alerts
            state.clearFailed.formIntersection(alerts.map(Self.pumpAlertIdentifier))
        case .bolusOutcome(let key, let outcome):
            bolusMoved(key, to: outcome, into: &announcements)
        case .linkFailed, .identified, .readingsChanged, .alertDismissed, .pumpFound, .historySync,
            .bolusOutcomesSaved:
            break
        }
    }

    /// How long a drop the app expects to recover from is given before the first notice can fire.
    static let expectedRecoveryGrace: TimeInterval = 60
    /// How many settlements and announcements are remembered against repeats.
    static let recentlyAnnouncedCap = 64

    /// The pump stopped being reachable at `now`, unless it already had. A real drop after an expected one
    /// removes the grace.
    private mutating func linkWentDown(_ now: Date, grace: TimeInterval) {
        if state.linkDownSince == nil {
            state.linkDownSince = now
            state.linkDownGrace = grace
        } else if grace == 0 {
            state.linkDownGrace = 0
        }
    }

    private mutating func remember(_ id: String) {
        state.recentlyAnnounced.removeAll { $0 == id }
        state.recentlyAnnounced.append(id)
        if state.recentlyAnnounced.count > Self.recentlyAnnouncedCap {
            state.recentlyAnnounced.removeFirst(state.recentlyAnnounced.count - Self.recentlyAnnouncedCap)
        }
    }

    // MARK: - Boluses

    private mutating func bolusMoved(
        _ key: RemoteBolusLedger.Key, to outcome: BolusOutcome, into announcements: inout [AlertRequest]
    ) {
        let tracked = state.boluses[key]
        // A bolus already settled from a ledger read that ran ahead of the events (the session records
        // before it emits) gets late events for its earlier steps; following it again would announce twice.
        if tracked == nil, state.recentlyAnnounced.contains(Self.bolusIdentifier(key)) { return }
        switch outcome {
        case .requested, .accepted, .delivering:
            if tracked == nil { state.boluses[key] = TrackedBolus(key: key, phase: .inFlight) }
        case .unknown:
            state.boluses[key] = TrackedBolus(key: key, phase: tracked?.phase == .confirmed ? .confirmed : .unknown)
        case .delivered, .stopped, .refused, .failed:
            guard let tracked else { return }
            state.boluses[key] = nil
            remember(Self.bolusIdentifier(key))
            announcements += settled(key, from: tracked.phase, to: outcome, afterRelaunch: false)
        }
    }

    /// Bring the tracked boluses in line with the ledger, which is the authority. An unknown outcome the
    /// engine never saw (a restart turned an in-flight request unknown, or a crash cut off the event) gets
    /// its notice; a tracked one that settled is announced; one the user confirmed loses its notice.
    private mutating func reconcile(
        _ ledger: LedgerView, afterRelaunch: Bool, into announcements: inout [AlertRequest]
    ) {
        state.ledgerUnreadable = ledger.unreadable
        var seen = Set<RemoteBolusLedger.Key>()
        for entry in ledger.entries {
            let key = entry.key
            seen.insert(key)
            let tracked = state.boluses[key]
            switch entry.outcome {
            case .unknown:
                let confirmed = entry.confirmedOnPumpAt != nil || tracked?.phase == .confirmed
                state.boluses[key] = TrackedBolus(key: key, phase: confirmed ? .confirmed : .unknown)
            case .requested, .accepted, .delivering:
                if tracked == nil { state.boluses[key] = TrackedBolus(key: key, phase: .inFlight) }
            case .delivered, .stopped, .refused, .failed:
                // A final entry the engine wasn't following is history it has nothing to say about.
                guard let tracked else { continue }
                state.boluses[key] = nil
                remember(Self.bolusIdentifier(key))
                announcements += settled(key, from: tracked.phase, to: entry.outcome, afterRelaunch: afterRelaunch)
            }
        }
        // An unreadable ledger, or one with no store, says nothing about what it doesn't hold: keep following.
        guard ledger.isComplete else { return }
        for key in state.boluses.keys where !seen.contains(key) { state.boluses[key] = nil }
    }

    /// The announcement for a bolus that reached a final outcome, if one is due.
    ///
    /// A bolus whose outcome was unknown is always announced as a bolus result, whatever it settled to,
    /// because the user was told it was unknown. So is one the previous process was still working on: the
    /// user never saw how it ended. A bolus that ends normally while the app runs is reported where it was
    /// asked for; only a refusal or failure is also posted, as "Bolus not delivered", for a user who
    /// isn't looking at the screen or the watch.
    private func settled(
        _ key: RemoteBolusLedger.Key, from phase: BolusPhase, to outcome: BolusOutcome, afterRelaunch: Bool
    ) -> [AlertRequest] {
        let id = Self.bolusIdentifier(key)
        let wasUnknown = phase == .unknown || phase == .confirmed
        if !wasUnknown && !afterRelaunch {
            switch outcome {
            case .refused(let reason), .failed(let reason):
                return announce(.bolusDeliveryFailed, .warning, id: id, title: "Bolus not delivered", body: reason)
            default:
                return []
            }
        }
        let (title, body): (String, String)
        switch outcome {
        case .delivered(let units):
            title = "Bolus delivered"
            body =
                wasUnknown
                ? "Reconciled from pump history: \(formatUnits(units)) delivered."
                : "\(formatUnits(units)) delivered."
        case .stopped(let delivered, let requested):
            title = "Bolus stopped early"
            body =
                wasUnknown
                ? "Reconciled from pump history: \(formatUnits(delivered)) of \(formatUnits(requested)) delivered."
                : "\(formatUnits(delivered)) of \(formatUnits(requested)) delivered."
        case .failed:
            title = "Bolus not delivered"
            body =
                wasUnknown
                ? "Pump history shows this bolus never started (0 U). Re-enter it if you still need it."
                : "A bolus that was interrupted never reached the pump (0 U). Re-enter it if you still need it."
        case .refused(let reason):
            title = "Bolus not delivered"
            body = reason
        case .requested, .accepted, .delivering, .unknown:
            return []
        }
        return announce(
            .bolusReconciliation, outcome.deliveredUnits.map { $0 > 0 } == true ? .info : .warning,
            id: id, title: title, body: body)
    }

    /// The bolus result notification's identifier: one per request, shared by the unknown notice and the
    /// announcement that replaces it.
    public static func bolusIdentifier(_ key: RemoteBolusLedger.Key) -> String {
        RemoteBolusLedger.reconciliationDedupeKey(peerId: key.peerId, requestId: key.requestId)
    }

    /// The gentle copy for an unknown outcome (R11): never "failed", and what to do.
    public static let unknownOutcomeTitle = "Bolus outcome unknown"
    public static let unknownOutcomeBody = "Bolus sent but outcome is unknown — verify on the pump before retrying."

    // MARK: - Pump notifications

    /// A pump notification's identifier. A malfunction is keyed by its code, because an alarm and a
    /// malfunction on the same bit are two notifications.
    public static let clearFailedBody = "faBolus couldn't clear this from the phone. Clear it on the pump."

    public static func pumpAlertIdentifier(_ alert: PumpAlert) -> String {
        if let code = alert.malfunctionCode { return "pumpalert-malfunction-\(code)" }
        return "pumpalert-\(alert.kind.rawValue)-\(alert.id)"
    }

    // MARK: - Deriving and committing

    public static let connectionUnstableId = "safety.pumpConnectionUnstable"
    public static let cgmDataLossId = "safety.cgmDataLoss"

    /// The condition requests that should be held right now, by identifier.
    func desired(now: Date) -> [String: AlertRequest] {
        var out: [String: AlertRequest] = [:]
        func add(
            _ category: NotificationBroker.Category, _ severity: AlertSeverity, id: String, title: String,
            body: String, fireDate: Date? = nil, pumpAlert: PumpAlert? = nil
        ) {
            let decision = NotificationBroker.decide(category, policy: policy)
            guard let level = decision.level else { return }
            out[id] = AlertRequest(
                identifier: id, category: category, severity: severity, level: level,
                escalation: decision.escalation ?? .none, title: title, body: body, fireDate: fireDate,
                pumpAlert: pumpAlert)
        }
        for bolus in state.boluses.values where bolus.phase == .unknown {
            add(
                .bolusReconciliation, .warning, id: Self.bolusIdentifier(bolus.key), title: Self.unknownOutcomeTitle,
                body: Self.unknownOutcomeBody)
        }
        if state.ledgerUnreadable {
            add(
                .bolusReconciliation, .warning, id: RemoteBolusLedger.unreadableLedgerReconciliationDedupeKey,
                title: Self.unknownOutcomeTitle,
                body: "A previous bolus can’t be reconciled — the safety record is unreadable. Verify on the "
                    + "pump/t:connect before dosing again.")
        }
        if let down = state.linkDownSince {
            let schedule = DisconnectEscalation.schedule(delay: policy.pumpDisconnectDelay)
            // Only the latest notice already due is posted; one the user has seen is left as it is. Both
            // matter only when the delay changes while the pump is down: without them a shorter delay would
            // post several notices at once, and a longer one would re-post one already delivered.
            func fireDate(_ step: DisconnectEscalation.Step) -> Date {
                down.addingTimeInterval(Swift.max(step.afterSeconds, state.linkDownGrace))
            }
            let latestDue = schedule.last { fireDate($0) <= now }?.id
            for step in schedule {
                if let held = state.posted[step.id], held.hasFired(by: now) {
                    out[step.id] = held
                    continue
                }
                let fireDate = fireDate(step)
                if fireDate <= now && step.id != latestDue { continue }
                add(.pumpDisconnect, .warning, id: step.id, title: step.title, body: step.body, fireDate: fireDate)
            }
        }
        if state.connectionUnstable {
            add(
                .pumpConnectionUnstable, .warning, id: Self.connectionUnstableId,
                title: "Can’t hold a connection to this pump",
                body: "faBolus keeps losing and re-establishing the link to your pump and can’t hold a stable "
                    + "connection. \(DisconnectEscalation.pumpButtonsInstruction)")
        }
        if state.urgentLow {
            add(
                .urgentLowGlucose, .critical, id: UrgentLowAlarm.dedupeKey, title: UrgentLowAlarm.title,
                body: UrgentLowAlarm.body)
        }
        if state.cgmLost {
            // Shown in the app only this release; the broker refuses it. Kept here so a pump without a
            // screen can turn it into an alert by changing the category alone.
            add(
                .cgmDataLoss, .warning, id: Self.cgmDataLossId, title: "CGM data lost",
                body: "faBolus stopped receiving CGM readings. Check your sensor and transmitter.")
        }
        for alert in state.pumpAlerts {
            let id = Self.pumpAlertIdentifier(alert)
            let body =
                state.clearFailed.contains(id)
                ? Self.clearFailedBody : alert.detail.isEmpty ? "Active pump alert" : alert.detail
            add(
                NotificationRules.category(for: alert), alert.severity, id: id, title: alert.title, body: body,
                pumpAlert: alert)
        }
        return out
    }

    private func announce(
        _ category: NotificationBroker.Category, _ severity: AlertSeverity, id: String, title: String, body: String
    ) -> [AlertRequest] {
        let decision = NotificationBroker.decide(category, policy: policy)
        guard let level = decision.level else { return [] }
        return [
            AlertRequest(
                identifier: id, category: category, severity: severity, level: level,
                escalation: decision.escalation ?? .none, title: title, body: body)
        ]
    }

    /// Diff what should be held against what was handed to the OS, then queue the withdrawals, the changed
    /// posts and the announcements, in that order. An announcement that reuses a withdrawn identifier (a
    /// settled bolus replacing its unknown notice) is posted after the withdrawal, so it stands.
    private mutating func commit(_ announcements: [AlertRequest], now: Date) -> [Pending] {
        let desired = desired(now: now)
        var effects: [AlertEffect] = []
        // An identifier an announcement posts again needs no withdrawal first: the post replaces it, and a
        // withdrawal racing the post could remove the announcement.
        let reposted = Set(announcements.map(\.identifier))
        let gone = state.posted.keys.filter { desired[$0] == nil && !reposted.contains($0) }.sorted()
        if !gone.isEmpty { effects.append(.withdraw(gone)) }
        for id in desired.keys.sorted() {
            if let request = desired[id], !request.presentsLike(state.posted[id]) { effects.append(.post(request)) }
        }
        state.posted = desired
        effects += announcements.map(AlertEffect.post)
        var pending: [Pending] = []
        for effect in effects {
            // A post still owed for an identifier that is now withdrawn or posted again is dropped, so a
            // stale request is never shown just before its withdrawal or replacement (after a crash, or
            // while a drain awaits the OS). The new effect itself is always kept: the old post may already
            // be with the OS.
            let superseded: Set<String>
            switch effect {
            case .post(let request): superseded = [request.identifier]
            case .withdraw(let ids): superseded = Set(ids)
            }
            state.outbox.removeAll {
                if case .post(let request) = $0.effect { return superseded.contains(request.identifier) }
                return false
            }
            for id in superseded { state.refused[id] = nil }
            let next = Pending(sequence: state.nextSequence, effect: effect)
            state.nextSequence += 1
            state.outbox.append(next)
            pending.append(next)
        }
        return pending
    }

    // MARK: - Reading

    /// An unknown outcome nobody has confirmed: the in-app banner shows.
    public var hasOpenBolusResult: Bool { state.boluses.values.contains { $0.phase == .unknown } }

    /// The notifications showing at `now`: those held and already fired, most severe first. What the watch
    /// mirrors (R12): a category that is off on the phone is absent here too.
    public func active(now: Date) -> [ActiveAlert] {
        state.posted.values.filter { $0.hasFired(by: now) }
            .map(ActiveAlert.init)
            .sorted { ($0.severity, $1.identifier) > ($1.severity, $0.identifier) }
    }
}

/// A notification that is showing, for the in-app list and the watch.
public struct ActiveAlert: Sendable, Hashable {
    public var identifier: String
    public var category: NotificationBroker.Category
    public var severity: AlertSeverity
    public var title: String
    public var body: String
    /// The pump notification it mirrors, for a dismiss from the app or the watch.
    public var pumpAlert: PumpAlert?
    /// How the phone posted it and how the watch should: the watch follows the phone, capped at its
    /// vibrating rung.
    public var phoneIntent: NotificationRules.Intent
    public var watchIntent: NotificationRules.Intent

    init(_ request: AlertRequest) {
        identifier = request.identifier
        category = request.category
        severity = request.severity
        title = request.title
        body = request.body
        pumpAlert = request.pumpAlert
        phoneIntent = NotificationRules.Intent(level: request.level)
        watchIntent = Swift.min(phoneIntent, .alert)
    }
}
