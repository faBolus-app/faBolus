import Foundation
import faBolusCore

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
        // Proactively push status (with history for the watch chart) when pump data changes.
        model.addStatusListener { [weak self] _ in
            guard let self, let m = self.model else { return }
            self.link.send(m.statusCommand(includeHistory: true))
        }
    }

    private func handle(_ cmd: RemoteCommand) {
        guard let model else { return }
        switch cmd.kind {
        case .bolusRequest:
            // The Apple Watch confirms on-device (hold-to-deliver), like the Garmin — deliver
            // directly through the validated signed path. Carbs are converted to units first.
            Task {
                let units: Double
                if let carbs = cmd.carbsGrams, carbs > 0 {
                    let rec = await model.recommendBolus(carbsGrams: carbs, bgMgdl: cmd.bgMgdl.map(Int.init) ?? model.snapshot.glucose)
                    units = rec.recommendedUnits
                } else {
                    units = cmd.units ?? 0
                }
                guard units > 0 else {
                    self.link.send(RemoteCommand(kind: .bolusStatus, requestId: cmd.requestId,
                                                 status: .failed, message: "No insulin needed"))
                    return
                }
                await model.remoteDeliver(requestId: cmd.requestId, units: units)
            }
        case .cancelBolus:
            // The in-flight delivery loop echoes the single final status; no echo here (else the
            // watch would flip cancelled → delivered when the bolus finishes first).
            Task { await model.cancelBolus() }
        case .dismissAlert:
            if let id = cmd.alertId, let k = cmd.alertKind {
                Task { await model.dismissAlert(id: id, kind: k); self.link.send(model.statusCommand(includeHistory: true)) }
            }
        case .statusRead:
            link.send(model.statusCommand(includeHistory: true))
        default:
            break
        }
    }
}
