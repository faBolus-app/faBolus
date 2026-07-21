import Foundation
import faBolusCore
import Observation
import WidgetKit

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
    /// Direct-to-watch CGM failover: when the iPhone is out of range, the watch reads glucose itself,
    /// phone-independent — a Dexcom G7/ONE+ over BLE, and/or xDrip4iOS via Apple Health (synced from
    /// the phone). Both reuse the shared sources; started only while unreachable, to save power.
    private let directSources: [any GlucoseSource] = [DexcomG7BLESource(), HealthKitGlucoseSource()]

    init() {
        link.onReachabilityChange = { [weak self] r in
            guard let self else { return }
            self.reachable = r
            if r { self.stopDirect() } else { self.startDirect() }
        }
        link.onReceive = { [weak self] cmd in self?.handle(cmd) }
        for s in directSources { s.onChange = { [weak self] in self?.applyDirect() } }
        reachable = link.isReachable
        if !reachable { startDirect() }
    }

    private func startDirect() { for s in directSources { Task { await s.start() } } }
    private func stopDirect() { for s in directSources { s.stop() } }

    /// Apply the freshest direct reading when the phone can't supply a fresher one (out of range, or
    /// the relayed value is older). Never overrides a fresher phone reading. Scans the sources (no
    /// per-source capture) to avoid a retain cycle on their `onChange`.
    private func applyDirect() {
        guard let s = directSources.compactMap({ $0.latest }).max(by: { $0.date < $1.date }) else { return }
        let fresher = glucoseDate.map { s.date > $0 } ?? true
        guard !reachable || fresher else { return }
        glucose = s.mgdl
        glucoseDate = s.date
        trend = s.trend.rawValue
        publishComplication()
    }

    /// Stale per the shared `GlucoseFreshness` threshold (default 6 min). A stale reading is shown
    /// but marked (grayed + age), never hidden — "old is worse than nothing".
    var isGlucoseStale: Bool {
        guard let d = glucoseDate else { return glucose != nil }
        return GlucoseFreshness.isStale(d)
    }
    var displayGlucose: String { glucose.map { "\($0)" } ?? "—" }
    var cgmActive: Bool { glucose != nil && !isGlucoseStale }
    var ageMinutes: Int? {
        guard let d = glucoseDate else { return nil }
        return max(0, Int(Date().timeIntervalSince(d) / 60))
    }
    /// Relative age label ("now", "3 min ago"), or nil when there's no reading yet.
    var ageLabel: String? { glucoseDate.map { GlucoseFreshness.ageLabel(for: $0) } }

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
            // Treat a non-positive relayed value as "no reading" (nil) so the complication/UI show
            // "—" instead of a literal 0; a missing bgMgdl leaves the current value untouched.
            if let g = cmd.bgMgdl { glucose = g > 0 ? Int(g) : nil }
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
            // Mirror the phone's staleness policy so the watch marks/hides + stops using stale
            // readings for carb→unit exactly like the phone.
            if let s = cmd.glucoseStaleMinutes { GlucoseFreshness.staleAfter = TimeInterval(s) * 60 }
            GlucoseFreshness.hideAfter = cmd.glucoseHideDelayMinutes.map { GlucoseFreshness.staleAfter + TimeInterval($0) * 60 }
            publishComplication()
        default:
            break
        }
    }

    /// Publish the latest glucose to the App Group so the watch-face complication can show it.
    /// Reuses `WidgetSnapshot`/`WidgetStore` (device-local App Group container on the watch).
    private func publishComplication() {
        let snap = WidgetSnapshot(glucose: glucose, glucoseDate: glucoseDate, trendArrow: trend,
                                  iobUnits: iobUnits, reservoirUnits: reservoirUnits,
                                  batteryPercent: batteryPercent, lastBolusUnits: lastBolusUnits,
                                  connected: reachable, updatedAt: Date())
        WidgetStore.save(snap)
        WidgetCenter.shared.reloadAllTimelines()
    }

    /// Send a units bolus the watch already confirmed (hold-to-deliver). The phone delivers it
    /// directly through the validated signed path (like the Garmin remote).
    func deliverUnits(_ units: Double) {
        startPending(RemoteCommand(kind: .bolusRequest, units: units))
    }

    /// Send a carbs bolus; the phone converts carbs→units with the pump's calculator, then delivers.
    /// A stale CGM value is never sent for the correction (matches the phone's rule).
    func deliverCarbs(_ grams: Double) {
        let bg: Double? = isGlucoseStale ? nil : glucose.map(Double.init)
        startPending(RemoteCommand(kind: .bolusRequest, carbsGrams: grams, bgMgdl: bg))
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

    /// modern band color for a glucose value.
    static func color(_ mgdl: Int) -> Int { RemoteGlucose.band(mgdl) }
}

/// Shared glucose banding so the watch views color consistently.
enum RemoteGlucose {
    static func band(_ mgdl: Int) -> Int {
        switch mgdl { case ..<70: return 0; case 70..<180: return 1; case 180..<250: return 2; default: return 3 }
    }
}
