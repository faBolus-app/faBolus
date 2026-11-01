import Foundation
import TandemLink
import TandemMessages
import faBolusCore

extension PumpSession {
    /// Asks the pump to dismiss one of its notifications (DismissNotification, op-184). Only an
    /// authenticated "cleared" lets a remote stop showing the alert. A pump that doesn't support remote
    /// dismissal, or a notification it marks not dismissable (a malfunction), gets nothing sent and says
    /// so. The pump's alerts are read again soon after either way.
    public func dismiss(_ alert: PumpAlert) async -> DismissOutcome {
        let outcome = await sendDismiss(alert)
        due[.alerts] = clock()
        emit(.alertDismissed(alert, outcome))
        return outcome
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
            return alertLists.classClears == nil ? await trialCheck(alert) : .cleared
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
    // (an alert's `remoteClear` is `.tryable`) and the read that follows decides it for the unit. Once the
    // bench settles the class, its row replaces all of this: `remoteClearTrialResult`, `trialCheck`,
    // `PumpSessionRecord.remoteClearTrials`, `DismissOutcome.notCleared` and `RemoteClear.tryable` go, with
    // their tests.

    /// This unit's trial result, on this firmware; `nil` until a clear has been tried and checked.
    public var remoteClearTrialResult: RemoteClearEvidence? {
        guard let unit = identity?.unit else { return nil }
        return record.remoteClearTrials[unit]
    }

    /// The pump said it cleared `alert`. The read of its kind that follows says whether it did, and that is
    /// recorded for this unit; only this read counts, so an alert cleared on the pump itself never does.
    /// A read that doesn't come back leaves the pump's word and records nothing.
    private func trialCheck(_ alert: PumpAlert) async -> DismissOutcome {
        guard case .reply = await exchange(Self.statusRead(for: alert.kind), priority: .user) else { return .cleared }
        let showing = (state.alerts?.value ?? []).contains {
            $0.kind == alert.kind && $0.id == alert.id && !$0.isMalfunction
        }
        if let unit = identity?.unit {
            record.remoteClearTrials[unit] = showing ? .doesNotClear : .clears
            saveRecord()
            refreshRemoteClear()
        }
        return showing ? .notCleared : .cleared
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
