import Foundation
import faBolusCore
import Observation
import WidgetKit

/// Transport-agnostic remote-client state shared by every faBolus remote that mirrors the phone
/// (Apple Watch over `RemoteLink`, Mac over `PeerLink`). It is a *dumb remote*: it never touches the
/// pump (PumpX2Kit runs on the phone). It sends bolus/cancel/dismiss/status commands and reflects the
/// status the phone echoes back, and publishes the latest glucose/pump state to the App Group for
/// this device's widgets/complication.
///
/// Not `final` so a platform can subclass it to add device-specific behavior (e.g. the watch's
/// direct-CGM failover); override `reachabilityDidChange(_:)` and call `super`.
@MainActor
@Observable
class RemoteClientModel {
    // Glucose
    var glucose: Int?
    var glucoseDate: Date?             // for staleness
    var trend: String = "→"           // Unicode arrow
    var history: [Int] = []            // recent mg/dL, oldest→newest (for the chart)
    // Pump status
    var iobUnits: Double = 0
    var reservoirUnits: Double = 0
    var batteryPercent: Int = 0
    var lastBolusUnits: Double?
    var connection: String = ""
    // Calculator settings (mirrored from the phone)
    var carbRatio: Double = 0
    var isf: Int = 0
    var targetBg: Int = 0
    var maxBolusUnits: Double = 25
    // Entry prefs (from phone Settings — the remote increments)
    var bolusIncrement: Double = 0.05
    var carbIncrement: Double = 5
    var defaultMode: String = "carbs"
    // Customization mirrored from the phone.
    var detailsOrder: [String] = ["iob", "reservoir", "battery", "cgm", "lastBolus", "carbRatio", "isf", "target", "maxBolus"]
    var chartRanges: [Int] = [3, 6, 12, 24]
    // Alerts + link
    var alerts: [RemoteCommand.RemoteAlert] = []
    var reachable: Bool = false
    var lastStatus: RemoteCommand.Status?
    var statusMessage: String?
    var pendingRequestId: String?

    /// Whether the phone has been seen bolusing since this request started — so a lost/late terminal
    /// echo can be recovered from the connection state (see handle(.statusRead)).
    @ObservationIgnored private var sawPhoneBolusing = false

    @ObservationIgnored let link: any RemoteTransport

    init(link: any RemoteTransport) {
        self.link = link
        link.onReachabilityChange = { [weak self] r in self?.reachabilityDidChange(r) }
        link.onReceive = { [weak self] cmd in self?.handle(cmd) }
        reachable = link.isReachable
    }

    /// Called when the link's reachability changes. Base updates `reachable`; subclasses override to
    /// add behavior (e.g. start/stop a direct-CGM failover) and must call `super`.
    func reachabilityDidChange(_ r: Bool) { reachable = r }

    // MARK: Derived display

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

    static func arrow(fromToken t: String?) -> String {
        switch t {
        case "up": return "↑"; case "upup": return "⇈"; case "up45": return "↗"
        case "down": return "↓"; case "downdown": return "⇊"; case "down45": return "↘"
        default: return "→"
        }
    }

    // MARK: Inbound

    func handle(_ cmd: RemoteCommand) {
        switch cmd.kind {
        case .bolusStatus:
            if cmd.requestId == pendingRequestId {
                lastStatus = cmd.status
                statusMessage = cmd.message
                // Reflect the actual delivered amount from the outcome echo immediately, so the
                // Details "Last bolus" shows the just-delivered value (e.g. 0.05 U) right away
                // instead of the previous bolus until the next status push arrives.
                if (cmd.status == .delivered || cmd.status == .cancelled), let d = cmd.deliveredUnits {
                    lastBolusUnits = d
                }
            }
        case .statusRead:
            // Treat a non-positive relayed value as "no reading" (nil) so the UI shows "—" instead of
            // a literal 0; a missing bgMgdl leaves the current value untouched.
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
            if let d = cmd.detailsOrder, !d.isEmpty { detailsOrder = d }
            if let r = cmd.watchChartRanges, !r.isEmpty { chartRanges = r }
            if let msg = cmd.message { connection = msg }
            // Recover from a lost/late terminal echo: once the phone has reported bolusing and then
            // reports it's no longer bolusing, the bolus is done even if the delivered/cancelled echo
            // never arrived — so we don't stay stuck in .delivering (which would also freeze "last
            // bolus"). Guarded by sawPhoneBolusing so the pre-bolus status push (phone not yet
            // bolusing) doesn't clear it prematurely.
            if connection == PumpConnectionState.bolusing.rawValue {
                sawPhoneBolusing = true
            } else if lastStatus == .delivering && sawPhoneBolusing {
                lastStatus = .delivered
            }
            if let h = cmd.history { history = h }
            // Don't overwrite last-bolus from a routine status push while a bolus is genuinely in
            // progress — that value is still the PREVIOUS bolus mid-delivery and would flicker
            // (e.g. 1.9 → 0.05). The .delivered/.cancelled echo (or the recovery above) settles it.
            if lastStatus != .delivering { lastBolusUnits = cmd.lastBolusUnits }
            if let a = cmd.alerts { alerts = a }
            // Mirror the phone's staleness policy so the remote marks/hides + stops using stale
            // readings for carb→unit exactly like the phone.
            if let s = cmd.glucoseStaleMinutes { GlucoseFreshness.staleAfter = TimeInterval(s) * 60 }
            GlucoseFreshness.hideAfter = cmd.glucoseHideDelayMinutes.map { GlucoseFreshness.staleAfter + TimeInterval($0) * 60 }
            publishSnapshot()
        default:
            break
        }
    }

    /// Publish the latest glucose/pump state to the App Group so this device's widgets/complication
    /// can show it. Reuses `WidgetSnapshot`/`WidgetStore` (a device-local App Group container).
    func publishSnapshot() {
        let snap = WidgetSnapshot(glucose: glucose, glucoseDate: glucoseDate, trendArrow: trend,
                                  iobUnits: iobUnits, reservoirUnits: reservoirUnits,
                                  batteryPercent: batteryPercent, lastBolusUnits: lastBolusUnits,
                                  connected: reachable, updatedAt: Date(),
                                  cgmActive: cgmActive, carbRatio: carbRatio, isf: isf,
                                  targetBg: targetBg, maxBolusUnits: maxBolusUnits)
        WidgetStore.save(snap)
        WidgetCenter.shared.reloadAllTimelines()
    }

    // MARK: Outbound

    /// Send a units bolus the remote already confirmed (hold-to-deliver). The phone delivers it
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

    /// Preview of the units the phone would deliver for a carb amount — mirrors the pump calculator
    /// (food = carbs ÷ carb ratio; plus a BG-vs-target correction minus IOB; rounded to 0.05 U), so a
    /// remote can show the estimated dose like the Garmin/phone. Returns nil until the carb ratio is
    /// known. A stale CGM value isn't used for the correction (matches `deliverCarbs`).
    func estimatedUnits(forCarbs grams: Double) -> Double? {
        guard carbRatio > 0, grams > 0 else { return carbRatio > 0 ? 0 : nil }
        let food = grams / carbRatio
        var correction = 0.0
        if !isGlucoseStale, let g = glucose, isf > 0 {
            correction = max(0, Double(g - targetBg) / Double(isf) - iobUnits)
        }
        return (max(0, food + correction) * 20).rounded() / 20
    }

    /// Send a bolus command and enter the pending/delivering state, correlating future echoes by its
    /// `requestId`. Internal so a subclass can drive it with a caller-supplied requestId (e.g. the
    /// Mac's widget quick-bolus, which must correlate the phone's echo to the widget request).
    func startPending(_ cmd: RemoteCommand) {
        pendingRequestId = cmd.requestId
        lastStatus = .delivering
        statusMessage = "Delivering…"
        sawPhoneBolusing = false
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

    /// modern band color index for a glucose value (0 low, 1 in-range, 2 high, 3 urgent-high).
    nonisolated static func band(_ mgdl: Int) -> Int {
        switch mgdl { case ..<70: return 0; case 70..<180: return 1; case 180..<250: return 2; default: return 3 }
    }
}
