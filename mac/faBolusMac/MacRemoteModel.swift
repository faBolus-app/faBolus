import Foundation
import faBolusCore
import WidgetKit

/// macOS remote state. A thin subclass of the shared `AuthenticatingRemoteClientModel`: it supplies
/// the Mac's token store + display name and wires the pairing UI (`MacConnection`), publishes a
/// richer `WidgetSnapshot` for the Mac widgets, and relays the interactive quick-bolus widget's
/// confirmed dose. The one-time-code handshake + channel encryption live in the shared base. It never
/// touches the pump.
@MainActor
final class MacRemoteModel: AuthenticatingRemoteClientModel {
    private var widgetRequestId: String?
    private var widgetBolus: MacWidgetBolusReceiver?
    private(set) var pairing: MacConnection!
    let display = MacDisplayModel()

    private let ble: BLELink

    var deltaText: String? {
        guard history.count >= 2 else { return nil }
        let delta = history[history.count - 1] - history[history.count - 2]
        return delta >= 0 ? "+\(delta)" : "\(delta)"
    }

    init() {
        let ble = BLELink(role: .central)
        self.ble = ble
        let macName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        super.init(link: SealedTransport(inner: ble),
                   clientId: MacAuthStore.clientId(), displayName: macName,
                   tokenFor: { MacAuthStore.token(forPhone: $0) },
                   saveToken: { MacAuthStore.saveToken($0, forPhone: $1) })
        pairing = MacConnection(peer: ble)   // reads the remembered phone and starts connecting
        widgetBolus = MacWidgetBolusReceiver(model: self)
        // No requestStatus() here — we ask only after we authenticate.
    }

    // MARK: - Shared-base hooks (wire the handshake to MacConnection's observable UI state)

    override func currentHostName() -> String? { pairing?.pairedPhone }

    override func handshakeNeedsCode() { pairing?.needsCode = true }

    override func handshakeFailed(_ message: String) {
        pairing.pairingError = message
        pairing.needsCode = true   // let the user re-enter the code
    }

    override func handshakeSucceeded() {
        pairing.authenticated = true
        pairing.needsCode = false
        pairing.pairingPhone = nil
        pairing.pairingError = nil
    }

    override func reachabilityDidChange(_ r: Bool) {
        super.reachabilityDidChange(r)   // base drives the handshake + ends the sealed session
        pairing?.connected = r
        pairing?.connectedName = r ? ble.connectedPeerName : nil
        if !r { pairing?.authenticated = false }
    }

    // MARK: - Pairing UI actions (called from the Mac Settings/Connection view)

    /// Begin pairing with a discovered iPhone. A known phone (has a token) authenticates silently;
    /// a new one prompts for its one-time code.
    func beginPair(with name: String) {
        pairing.pairingError = nil
        if MacAuthStore.token(forPhone: name) != nil {
            pairing.needsCode = false
            pairing.pairingPhone = nil
        } else {
            pairing.pairingPhone = name
            pairing.needsCode = true
        }
        pairing.connect(to: name)   // handshake runs once the link is up (or after submitCode)
    }

    /// The user entered the one-time code shown on the phone.
    func submitCode(_ code: String) {
        pairing.needsCode = false
        pairing.pairingError = nil
        provideCode(code)   // base restarts the handshake with the code
    }

    /// A scanned pairing QR: select the encoded iPhone and use its high-entropy code.
    func applyScannedPayload(_ payload: PeerPairingPayload) {
        pairing.pairingError = nil
        pairing.pairingPhone = payload.hostName
        pairing.needsCode = false
        pairing.connect(to: payload.hostName)
        provideCode(payload.code)
    }

    func cancelPairing() {
        pairing.needsCode = false
        pairing.pairingPhone = nil
        pairing.pairingError = nil
        resetHandshake()
    }

    // MARK: - Status + widget mirroring

    override func handle(_ cmd: RemoteCommand) {
        super.handle(cmd)   // base: auth handshake; else RemoteClientModel status/bolus handling
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

    // MARK: - Widget quick-bolus

    func deliverWidgetPending() {
        guard pairing?.authenticated == true, let r = WidgetBolusStore.takePending() else { return }
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
                                  carbRatio: carbRatio, isf: isf, targetBg: targetBg, maxBolusUnits: maxBolusUnits,
                                  // Publish the phone's freshness policy so the widgets grey/hide like the app.
                                  staleAfterSec: GlucoseFreshness.staleAfter, hideAfterSec: GlucoseFreshness.hideAfter)
        WidgetStore.save(snap)
        WidgetBolusStore.increment = bolusIncrement
        WidgetBolusStore.carbIncrement = carbIncrement
        if maxBolusUnits > 0 { WidgetBolusStore.maxBolus = maxBolusUnits }
        WidgetBolusStore.defaultMode = defaultMode
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func reloadQuickBolus() { WidgetCenter.shared.reloadTimelines(ofKind: "FaBolusQuickBolus") }
}
