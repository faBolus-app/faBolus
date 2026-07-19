import Foundation
import Observation

/// Watch-side remote state. Talks to the iPhone host over `RemoteLink` (WatchConnectivity):
/// sends bolus requests, reflects status echoed back. The watch is a dumb remote — it never
/// touches the pump (PumpX2Kit runs on the phone).
@MainActor
@Observable
final class WatchModel {
    var glucose: Int?
    var glucoseDate: Date?             // for 6-min staleness
    var trend: String = "→"           // Unicode arrow
    var iobUnits: Double = 0
    var reservoirUnits: Double = 0
    var lastBolusUnits: Double?
    var bolusIncrement: Double = 0.05   // from phone settings
    var alerts: [RemoteCommand.RemoteAlert] = []
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

    /// A CGM reading older than 6 minutes shouldn't be shown as current.
    var isGlucoseStale: Bool {
        guard let d = glucoseDate else { return glucose != nil }
        return Date().timeIntervalSince(d) > 6 * 60
    }
    var displayGlucose: String { (glucose != nil && !isGlucoseStale) ? "\(glucose!)" : "—" }

    private static func arrow(fromToken t: String?) -> String {
        switch t {
        case "up": return "↑"; case "upup": return "⇈"; case "up45": return "↗"
        case "down": return "↓"; case "downdown": return "⇊"; case "down45": return "↘"
        default: return "→"
        }
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
            if let age = cmd.glucoseAgeSec { glucoseDate = Date().addingTimeInterval(-age) }
            if let t = cmd.trend { trend = Self.arrow(fromToken: t) }
            if let iob = cmd.units { iobUnits = iob }
            if let r = cmd.reservoirUnits { reservoirUnits = r }
            if let bi = cmd.bolusIncrement, bi > 0 { bolusIncrement = bi }
            lastBolusUnits = cmd.lastBolusUnits
            if let a = cmd.alerts { alerts = a }
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

    func dismissAlert(_ a: RemoteCommand.RemoteAlert) {
        link.send(RemoteCommand(kind: .dismissAlert, alertId: a.id, alertKind: a.kind))
        alerts.removeAll { $0.id == a.id && $0.kind == a.kind }
    }

    func requestStatus() { link.send(RemoteCommand(kind: .statusRead)) }
}
