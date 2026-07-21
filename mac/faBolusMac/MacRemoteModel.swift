import Foundation
import faBolusCore
import WidgetKit

/// macOS remote state. A thin subclass of the shared `RemoteClientModel` that connects over
/// `PeerLink` (MultipeerConnectivity, browser role) instead of WatchConnectivity, publishes a
/// richer `WidgetSnapshot` (with a sparkline + calculator config) for the Mac widgets, and relays
/// the interactive quick-bolus widget's confirmed dose to the phone over the same link. It never
/// touches the pump — the phone executes every bolus.
@MainActor
final class MacRemoteModel: RemoteClientModel {
    /// The requestId of a bolus that originated from the Mac quick-bolus widget, so its status
    /// echoes can be mirrored back into `WidgetBolusStore` for in-place progress/cancel.
    private var widgetRequestId: String?
    private var widgetBolus: MacWidgetBolusReceiver?
    /// Discovery/pairing state for the Settings → Connection screen. (Named `pairing` to avoid the
    /// base model's `connection` string, which mirrors the pump connection state.)
    private(set) var pairing: MacConnection!

    /// Typed access to the underlying transport for pairing.
    private var peer: PeerLink { link as! PeerLink }

    init() {
        super.init(link: PeerLink(role: .browser))
        pairing = MacConnection(peer: peer)   // reads the remembered phone and auto-connects
        widgetBolus = MacWidgetBolusReceiver(model: self)
        requestStatus()   // ask the phone for a snapshot as soon as we connect (queued until then)
    }

    override func reachabilityDidChange(_ r: Bool) {
        super.reachabilityDidChange(r)
        pairing?.connected = r
        if r { requestStatus() }   // fresh snapshot on (re)connect
    }

    override func handle(_ cmd: RemoteCommand) {
        super.handle(cmd)
        // Mirror the outcome of a widget-originated bolus back to the widget's App Group state.
        if cmd.kind == .bolusStatus, cmd.requestId == widgetRequestId {
            let phase: WidgetBolusPhase
            switch cmd.status {
            case .delivered: phase = .delivered
            case .cancelled: phase = .cancelled
            case .failed, .outOfRange: phase = .failed
            default: phase = .delivering
            }
            WidgetBolusStore.setStatus(WidgetBolusStatus(phase: phase, deliveredUnits: cmd.deliveredUnits ?? 0,
                                                         requestId: cmd.requestId, message: cmd.message ?? ""))
            reloadQuickBolus()
            if phase != .delivering { widgetRequestId = nil }
        }
    }

    /// Deliver a dose the Mac quick-bolus widget confirmed (1-2-3). Sent over the link with the
    /// widget's own requestId so the phone's echo correlates back to the widget's status.
    func deliverWidgetPending() {
        guard let r = WidgetBolusStore.takePending() else { return }
        widgetRequestId = r.requestId
        let cmd: RemoteCommand
        if r.mode == "carbs" {
            let bg: Double? = isGlucoseStale ? nil : glucose.map(Double.init)
            cmd = RemoteCommand(kind: .bolusRequest, requestId: r.requestId, carbsGrams: r.amount, bgMgdl: bg)
        } else {
            cmd = RemoteCommand(kind: .bolusRequest, requestId: r.requestId, units: r.amount)
        }
        startPending(cmd)
        WidgetBolusStore.setStatus(WidgetBolusStatus(phase: .delivering, units: r.mode == "units" ? r.amount : 0,
                                                     requestId: r.requestId))
        reloadQuickBolus()
    }

    override func publishSnapshot() {
        // Build a sparkline from the relayed history (values only; synthesize ~5-min timestamps).
        let now = Date()
        let recent = history.suffix(48)
        let points = recent.enumerated().map { i, mgdl in
            WidgetSnapshot.Point(t: now.addingTimeInterval(Double(i - recent.count) * 300), mgdl: mgdl)
        }
        let snap = WidgetSnapshot(glucose: glucose, glucoseDate: glucoseDate, trendArrow: trend,
                                  iobUnits: iobUnits, reservoirUnits: reservoirUnits,
                                  batteryPercent: batteryPercent, lastBolusUnits: lastBolusUnits,
                                  connected: reachable, updatedAt: now, recentPoints: Array(points),
                                  activeAlerts: alerts.map(\.title), cgmActive: cgmActive,
                                  carbRatio: carbRatio, isf: isf, targetBg: targetBg, maxBolusUnits: maxBolusUnits)
        WidgetStore.save(snap)
        // Keep the interactive quick-bolus widget's picker in sync with the phone's settings.
        WidgetBolusStore.increment = bolusIncrement
        WidgetBolusStore.carbIncrement = carbIncrement
        if maxBolusUnits > 0 { WidgetBolusStore.maxBolus = maxBolusUnits }
        WidgetBolusStore.defaultMode = defaultMode
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func reloadQuickBolus() { WidgetCenter.shared.reloadTimelines(ofKind: "FaBolusQuickBolus") }
}
