import Foundation

/// iPhone-side receiver for remote (watch/Garmin) commands. Implements the phone half of the
/// double-confirmation: a remote `bolusRequest` becomes a `pendingRemoteBolus` the iOS UI must
/// explicitly confirm before `AppModel` delivers. Status is echoed back to the remote.
@MainActor
public final class PhoneRemoteHost {
    private let link = RemoteLink()
    private weak var model: AppModel?

    public init(model: AppModel) {
        self.model = model
        link.onReceive = { [weak self] cmd in self?.handle(cmd) }
        model.addRemoteEcho { [weak self] cmd in self?.link.send(cmd) }
        // Proactively push status to the watch when pump data changes.
        model.addStatusListener { [weak self] _ in
            guard let self, let m = self.model else { return }
            self.link.send(m.statusCommand(includeHistory: false))
        }
    }

    private func handle(_ cmd: RemoteCommand) {
        guard let model else { return }
        switch cmd.kind {
        case .bolusRequest:
            guard let units = cmd.units else { return }
            model.presentRemoteBolus(requestId: cmd.requestId, units: units)
            link.send(RemoteCommand(kind: .bolusStatus, requestId: cmd.requestId,
                                    status: .awaitingConfirm, message: "Confirm on iPhone"))
        case .cancelBolus:
            Task { await model.cancelBolus() }
            link.send(RemoteCommand(kind: .bolusStatus, requestId: cmd.requestId, status: .cancelled))
        case .dismissAlert:
            if let id = cmd.alertId, let k = cmd.alertKind {
                Task { await model.dismissAlert(id: id, kind: k); self.link.send(model.statusCommand(includeHistory: false)) }
            }
        case .statusRead:
            link.send(model.statusCommand(includeHistory: false))
        default:
            break
        }
    }
}
