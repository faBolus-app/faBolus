import Foundation
import Observation

/// Watch-side remote state. Talks to the iPhone host over `RemoteLink` (WatchConnectivity):
/// sends bolus requests, reflects status echoed back. The watch is a dumb remote — it never
/// touches the pump (PumpX2Kit runs on the phone).
@MainActor
@Observable
final class WatchModel {
    var glucose: Int?
    var trend: String = "→"
    var iobUnits: Double = 0
    var reachable: Bool = false
    var lastStatus: RemoteCommand.Status?
    var statusMessage: String?
    var pendingRequestId: String?

    private let link = RemoteLink()

    init() {
        link.onReachabilityChange = { [weak self] r in self?.reachable = r }
        link.onReceive = { [weak self] cmd in self?.handle(cmd) }
        reachable = link.isReachable
    }

    private func handle(_ cmd: RemoteCommand) {
        switch cmd.kind {
        case .bolusStatus:
            if cmd.requestId == pendingRequestId {
                lastStatus = cmd.status
                statusMessage = cmd.message
            }
        case .statusRead:
            if let g = cmd.bgMgdl { glucose = Int(g) }
            if let iob = cmd.units { iobUnits = iob }
        default:
            break
        }
    }

    /// Sends a units-only bolus request; the phone runs the confirm interlock (double-confirm).
    func requestBolus(units: Double) {
        let cmd = RemoteCommand(kind: .bolusRequest, units: units)
        pendingRequestId = cmd.requestId
        lastStatus = .awaitingConfirm
        statusMessage = "Confirm on iPhone"
        link.send(cmd)
    }

    func cancel() {
        guard let id = pendingRequestId else { return }
        link.send(RemoteCommand(kind: .cancelBolus, requestId: id))
    }

    func requestStatus() { link.send(RemoteCommand(kind: .statusRead)) }
}
