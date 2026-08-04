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
    var isPaired: Bool { WatchPairingStore.load() != nil }

    private let client = PumpBLEClient(restoreIdentifier: "com.fabolus.app.watch.pump")
    private var coordinator: PairingCoordinator?
    private var pairingCode = ""
    private var authenticationKey: [UInt8] = []

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
        let coord: PairingCoordinator
        let isFull: Bool
        if !pairingCode.isEmpty, let full = try? PairingCoordinator(pairingCode: pairingCode) {
            coord = full; isFull = true
        } else if let stored = WatchPairingStore.load() {
            coord = PairingCoordinator(resumeDerivedSecret: stored); isFull = false
        } else {
            pairState = .failed("No code or saved pairing"); return
        }
        coord.onSendRequest = { [weak self] msg in try? self?.client.send(msg) }   // AUTHORIZATION passes the interlock
        coord.onError = { [weak self] e in
            if !isFull { WatchPairingStore.clear() }   // a bad stored secret → forget it
            self?.pairState = .failed("\(e)")
        }
        coord.onPaired = { [weak self] key, _ in
            guard let self else { return }
            self.authenticationKey = key
            if isFull { WatchPairingStore.save(coord.derivedSecret); self.pairingCode = "" }
            self.pairState = .paired
        }
        coordinator = coord
        pairState = .pairing
        coord.start()
    }

    func pumpClient(_ c: PumpBLEClient, didReceiveFrame frame: [UInt8], on ch: Characteristic) {
        if ch == .authorization { coordinator?.handle(frame: frame) }
        // Phase 2 will parse status/control responses here.
    }

    func pumpClient(_ c: PumpBLEClient, didError error: Error) {
        pairState = .failed("\(error)")
    }
}
