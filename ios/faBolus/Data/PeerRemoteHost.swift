import Foundation
import faBolusCore
import UIKit

/// iPhone-side receiver for the **Mac** remote, carried over `PeerLink` (MultipeerConnectivity)
/// since WatchConnectivity can't reach a Mac. Structurally identical to `PhoneRemoteHost` — it
/// translates the transport's `RemoteCommand`s into the same `AppModel` calls and echoes status
/// back — only the transport differs. `AppModel`'s echo broadcast fans out to every registered
/// remote, and each remote ignores `requestId`s it didn't send, so the Mac and Apple Watch coexist.
///
/// The Mac confirms on-device (hold-to-deliver / 1-2-3), like the Apple Watch and Garmin, so a
/// `bolusRequest` is delivered directly through the validated signed path.
@MainActor
public final class PeerRemoteHost {
    // Advertise under the device name ("Zev's iPhone") so the Mac can identify it when pairing.
    private let link = PeerLink(role: .advertiser, displayName: UIDevice.current.name)
    private weak var model: AppModel?

    public init(model: AppModel) {
        self.model = model
        link.onReceive = { [weak self] cmd in self?.handle(cmd) }
        model.addRemoteEcho { [weak self] cmd in self?.link.send(cmd) }
        // Proactively push status (with history for the Mac chart) when pump data changes.
        model.addStatusListener { [weak self] _ in
            guard let self, let m = self.model else { return }
            self.link.send(m.statusCommand(includeHistory: true))
        }
    }

    private func handle(_ cmd: RemoteCommand) {
        guard let model else { return }
        switch cmd.kind {
        case .bolusRequest:
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
            // Mac would flip cancelled → delivered when the bolus finishes first).
            Task { await model.cancelBolus() }
        case .dismissAlert:
            if let id = cmd.alertId, let k = cmd.alertKind {
                Task { await model.dismissAlert(id: id, kind: k); self.link.send(model.statusCommand(includeHistory: true)) }
            }
        case .statusRead:
            link.send(model.statusCommand(includeHistory: true))
        case .suspendPump:
            model.requestRemoteControl(requestId: cmd.requestId, action: .suspend)
        case .resumePump:
            model.requestRemoteControl(requestId: cmd.requestId, action: .resume)
        default:
            break
        }
    }
}
