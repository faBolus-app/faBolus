import Foundation
#if canImport(MultipeerConnectivity)
import MultipeerConnectivity

/// Same-network transport for the phone↔Mac remote link, mirroring `RemoteLink`'s surface but
/// carried over MultipeerConnectivity (Wi-Fi / peer-to-peer) since WatchConnectivity can't reach a
/// Mac. Sends/receives `RemoteCommand`s as JSON `Data`; delivers received commands on the main actor.
///
/// One side advertises (the iPhone host), the other browses (the Mac remote); both use the same
/// service type and an encrypted session. Commands sent with no connected peer are queued and
/// flushed on connect, so nothing is silently dropped (parallels RemoteLink's transferUserInfo
/// fallback).
///
/// `@unchecked Sendable`: all mutable transport state is confined to `queue`; the MultipeerConnectivity
/// delegate callbacks are re-dispatched to the main actor before touching `onReceive` /
/// `onReachabilityChange` (set once at init, like RemoteLink).
public final class PeerLink: NSObject, RemoteTransport, @unchecked Sendable {
    /// Which half of the discovery handshake this end plays: the iPhone host advertises, the Mac
    /// remote browses and invites.
    public enum Role: Sendable { case advertiser, browser }

    public var onReceive: (@MainActor (RemoteCommand) -> Void)?
    public var onReachabilityChange: (@MainActor (Bool) -> Void)?
    /// Invoked (on the main actor) with the current set of discovered peer names — the browser (Mac)
    /// side of pairing, so the UI can list iPhones to pair with.
    public var onPeersChanged: (@MainActor ([String]) -> Void)?

    /// Service type: 1–15 chars, lowercase letters/digits/hyphens (Bonjour rules). Shared by both ends.
    public static let defaultServiceType = "fabolus-rmt"

    private let session: MCSession
    private var advertiser: MCNearbyServiceAdvertiser?
    private var browser: MCNearbyServiceBrowser?

    /// Serializes access to `session.send`, the pending queue, and the discovery/pairing state.
    private let queue = DispatchQueue(label: "com.fabolus.peerlink")
    private var pending: [Data] = []
    /// Discovered advertisers by display name (browser role). Only the `preferredPeerName` is invited.
    private var foundPeers: [String: MCPeerID] = [:]
    /// The paired peer to auto-connect to; nil until the user pairs one from the UI.
    private var preferredPeerName: String?

    public init(role: Role, serviceType: String = PeerLink.defaultServiceType,
                displayName: String = PeerLink.defaultDisplayName()) {
        let peerID = MCPeerID(displayName: displayName)
        session = MCSession(peer: peerID, securityIdentity: nil, encryptionPreference: .required)
        super.init()
        session.delegate = self
        switch role {
        case .advertiser:
            let adv = MCNearbyServiceAdvertiser(peer: peerID, discoveryInfo: nil, serviceType: serviceType)
            adv.delegate = self
            advertiser = adv
            adv.startAdvertisingPeer()
        case .browser:
            let br = MCNearbyServiceBrowser(peer: peerID, serviceType: serviceType)
            br.delegate = self
            browser = br
            br.startBrowsingForPeers()
        }
    }

    deinit {
        advertiser?.stopAdvertisingPeer()
        browser?.stopBrowsingForPeers()
        session.disconnect()
    }

    /// A stable, human-readable peer name (host name, clamped to MultipeerConnectivity's 63-byte cap).
    public static func defaultDisplayName() -> String {
        let raw = ProcessInfo.processInfo.hostName
        return raw.isEmpty ? "faBolus" : String(raw.prefix(63))
    }

    public var isReachable: Bool { !session.connectedPeers.isEmpty }

    /// The display name of the currently connected peer, if any (for status UI).
    public var connectedPeerName: String? { session.connectedPeers.first?.displayName }

    // MARK: Pairing (browser / Mac side)

    /// Choose the peer to connect to. Persisted by the caller; passing the remembered name on launch
    /// auto-connects. Invites the peer immediately if it's already been discovered. `nil` clears it.
    public func setPreferredPeer(_ name: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.preferredPeerName = name
            if let name, let peerID = self.foundPeers[name] {
                self.browser?.invitePeer(peerID, to: self.session, withContext: nil, timeout: 30)
            }
        }
    }

    /// Drop the current connection (used by "Forget this iPhone").
    public func disconnectAll() {
        session.disconnect()
    }

    /// Send a command reliably to all connected peers; if none are connected yet it's queued and
    /// flushed on the next connect, so commands aren't dropped when briefly out of range.
    public func send(_ command: RemoteCommand) {
        guard let data = try? command.encoded() else { return }
        queue.async { [weak self] in
            guard let self else { return }
            let peers = self.session.connectedPeers
            if peers.isEmpty {
                self.pending.append(data)
            } else {
                try? self.session.send(data, toPeers: peers, with: .reliable)
            }
        }
    }

    private func flushPending() {
        queue.async { [weak self] in
            guard let self else { return }
            let peers = self.session.connectedPeers
            guard !peers.isEmpty, !self.pending.isEmpty else { return }
            for data in self.pending { try? self.session.send(data, toPeers: peers, with: .reliable) }
            self.pending.removeAll()
        }
    }

    private func dispatch(_ data: Data) {
        guard let cmd = try? RemoteCommand.decode(data) else { return }
        Task { @MainActor in self.onReceive?(cmd) }
    }
}

// MARK: - MCSessionDelegate
extension PeerLink: MCSessionDelegate {
    public func session(_ session: MCSession, peer peerID: MCPeerID, didChange state: MCSessionState) {
        let reachable = !session.connectedPeers.isEmpty
        if state == .connected { flushPending() }
        Task { @MainActor in self.onReachabilityChange?(reachable) }
    }
    public func session(_ session: MCSession, didReceive data: Data, fromPeer peerID: MCPeerID) {
        dispatch(data)
    }
    public func session(_ s: MCSession, didReceive stream: InputStream, withName streamName: String, fromPeer peerID: MCPeerID) {}
    public func session(_ s: MCSession, didStartReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, with progress: Progress) {}
    public func session(_ s: MCSession, didFinishReceivingResourceWithName resourceName: String, fromPeer peerID: MCPeerID, at localURL: URL?, withError error: Error?) {}
}

// MARK: - Advertiser (iPhone host) — accept the Mac's invitation into the encrypted session.
extension PeerLink: MCNearbyServiceAdvertiserDelegate {
    public func advertiser(_ advertiser: MCNearbyServiceAdvertiser, didReceiveInvitationFromPeer peerID: MCPeerID,
                           withContext context: Data?, invitationHandler: @escaping (Bool, MCSession?) -> Void) {
        // Single-user personal app: accept and join the encrypted session.
        invitationHandler(true, session)
    }
}

// MARK: - Browser (Mac remote) — discover advertising hosts; invite only the paired one.
extension PeerLink: MCNearbyServiceBrowserDelegate {
    public func browser(_ browser: MCNearbyServiceBrowser, foundPeer peerID: MCPeerID,
                        withDiscoveryInfo info: [String: String]?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.foundPeers[peerID.displayName] = peerID
            if peerID.displayName == self.preferredPeerName {
                browser.invitePeer(peerID, to: self.session, withContext: nil, timeout: 30)
            }
            let names = Array(self.foundPeers.keys)
            Task { @MainActor in self.onPeersChanged?(names) }
        }
    }
    public func browser(_ browser: MCNearbyServiceBrowser, lostPeer peerID: MCPeerID) {
        queue.async { [weak self] in
            guard let self else { return }
            self.foundPeers[peerID.displayName] = nil
            let names = Array(self.foundPeers.keys)
            Task { @MainActor in self.onPeersChanged?(names) }
        }
    }
}
#endif
