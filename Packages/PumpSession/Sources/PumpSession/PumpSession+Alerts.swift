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
        guard alert.isDismissable, !alert.isMalfunction else { return .unsupported }
        guard state.link.isConnected else { return .unconfirmed }
        guard let kind = NotificationKind(rawValue: alert.kind.rawValue) else { return .unsupported }
        // A signed request is checked against the pump's clock, so it is read first.
        _ = await exchange(TimeSinceResetRequest(), priority: .user)
        let request = DismissNotificationRequest(kind: kind, notificationId: alert.id)
        switch await exchange(request, allowing: request.operationRisk, priority: .user) {
        case .reply(let reply):
            return (reply.message as? DismissNotificationResponse)?.status == 0 ? .cleared : .refused
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
}
