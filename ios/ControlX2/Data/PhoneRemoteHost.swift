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
        model.remoteStatusEcho = { [weak self] cmd in self?.link.send(cmd) }
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
        case .statusRead:
            let s = model.snapshot
            link.send(RemoteCommand(kind: .statusRead,
                                    units: s.iobUnits,
                                    bgMgdl: s.glucose.map(Double.init),
                                    message: s.connection.rawValue))
        default:
            break
        }
    }
}
