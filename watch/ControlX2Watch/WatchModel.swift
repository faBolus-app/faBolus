import Foundation
import Observation

/// Watch-side remote state. Talks to the iPhone host over `RemoteLink` (WatchConnectivity):
/// sends bolus requests, reflects status echoed back. The watch is a dumb remote — it never
/// touches the pump (PumpX2Kit runs on the phone). Mirrors the data the phone + Garmin show.
@MainActor
@Observable
final class WatchModel {
    // Glucose
    var glucose: Int?
    var glucoseDate: Date?             // for 6-min staleness
    var trend: String = "→"           // Unicode arrow
    var history: [Int] = []            // recent mg/dL, oldest→newest (for the chart)
    // Pump status
    var iobUnits: Double = 0
    var reservoirUnits: Double = 0
    var batteryPercent: Int = 0
    var lastBolusUnits: Double?
    var connection: String = ""
    // Calculator settings
    var carbRatio: Double = 0
    var isf: Int = 0
    var targetBg: Int = 0
    var maxBolusUnits: Double = 25
    // Entry prefs (from phone Settings — the watch/Garmin increments)
    var bolusIncrement: Double = 0.05
    var carbIncrement: Double = 5
    var defaultMode: String = "carbs"
    // Alerts + link
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
    var cgmActive: Bool { glucose != nil && !isGlucoseStale }
    var ageMinutes: Int? {
        guard let d = glucoseDate else { return nil }
        return max(0, Int(Date().timeIntervalSince(d) / 60))
    }

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
            if let b = cmd.batteryPercent { batteryPercent = Int(b) }
            if let cr = cmd.carbRatio { carbRatio = cr }
            if let i = cmd.isf { isf = Int(i) }
            if let tb = cmd.targetBg { targetBg = Int(tb) }
            if let mx = cmd.maxBolusUnits, mx > 0 { maxBolusUnits = mx }
            if let bi = cmd.bolusIncrement, bi > 0 { bolusIncrement = bi }
            if let ci = cmd.carbIncrement, ci > 0 { carbIncrement = ci }
            if let m = cmd.bolusMode { defaultMode = m }
            if let msg = cmd.message { connection = msg }
            if let h = cmd.history { history = h }
            lastBolusUnits = cmd.lastBolusUnits
            if let a = cmd.alerts { alerts = a }
        default:
            break
        }
    }

    /// Send a units bolus the watch already confirmed (hold-to-deliver). The phone delivers it
    /// directly through the validated signed path (like the Garmin remote).
    func deliverUnits(_ units: Double) {
        startPending(RemoteCommand(kind: .bolusRequest, units: units))
    }

    /// Send a carbs bolus; the phone converts carbs→units with the pump's calculator, then delivers.
    func deliverCarbs(_ grams: Double) {
        startPending(RemoteCommand(kind: .bolusRequest, carbsGrams: grams, bgMgdl: glucose.map(Double.init)))
    }

    private func startPending(_ cmd: RemoteCommand) {
        pendingRequestId = cmd.requestId
        lastStatus = .delivering
        statusMessage = "Delivering…"
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

    /// Loop-style band color for a glucose value.
    static func color(_ mgdl: Int) -> Int { RemoteGlucose.band(mgdl) }
}

/// Shared glucose banding so the watch views color consistently.
enum RemoteGlucose {
    static func band(_ mgdl: Int) -> Int {
        switch mgdl { case ..<70: return 0; case 70..<180: return 1; case 180..<250: return 2; default: return 3 }
    }
}
