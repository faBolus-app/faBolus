import Foundation
import faBolusCore
import UIKit

/// Discovery + pairing state for the "Control another phone" screen (this iPhone acting as a remote).
/// Mirrors the Mac's `MacConnection`: lists host iPhones the `BLELink` central found, remembers the
/// paired one, and reconnects automatically. Separate from the model so SwiftUI observes it.
@MainActor
@Observable
final class PhoneRemoteConnection {
    var discoveredHosts: [String] = []
    var pairedHost: String?
    var connected: Bool = false
    var authenticated: Bool = false
    var needsCode: Bool = false
    var pairingHost: String?
    var pairingError: String?

    @ObservationIgnored let peer: BLELink
    @ObservationIgnored private let defaultsKey = "remoteClientPairedHost"

    init(peer: BLELink) {
        self.peer = peer
        pairedHost = UserDefaults.standard.string(forKey: defaultsKey)
        connected = peer.isReachable
        peer.onPeersChanged = { [weak self] names in self?.discoveredHosts = names.sorted() }
        if let paired = pairedHost { peer.setPreferredPeer(paired) }
    }

    func connect(to name: String) {
        pairedHost = name
        UserDefaults.standard.set(name, forKey: defaultsKey)
        peer.setPreferredPeer(name)
    }

    func forget() {
        if let name = pairedHost { RemoteClientAuthStore.forget(host: name) }
        pairedHost = nil
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        peer.setPreferredPeer(nil)
        peer.disconnectAll()
        connected = false; authenticated = false; needsCode = false
        pairingHost = nil; pairingError = nil
    }
}

/// This iPhone acting as a **remote** for another phone's pump. A thin subclass of the shared
/// `AuthenticatingRemoteClientModel` (same one the Mac uses): it supplies the iPhone's token store +
/// display name and wires the pairing UI (`PhoneRemoteConnection`). The handshake + channel encryption
/// live in the shared base. It never touches a pump — it relays to the host phone.
@MainActor
final class PhoneRemoteClientModel: AuthenticatingRemoteClientModel {
    private(set) var conn: PhoneRemoteConnection!
    private let ble: BLELink

    init() {
        let ble = BLELink(role: .central)
        self.ble = ble
        super.init(link: SealedTransport(inner: ble),
                   clientId: RemoteClientAuthStore.clientId(),
                   displayName: UIDevice.current.name,
                   tokenFor: { RemoteClientAuthStore.token(forHost: $0) },
                   saveToken: { RemoteClientAuthStore.saveToken($0, forHost: $1) })
        conn = PhoneRemoteConnection(peer: ble)
    }

    /// Stop scanning/disconnect when the remote screen closes (the central runs only on demand).
    func stop() { ble.stop() }

    // MARK: Shared-base hooks
    override func currentHostName() -> String? { conn?.pairedHost }
    override func handshakeNeedsCode() { conn?.needsCode = true }
    override func handshakeFailed(_ message: String) { conn?.pairingError = message; conn?.needsCode = true }
    override func handshakeSucceeded() {
        conn?.authenticated = true; conn?.needsCode = false
        conn?.pairingHost = nil; conn?.pairingError = nil
    }
    override func reachabilityDidChange(_ r: Bool) {
        super.reachabilityDidChange(r)
        conn?.connected = r
        if !r { conn?.authenticated = false }
    }

    // MARK: Pairing actions (from RemoteControlView)
    func beginPair(with name: String) {
        conn.pairingError = nil
        if RemoteClientAuthStore.token(forHost: name) != nil {
            conn.needsCode = false; conn.pairingHost = nil
        } else {
            conn.pairingHost = name; conn.needsCode = true
        }
        conn.connect(to: name)
    }

    /// Manual 6-digit code entry.
    func submitCode(_ code: String) {
        conn.needsCode = false
        provideCode(code)
    }

    /// A scanned QR: select the encoded host and use its (high-entropy) code.
    func applyScannedPayload(_ payload: PeerPairingPayload) {
        conn.pairingError = nil
        conn.pairingHost = payload.hostName
        conn.needsCode = false
        conn.connect(to: payload.hostName)
        provideCode(payload.code)
    }
}
