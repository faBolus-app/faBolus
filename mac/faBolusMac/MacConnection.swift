import Foundation
import faBolusCore

/// Discovery + pairing state for the Mac's Settings → Connection screen. Lists the iPhones the
/// `BLELink` central has found, remembers the one the user pairs with (persisted), and reconnects to
/// it automatically on launch. Kept separate from `RemoteClientModel` so its state is observed by
/// SwiftUI. The BLE link being *connected* is not enough to use the phone — the phone requires an
/// authenticated pairing (`MacPairing`), so this also carries the auth-facing UI state that
/// `MacRemoteModel` drives during the handshake.
@MainActor
@Observable
final class MacConnection {
    /// Display names of iPhones currently advertising the faBolus remote service.
    var discoveredPhones: [String] = []
    /// The paired iPhone's name (persisted), or nil if none chosen yet.
    var pairedPhone: String?
    /// Whether the BLE link to the paired iPhone is up (transport-level).
    var connected: Bool = false

    // Auth-facing state (set by MacRemoteModel's handshake).
    /// Whether the connected iPhone has authenticated this Mac (allowed to control it).
    var authenticated: Bool = false
    /// True while we're pairing a new iPhone and need the user to enter its one-time code.
    var needsCode: Bool = false
    /// The iPhone currently being paired (awaiting a code), for the prompt.
    var pairingPhone: String?
    /// A human-readable pairing failure ("Incorrect code", …), or nil.
    var pairingError: String?

    @ObservationIgnored let peer: BLELink
    @ObservationIgnored private let defaultsKey = "pairedPhone"

    init(peer: BLELink) {
        self.peer = peer
        pairedPhone = UserDefaults.standard.string(forKey: defaultsKey)
        connected = peer.isReachable
        peer.onPeersChanged = { [weak self] names in self?.discoveredPhones = names.sorted() }
        if let paired = pairedPhone { peer.setPreferredPeer(paired) }   // auto-reconnect (token handshake)
    }

    /// Remember + connect to an iPhone (the handshake runs once the link is up).
    func connect(to name: String) {
        pairedPhone = name
        UserDefaults.standard.set(name, forKey: defaultsKey)
        peer.setPreferredPeer(name)
    }

    /// Forget the paired iPhone: drop its token, disconnect, and clear all pairing state.
    func forget() {
        if let name = pairedPhone { MacAuthStore.forget(phone: name) }
        pairedPhone = nil
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        peer.setPreferredPeer(nil)
        peer.disconnectAll()
        connected = false
        authenticated = false
        needsCode = false
        pairingPhone = nil
        pairingError = nil
    }
}
