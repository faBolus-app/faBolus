import Foundation

/// The transport-agnostic surface a remote client (Apple Watch, Mac) drives to talk to the iPhone
/// host. `RemoteLink` (WatchConnectivity) and `PeerLink` (MultipeerConnectivity) both conform, so a
/// single `RemoteClientModel` works over either link without knowing which one it holds.
public protocol RemoteTransport: AnyObject {
    /// Invoked (on the main actor) with each decoded command received from the peer.
    var onReceive: (@MainActor (RemoteCommand) -> Void)? { get set }
    /// Invoked (on the main actor) when the peer becomes reachable/unreachable.
    var onReachabilityChange: (@MainActor (Bool) -> Void)? { get set }
    /// Whether a peer is currently connected/reachable.
    var isReachable: Bool { get }
    /// Encode + send a command to the peer (queued and flushed on reconnect if none is connected).
    func send(_ command: RemoteCommand)
}
