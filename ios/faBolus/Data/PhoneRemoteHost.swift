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
            guard !AppSettings.shared.remotesReadOnly else {
                link.send(RemoteCommand(kind: .bolusStatus, requestId: cmd.requestId,
                                        status: .failed, message: "Read-only mode"))
                return
            }
            // The Apple Watch confirms on-device (hold-to-deliver), like the Garmin. The host is the
            // single calculator: `remoteDeliver` recomputes carbs→units, runs the divergence guard vs
            // the watch's own estimate, records carbs on the pump, and echoes the outcome.
            Task {
                await model.remoteDeliver(requestId: cmd.requestId, units: cmd.units,
                                          carbsGrams: cmd.carbsGrams, bgMgdl: cmd.bgMgdl.map(Int.init),
                                          remoteEstimate: cmd.remoteEstimateUnits)
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
            if cmd.forceGlucose == true {
                Task { await model.refreshGlucoseNow(); self.link.send(model.statusCommand(includeHistory: true)) }
            } else {
                link.send(model.statusCommand(includeHistory: true))
            }
        case .eatingEvent:
            // Apple Watch on-device detector relayed a p(eating) — feed the fusion engine. Advisory.
            if let p = cmd.eatingProb { model.ingestWatchEatingEvent(prob: p) }
        case .suspendPump:
            guard !AppSettings.shared.remotesReadOnly else { return }
            model.requestRemoteControl(requestId: cmd.requestId, action: .suspend)
        case .resumePump:
            guard !AppSettings.shared.remotesReadOnly else { return }
            model.requestRemoteControl(requestId: cmd.requestId, action: .resume)
        default:
            break
        }
    }
}
