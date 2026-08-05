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
    public var onUndeliverable: (@MainActor (RemoteCommand) -> Void)?

    private let session: WCSession?

    public override init() {
        session = WCSession.isSupported() ? WCSession.default : nil
        super.init()
        session?.delegate = self
        session?.activate()
    }

    public var isReachable: Bool { session?.isReachable ?? false }

    /// Sends a command.
    ///
    /// **A pump-mutating command is never queued.** `transferUserInfo` is a guaranteed, FIFO,
    /// opportunistic-latency queue: iOS will deliver it eventually, which for a bolus means it can
    /// land minutes after the user gave up and dosed another way. That is a double-dose hazard, and a
    /// late `cancelBolus`/`resumePump` is the same class of problem. So for those kinds we use live
    /// messaging only and report failure through `onUndeliverable`; the caller surfaces "not sent"
    /// rather than sitting on "Delivering…" waiting for an echo that will never arrive.
    ///
    /// Non-mutating traffic (status reads, outcome echoes, advisory eating events) still queues, so a
    /// watch that was out of range catches up instead of silently losing state.
    public func send(_ command: RemoteCommand) {
        guard let data = try? command.encoded() else { return }
        guard let session else { reportUndeliverable(command); return }
        switch RemoteSendDisposition.decide(kind: command.kind, isReachable: session.isReachable) {
        case .sendLive:
            session.sendMessageData(data, replyHandler: nil, errorHandler: { [weak self] _ in
                guard let self else { return }
                // A live send that errored: same rule, now with `liveSendFailed`.
                switch RemoteSendDisposition.decide(kind: command.kind, isReachable: false,
                                                   liveSendFailed: true) {
                case .queue: self.transfer(data)
                case .reportUndeliverable: self.reportUndeliverable(command)
                case .sendLive: break   // unreachable by construction
                }
            })
        case .queue:
            transfer(data)
        case .reportUndeliverable:
            reportUndeliverable(command)
        }
    }

    private func transfer(_ data: Data) { session?.transferUserInfo(["cmd": data]) }

    private func reportUndeliverable(_ command: RemoteCommand) {
        Task { @MainActor in self.onUndeliverable?(command) }
    }

    private func dispatch(_ data: Data) {
        guard let cmd = try? RemoteCommand.decodeValidated(data) else { return }   // audit A-07
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
