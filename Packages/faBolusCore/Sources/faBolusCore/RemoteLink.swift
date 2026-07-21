import Foundation
#if canImport(WatchConnectivity)
import WatchConnectivity

/// Thin WatchConnectivity wrapper shared by the iOS host and the watchOS remote. Sends/receives
/// `RemoteCommand`s as JSON `Data` (Sendable). Delivers received commands on the main actor.
///
/// `@unchecked Sendable`: WCSession's send/transfer calls are thread-safe, and the callbacks
/// are set once at init and always re-dispatched to the main actor before use.
public final class RemoteLink: NSObject, WCSessionDelegate, RemoteTransport, @unchecked Sendable {
    public var onReceive: (@MainActor (RemoteCommand) -> Void)?
    public var onReachabilityChange: (@MainActor (Bool) -> Void)?

    private let session: WCSession?

    public override init() {
        session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
        session?.delegate = self
        session?.activate()
    }

    public var isReachable: Bool { session?.isReachable ?? false }

    /// Sends a command. Uses live messaging when reachable, else queues via transferUserInfo so
    /// nothing is silently dropped (phone-out-of-range = deferred, not lost).
    public func send(_ command: RemoteCommand) {
        guard let session, let data = try? command.encoded() else { return }
        if session.isReachable {
            session.sendMessageData(data, replyHandler: nil, errorHandler: { [weak self] _ in
                self?.transfer(data)
            })
        } else {
            transfer(data)
        }
    }

    private func transfer(_ data: Data) { session?.transferUserInfo(["cmd": data]) }

    private func dispatch(_ data: Data) {
        guard let cmd = try? RemoteCommand.decode(data) else { return }
        Task { @MainActor in self.onReceive?(cmd) }
    }

    // MARK: WCSessionDelegate
    public func session(_ s: WCSession, didReceiveMessageData data: Data) { dispatch(data) }
    public func session(_ s: WCSession, didReceiveUserInfo userInfo: [String: Any]) {
        if let data = userInfo["cmd"] as? Data { dispatch(data) }
    }
    public func sessionReachabilityDidChange(_ s: WCSession) {
        let r = s.isReachable
        Task { @MainActor in self.onReachabilityChange?(r) }
    }
    public func session(_ s: WCSession, activationDidCompleteWith state: WCSessionActivationState, error: Error?) {}
    #if os(iOS)
    public func sessionDidBecomeInactive(_ s: WCSession) {}
    public func sessionDidDeactivate(_ s: WCSession) { s.activate() }
    #endif
}
#endif
