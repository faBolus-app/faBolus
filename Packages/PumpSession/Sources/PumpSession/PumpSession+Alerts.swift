import Foundation
import TandemLink
import TandemMessages
import faBolusCore

extension PumpSession {
    /// Asks the pump to dismiss one of its notifications (DismissNotification, op-184). Only an
    /// authenticated "cleared" lets a remote stop showing the alert. A pump that doesn't support remote
    /// dismissal, or a notification it marks not dismissable (a malfunction), gets nothing sent and says
    /// so. The pump's alerts are read again soon after either way.
    ///
    /// - Parameter wait: how long a clear asked for before the pump is reachable (a notification's Clear
    ///   that launched the app) waits for it: connected, identified and its alerts read, so the clear is
    ///   judged, and a remote-clear trial recorded, exactly as from the app. Past it, the clear goes the
    ///   same way it would have at once: `.unconfirmed` with no link.
    public func dismiss(_ alert: PumpAlert, waitingForLinkUpTo wait: TimeInterval = 0) async -> DismissOutcome {
        if wait > 0 { await waitForReachablePump(until: uptime().addingTimeInterval(wait)) }
        let outcome = await sendDismiss(alert)
        due[.alerts] = uptime()
        emit(.alertDismissed(alert, outcome))
        return outcome
    }

    /// Connected, identified and its alerts read in this process.
    var pumpReachable: Bool { state.link.isConnected && identity != nil && state.alerts != nil }

    private func waitForReachablePump(until deadline: Uptime) async {
        guard !pumpReachable, uptime() < deadline else { return }
        await withCheckedContinuation { linkWaiters.append((deadline, $0)) }
    }

    /// Lets the waiting clears go once the pump is reachable or their deadline has passed (`all`: the
    /// session is stopping).
    func resumeLinkWaiters(all: Bool = false) {
        guard !linkWaiters.isEmpty else { return }
        let now = uptime()
        let release = all || pumpReachable
        let (go, stay) = (
            linkWaiters.filter { release || now >= $0.deadline },
            linkWaiters.filter { !(release || now >= $0.deadline) }
        )
        linkWaiters = stay
        for waiter in go { waiter.continuation.resume() }
    }

    private func sendDismiss(_ alert: PumpAlert) async -> DismissOutcome {
        // The alert as the session holds it now: its remoteClear may have changed since the caller read it.
        let current = state.alerts?.value.first { $0.kind == alert.kind && $0.id == alert.id && !$0.isMalfunction }
        guard !alert.isMalfunction, (current ?? alert).remoteClear != .unavailable else { return .unsupported }
        guard state.link.isConnected else { return .unconfirmed }
        guard let kind = NotificationKind(rawValue: alert.kind.rawValue) else { return .unsupported }
        // A signed request is checked against the pump's clock, so it is read first.
        _ = await exchange(TimeSinceResetRequest(), priority: .user)
        let request = DismissNotificationRequest(kind: kind, notificationId: alert.id)
        switch await exchange(request, allowing: request.operationRisk, priority: .user) {
        case .reply(let reply):
            guard (reply.message as? DismissNotificationResponse)?.status == 0 else { return .refused }
            // Only an alert the session holds showing can be a trial: one it no longer holds may have been
            // cleared on the pump, and its absence after the clear would say nothing.
            guard alertLists.classClears == nil, current != nil else { return .cleared }
            return await trialCheck(alert)
        case .pumpError(let error):
            // BAD_OPCODE says the pump has no such command; the undefined code (0) says nothing definite.
            if error.isBadOpcode { return .unsupported }
            return error.errorCodeId == 0 ? .unconfirmed : .refused
        case .notSent(let reason):
            switch reason {
            case .unsupported, .signedWriteNotAllowed, .identityUnknown, .characteristicUnavailable: return .unsupported
            default: return .unconfirmed
            }
        case .unknown:
            return .unconfirmed
        }
    }

    /// Sets each alert's `remoteClear` from what's known for this pump's class and unit.
    func refreshRemoteClear() {
        alertLists.classClears = identity.flatMap { id in
            guard let model = id.model, let api = id.apiVersion else { return nil }
            return config.remoteClearClasses[PumpClass(model: model, apiVersion: api)]
        }
        alertLists.unitClears = identity?.unit.flatMap { record.remoteClearTrials[$0] }
        guard let current = state.alerts else { return }
        let merged = alertLists.merged
        guard merged != current.value else { return }
        state.alerts = Observed(
            merged, measuredAt: current.measuredAt, receivedAt: current.receivedAt, source: current.source)
        emitReadings([.alerts])
    }

    // MARK: - The remote-clear trial
    //
    // While the pump's class has no answer in `RemoteClearing.knownClasses`, the phone may try one clear
    // (an alert's `remoteClear` is `.tryable`) and the reads that follow decide it for the unit. Once the
    // bench settles the class, its row replaces all of this: `remoteClearTrialResult`, `trialCheck`,
    // `pendingTrial` and `settleRemoteClearTrial`, `PumpSessionRecord.remoteClearTrials`,
    // `DismissOutcome.notCleared` and `RemoteClear.tryable` go, with their tests.

    /// This unit's trial result, on this firmware; `nil` until a clear has been tried and checked.
    public var remoteClearTrialResult: RemoteClearEvidence? {
        guard let unit = identity?.unit else { return nil }
        return record.remoteClearTrials[unit]
    }

    /// The pump said it cleared `alert`. The read of its kind that follows says whether it did: gone, this unit
    /// acts on a remote clear. Still showing isn't recorded yet, because a pump may drop the alert a moment
    /// after answering: a routine read of the kind at least `trialSettle` later decides it. The user is told
    /// now that it isn't cleared. A read that doesn't come back leaves the pump's word and records nothing.
    private func trialCheck(_ alert: PumpAlert) async -> DismissOutcome {
        guard case .reply = await exchange(Self.statusRead(for: alert.kind), priority: .user) else { return .cleared }
        guard isShowing(alert.kind, alert.id) else {
            recordRemoteClearTrial(.clears)
            return .cleared
        }
        if let unit = identity?.unit {
            pendingTrial = PendingRemoteClearTrial(
                unit: unit, kind: alert.kind, id: alert.id, decideAfter: uptime().addingTimeInterval(Self.trialSettle))
        }
        return .notCleared
    }

    /// How long after a clear an alert still showing counts as one the pump didn't clear.
    static let trialSettle: TimeInterval = 5

    /// Decides a pending trial from a read of its kind once the settle has passed. Still showing: this unit
    /// doesn't act on a remote clear. Gone by then may be the pump acting late or the user clearing it on the
    /// pump, so nothing is recorded and the phone may try again.
    func settleRemoteClearTrial(after message: any TandemMessages.Message, now: Uptime) {
        guard let pending = pendingTrial, now >= pending.decideAfter, Self.statusKind(of: message) == pending.kind
        else { return }
        pendingTrial = nil
        guard identity?.unit == pending.unit, isShowing(pending.kind, pending.id) else { return }
        recordRemoteClearTrial(.doesNotClear)
    }

    private func isShowing(_ kind: PumpAlertKind, _ id: Int) -> Bool {
        (state.alerts?.value ?? []).contains { $0.kind == kind && $0.id == id && !$0.isMalfunction }
    }

    private func recordRemoteClearTrial(_ evidence: RemoteClearEvidence) {
        guard let unit = identity?.unit else { return }
        record.remoteClearTrials[unit] = evidence
        saveRecord()
        refreshRemoteClear()
    }

    private static func statusKind(of message: any TandemMessages.Message) -> PumpAlertKind? {
        switch message {
        case is AlertStatusResponse: return .alert
        case is AlarmStatusResponse: return .alarm
        case is ReminderStatusResponse: return .reminder
        case is CGMAlertStatusResponse: return .cgmAlert
        default: return nil
        }
    }

    private static func statusRead(for kind: PumpAlertKind) -> any TandemMessages.Message {
        switch kind {
        case .alert: return AlertStatusRequest()
        case .alarm: return AlarmStatusRequest()
        case .reminder: return ReminderStatusRequest()
        case .cgmAlert: return CGMAlertStatusRequest()
        }
    }
}

/// A trial clear whose alert was still showing right after it.
struct PendingRemoteClearTrial: Sendable, Equatable {
    let unit: PumpUnit
    let kind: PumpAlertKind
    let id: Int
    let decideAfter: Uptime
}
