import Foundation
import faBolusCore
import WidgetKit

/// macOS remote state. A subclass of the shared `RemoteClientModel` that connects over `BLELink`
/// (Bluetooth LE, central role), publishes a richer `WidgetSnapshot` for the Mac widgets, and relays
/// the interactive quick-bolus widget's confirmed dose to the phone. It never touches the pump.
///
/// Before it can do any of that it must **authenticate** to the phone with the one-time-code
/// handshake (`MacPairing`): on connect it sends `authHello`; a stored token authenticates a known
/// phone automatically, otherwise the user enters the code shown on the phone. On success both ends
/// hold a long-term token, so future reconnects need no code.
@MainActor
final class MacRemoteModel: RemoteClientModel {
    private var widgetRequestId: String?
    private var widgetBolus: MacWidgetBolusReceiver?
    private(set) var pairing: MacConnection!
    let display = MacDisplayModel()

    private let ble: BLELink
    private var peer: BLELink { ble }
    private var sealed: SealedTransport? { link as? SealedTransport }
    private let clientId = MacAuthStore.clientId()
    private let macName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName

    // Handshake state (one exchange at a time).
    private var hsSecret: Data?
    private var hsMacNonce: Data?
    private var hsPhoneNonce: Data?
    private var hsFirstPairing = false
    private var hsCode: String?          // the code being tried on a first pairing

    var deltaText: String? {
        guard history.count >= 2 else { return nil }
        let delta = history[history.count - 1] - history[history.count - 2]
        return delta >= 0 ? "+\(delta)" : "\(delta)"
    }

    init() {
        let ble = BLELink(role: .central)
        self.ble = ble
        super.init(link: SealedTransport(inner: ble))   // encrypts all traffic after the handshake
        pairing = MacConnection(peer: ble)   // reads the remembered phone and starts connecting
        widgetBolus = MacWidgetBolusReceiver(model: self)
        // No requestStatus() here — we ask only after we authenticate.
    }

    override func reachabilityDidChange(_ r: Bool) {
        super.reachabilityDidChange(r)
        pairing?.connected = r
        if r {
            startHandshake()
        } else {
            pairing?.authenticated = false
            sealed?.endSession()   // require a fresh handshake on the next connection
            resetHandshake()
        }
    }

    // MARK: - Pairing UI actions (called from MacConnectionView)

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
        hsCode = code.filter(\.isNumber)
        pairing.needsCode = false
        pairing.pairingError = nil
        startHandshake()
    }

    func cancelPairing() {
        pairing.needsCode = false
        pairing.pairingPhone = nil
        pairing.pairingError = nil
        resetHandshake()
    }

    private func resetHandshake() {
        hsSecret = nil; hsMacNonce = nil; hsPhoneNonce = nil; hsFirstPairing = false; hsCode = nil
    }

    // MARK: - Handshake (Mac = prover)

    private func startHandshake() {
        guard peer.isReachable, !(pairing?.authenticated ?? false) else { return }
        guard let name = pairing?.pairedPhone else { return }
        if let token = MacAuthStore.token(forPhone: name) {
            hsSecret = token; hsFirstPairing = false
        } else if let code = hsCode {
            hsSecret = MacPairing.secret(code: code); hsFirstPairing = true
        } else {
            pairing?.needsCode = true   // need the code before we can prove anything
            return
        }
        let mNonce = MacPairing.newNonce(); hsMacNonce = mNonce
        link.send(.auth(.authHello, clientId: clientId, nonce: mNonce.base64EncodedString(), message: macName))
    }

    override func handle(_ cmd: RemoteCommand) {
        switch cmd.kind {
        case .authChallenge:
            guard let secret = hsSecret, let mNonce = hsMacNonce,
                  let pB64 = cmd.authNonce, let pNonce = Data(base64Encoded: pB64) else { return }
            hsPhoneNonce = pNonce
            let proof = MacPairing.proof(secret: secret, label: "mac",
                                         phoneNonce: pNonce, macNonce: mNonce, clientId: clientId)
            link.send(.auth(.authProof, clientId: clientId, proof: proof))

        case .authResult:
            handleAuthResult(cmd)

        default:
            super.handle(cmd)   // normal status/bolus echoes (only arrive once authenticated)
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
    }

    private func handleAuthResult(_ cmd: RemoteCommand) {
        guard cmd.authOK == true else {
            pairing.pairingError = cmd.message ?? "Pairing failed."
            pairing.needsCode = true          // let the user re-enter the code
            hsSecret = nil; hsFirstPairing = false; hsCode = nil
            return
        }
        guard let secret = hsSecret, let mNonce = hsMacNonce, let pNonce = hsPhoneNonce,
              let phoneProof = cmd.authProof,
              MacPairing.verify(phoneProof, secret: secret, label: "phone",
                                phoneNonce: pNonce, macNonce: mNonce, clientId: clientId) else {
            pairing.pairingError = "Couldn’t verify the iPhone."
            resetHandshake()
            return
        }
        // On first pairing, unseal + persist the long-term token so later reconnects need no code.
        if hsFirstPairing {
            guard let sealed = cmd.authSealedToken, let code = hsCode,
                  let token = MacPairing.openToken(sealed, code: code) else {
                pairing.pairingError = "Pairing failed — please try again."
                pairing.needsCode = true
                return
            }
            MacAuthStore.saveToken(token, forPhone: pairing.pairedPhone ?? macName)
        }
        // Turn on channel encryption for the rest of this connection before any non-auth send.
        sealed?.activateSession(secret: secret, phoneNonce: pNonce, macNonce: mNonce)
        pairing.authenticated = true
        pairing.needsCode = false
        pairing.pairingPhone = nil
        pairing.pairingError = nil
        hsCode = nil; hsFirstPairing = false
        requestStatus()   // now trusted — pull a fresh snapshot
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
                                  carbRatio: carbRatio, isf: isf, targetBg: targetBg, maxBolusUnits: maxBolusUnits)
        WidgetStore.save(snap)
        WidgetBolusStore.increment = bolusIncrement
        WidgetBolusStore.carbIncrement = carbIncrement
        if maxBolusUnits > 0 { WidgetBolusStore.maxBolus = maxBolusUnits }
        WidgetBolusStore.defaultMode = defaultMode
        WidgetCenter.shared.reloadAllTimelines()
    }

    private func reloadQuickBolus() { WidgetCenter.shared.reloadTimelines(ofKind: "FaBolusQuickBolus") }
}
