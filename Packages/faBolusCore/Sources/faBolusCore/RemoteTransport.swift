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

/// What a transport should do with one outbound command. Isolated so the live-vs-queue rule is
/// testable without a concrete transport.
public enum RemoteSendDisposition: Equatable, Sendable {
    /// Hand to the peer now (a live BLE write).
    case sendLive
    /// Park it for opportunistic delivery on reconnect. Only ever correct for commands that do not
    /// touch the pump.
    case queue
    /// Do not send, and tell the caller. The only safe outcome for a pump-mutating command with no
    /// live link — nothing was sent, so there is nothing to reconcile.
    case reportUndeliverable

    /// - Parameters:
    ///   - kind: the command being sent.
    ///   - isReachable: whether the peer is live right now.
    ///   - liveSendFailed: pass `true` when a live send was already attempted and errored, to decide
    ///     the fallback. A non-mutating command falls back to the queue; a mutating one must not.
    public static func decide(
        kind: RemoteCommand.Kind,
        isReachable: Bool,
        liveSendFailed: Bool = false
    ) -> RemoteSendDisposition {
        if liveSendFailed { return kind.mutatesPumpState ? .reportUndeliverable : .queue }
        if isReachable { return .sendLive }
        return kind.mutatesPumpState ? .reportUndeliverable : .queue
    }
}
