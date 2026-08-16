import Foundation
import faBolusCore
import Observation
import CoreBluetooth
import PumpX2BLE
import PumpX2Auth
import PumpX2Messages

/// Phase 1 of the independent (direct-to-pump) watch: connect to the pump over the **watch's own**
/// Bluetooth and run the **full JPAKE pairing** with a 6-digit code entered on the watch, storing
/// the derived secret in the watch Keychain. Later connects resume-auth with that secret.
///
/// This is the direct path; the rest of the watch app still uses the iPhone relay until the
/// direct client is promoted (Phase 2: status polling + signed delivery).
@MainActor
@Observable
final class WatchPumpClient: PumpBLEClientDelegate {
    enum PairState: Equatable {
        case idle, connecting, pairing, paired, failed(String)
    }
    var pairState: PairState = .idle
    var isPaired: Bool { WatchPairingStore.hasAnyPairing }

    /// Phase 09.6-07 (D-03.1, bench-only): app-wide weak reference so `WatchModel` can read this
    /// client's already-tracked `statusForDiagnostics` when replying to a `.diagnosticsRead` request,
    /// without threading it through `WatchModel`'s init — mirrors `PhoneRemoteHost.shared` /
    /// `GarminRemoteBridge.shared`'s precedent. Set once, by this class's own init (the sole instance
    /// is `WatchRootView`'s `@State private var directPump`). Read-only from `WatchModel`'s
    /// perspective — no control-path exposure.
    static weak var shared: WatchPumpClient?

    /// Phase 09.6-05 (Part C-3b, D-03.3, bench-only): read-only status accessor for `WatchDebugView`
    /// — a short, human-readable rendering of `pairState`. Additive (a computed property, not a new
    /// control-path `func`); calling it never touches BLE, the pump, or `client`/`coordinator`.
    var statusForDiagnostics: String {
        switch pairState {
        case .idle: return isPaired ? "Idle (paired, not connected)" : "Idle (not paired)"
        case .connecting: return "Connecting…"
        case .pairing: return "Pairing…"
        case .paired: return "Paired"
        case .failed(let msg): return "Failed: \(msg)"
        }
    }

    /// Valid iff a 6-digit (JPAKE) OR 16-char (legacy V1) code — mirrors the phone's `PumpPairingCode`.
    static func isValidPairingCode(_ code: String) -> Bool {
        (try? PairingAuth.processPairingCode(code, type: .short6Char)) != nil ||
        (try? PairingAuth.processPairingCode(code, type: .long16Char)) != nil
    }

    private let client = PumpBLEClient(restoreIdentifier: "com.fabolus.app.watch.pump")
    private var coordinator: (any PairingCoordinating)?
    private var pairingCode = ""
    private var authenticationKey: [UInt8] = []

    init() { Self.shared = self }

    /// Begin a fresh pairing with the code shown on the pump. Scans → connects → JPAKE.
    func pair(code: String) {
        pairingCode = code
        pairState = .connecting
        client.delegate = self
        client.startScan()
    }

    /// Reconnect using the stored secret (resume-auth), no code needed.
    func connectResume() {
        guard isPaired else { return }
        pairingCode = ""
        pairState = .connecting
        client.delegate = self
        client.startScan()
    }

    func disconnect() { client.disconnect(); pairState = isPaired ? .idle : pairState }

    func forget() {
        WatchPairingStore.clear()
        authenticationKey = []
        client.disconnect()
        pairState = .idle
    }

    // MARK: - PumpBLEClientDelegate

    func pumpClient(_ c: PumpBLEClient, didChange state: PumpBLEClient.State) {
        switch state {
        case .scanning, .connecting, .discovering:
            if pairState != .pairing, pairState != .paired { pairState = .connecting }
        case .disconnected, .idle:
            if pairState == .connecting { pairState = .failed("Disconnected") }
        case .poweredOff, .unauthorized, .unsupported:
            pairState = .failed("Bluetooth unavailable")
        default:
            break
        }
    }

    func pumpClient(_ c: PumpBLEClient, didDiscover peripheral: CBPeripheral, rssi: Int) {
        // Detect the model from the BLE name so the pairing screen can offer to save a Mobi's PIN.
        if let name = peripheral.name {
            if name.hasPrefix("Tandem Mobi") { WatchPumpModelStore.set(isMobi: true) }
            else if name.hasPrefix("tslim X2") { WatchPumpModelStore.set(isMobi: false) }
        }
        c.connect(peripheral)
    }

    func pumpClientDidBecomeReady(_ c: PumpBLEClient) {
        // Auto-select the scheme from the code (JPAKE 6-digit vs legacy V1 16-char), or resume/
        // re-challenge from saved material. `onFirstPair` is non-nil ONLY for a fresh full pair.
        let coord: any PairingCoordinating
        let onFirstPair: (() -> Void)?
        if !pairingCode.isEmpty {
            let code = pairingCode
            switch PairingAuth.detectType(code) {
            case .short6Char:
                guard let full = try? PairingCoordinator(pairingCode: code) else {
                    pairState = .failed("Invalid pairing code"); return
                }
                coord = full
                onFirstPair = { [weak self] in WatchPairingStore.save(full.derivedSecret); self?.pairingCode = "" }
            case .long16Char:
                guard let v1 = try? LegacyPairingCoordinator(pairingCode: code) else {
                    pairState = .failed("Invalid pairing code"); return
                }
                coord = v1
                onFirstPair = { [weak self] in WatchPairingStore.saveV1Code(code); self?.pairingCode = "" }
            }
        } else if let v1Code = WatchPairingStore.loadV1Code() {   // legacy reconnect: silent re-challenge
            guard let v1 = try? LegacyPairingCoordinator(pairingCode: v1Code) else {
                WatchPairingStore.clear(); pairState = .failed("No code or saved pairing"); return
            }
            coord = v1; onFirstPair = nil
        } else if let stored = WatchPairingStore.load() {          // modern reconnect: JPAKE resume
            coord = PairingCoordinator(resumeDerivedSecret: stored); onFirstPair = nil
        } else {
            pairState = .failed("No code or saved pairing"); return
        }
        coord.onSendRequest = { [weak self] msg in try? self?.client.send(msg) }   // AUTHORIZATION passes the interlock
        coord.onError = { [weak self] e in
            if onFirstPair == nil { WatchPairingStore.clear() }   // saved material failed → forget it
            self?.pairState = .failed("\(e)")
        }
        coord.onPaired = { [weak self] key, _ in
            guard let self else { return }
            self.authenticationKey = key
            onFirstPair?()   // first full pair: persist the derived secret (JPAKE) or the code (V1)
            self.pairState = .paired
        }
        coordinator = coord
        pairState = .pairing
        coord.start()
    }

    func pumpClient(_ c: PumpBLEClient, didReceiveFrame frame: [UInt8], on ch: Characteristic) {
        if ch == .authorization {
            // Validate the frame CRC-16 before the coordinator parses it inline (it bypasses
            // ResponseParser's CRC check) — a corrupted pairing reply must not advance the handshake.
            guard frame.count >= 5,
                  Bytes.calculateCRC16(Array(frame[0..<(frame.count - 2)])) == Array(frame[(frame.count - 2)...])
            else { return }
            coordinator?.handle(frame: frame)
        }
        // Phase 2 will parse status/control responses here.
    }

    func pumpClient(_ c: PumpBLEClient, didError error: Error) {
        pairState = .failed("\(error)")
    }
}
