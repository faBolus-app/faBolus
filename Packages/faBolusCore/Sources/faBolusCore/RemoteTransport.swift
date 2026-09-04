import Foundation

/// Transport a remote client (Mac or another iPhone) uses to talk to the host. `BLELink` conforms.
/// One `RemoteClientModel` works over any conforming link.
///
/// To add a transport: conform (send/receive encoded `RemoteCommand`s); wrap in `SealedTransport`
/// if the medium is not already encrypted.
public protocol RemoteTransport: AnyObject {
    /// Invoked (on the main actor) with each decoded command received from the peer.
    var onReceive: (@MainActor (RemoteCommand) -> Void)? { get set }
    /// Invoked (on the main actor) when the peer becomes reachable/unreachable.
    var onReachabilityChange: (@MainActor (Bool) -> Void)? { get set }
    /// Whether a peer is currently connected/reachable.
    var isReachable: Bool { get }
    /// Invoked (on the main actor) when a command could **not** be handed to the peer. Only
    /// pump-mutating commands (`RemoteCommand.Kind.mutatesPumpState`) report this: they are never
    /// queued, so the caller must be told rather than left waiting for an echo that will not come.
    var onUndeliverable: (@MainActor (RemoteCommand) -> Void)? { get set }
    /// Encode + send a command to the peer.
    ///
    /// A non-pump-mutating command (status reads, echoes, advisory events) MAY be queued and flushed
    /// on reconnect. A **pump-mutating** command must be sent live or reported via
    /// `onUndeliverable` — never deferred. See `RemoteCommand.Kind.mutatesPumpState`.
    func send(_ command: RemoteCommand)
}
