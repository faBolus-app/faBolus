import Foundation
import faBolusCore

/// Discovery + pairing state for the Mac's Settings → Connection screen. Lists the iPhones the
/// `PeerLink` browser has found, remembers the one the user pairs with (persisted), and reconnects
/// to it automatically on launch. Kept separate from `RemoteClientModel` so its state is observed by
/// SwiftUI (the model's transport callbacks own reachability; this owns only peer discovery).
@MainActor
@Observable
final class MacConnection {
    /// Display names of iPhones currently advertising the faBolus remote service.
    var discoveredPhones: [String] = []
    /// The paired iPhone's name (persisted), or nil if none chosen yet.
    var pairedPhone: String?
    /// Whether the paired iPhone is currently connected. Driven by `MacRemoteModel.reachabilityDidChange`.
    var connected: Bool = false

    @ObservationIgnored private let peer: PeerLink
    @ObservationIgnored private let defaultsKey = "pairedPhone"

    init(peer: PeerLink) {
        self.peer = peer
        pairedPhone = UserDefaults.standard.string(forKey: defaultsKey)
        connected = peer.isReachable
        peer.onPeersChanged = { [weak self] names in self?.discoveredPhones = names.sorted() }
        if let paired = pairedPhone { peer.setPreferredPeer(paired) }   // auto-reconnect
    }

    /// Pair with a discovered iPhone: remember it and connect.
    func pair(with name: String) {
        pairedPhone = name
        UserDefaults.standard.set(name, forKey: defaultsKey)
        peer.setPreferredPeer(name)
    }

    /// Forget the paired iPhone and disconnect.
    func forget() {
        pairedPhone = nil
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        peer.setPreferredPeer(nil)
        peer.disconnectAll()
        connected = false
    }
}
