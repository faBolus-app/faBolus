import Foundation
import RemoteProtocol

/// One thing waiting to go to the watch. Status, config and history each hold one slot whose content is
/// always the newest, so a status sent in reply to a poll and one pushed on a change are the same message
/// and coalescing them loses nothing. Outcomes and dismiss results are kept per request.
public enum OutboxItem: Sendable, Hashable {
    case outcome(requestId: String)
    case dismissResult(requestId: String)
    case legacyReply(Int)
    case incompatible
    case config
    case status
    case history
}

/// The link's whole state. `WatchLinkReducer` is the only thing that changes it.
public struct WatchLinkState: Sendable {
    public struct InFlight: Sendable, Hashable {
        public var send: Int
        public var item: OutboxItem
        /// The content version that went out; a newer one set meanwhile is still due afterwards.
        public var version: Int
        public var startedAt: LinkSeconds
        public var lastProgressAt: LinkSeconds
    }

    struct Pending: Sendable {
        var message: RemoteMessage?
        var legacy: WireValue?
        var version: Int
        var attempts = 0
    }

    public private(set) var phase: WatchLinkPhase = .notPaired

    public internal(set) var paired = false
    public internal(set) var device: WatchDeviceStatus = .unknown
    /// The transport finished setting up, a probe found the app, or a message arrived: the watch can
    /// take messages while it stays connected.
    public internal(set) var shownReady = false
    /// `false` once the watch says the app isn't installed; `nil` when unknown.
    public internal(set) var appInstalled: Bool?
    /// The last message from the watch was version 1: it runs the old app, which can't read the config,
    /// status or history, so only the replies to its messages go to it until a version 2 message arrives.
    public internal(set) var peerIsLegacy = false

    public internal(set) var config: WatchConfig?
    public internal(set) var status: StatusPayload?
    public internal(set) var history: HistoryPayload?

    var due: [OutboxItem: Pending] = [:]
    /// Outcomes and dismiss results in the order they were first queued, so one request's outcome isn't
    /// sent before an earlier one's.
    var resultOrder: [OutboxItem] = []
    var legacyOrder: [Int] = []
    var nextLegacy = 0
    var contentVersion = 0

    public internal(set) var inFlight: InFlight?
    var nextSend = 1
    public internal(set) var backoffUntil: LinkSeconds?
    var backoffLevel = 0
    var stallStreak = 0
    var lastReregisterAt: LinkSeconds?

    var probe = 0
    var probeOutstanding = false
    /// When the next probe goes out, or the outstanding one is given up on. `nil`: as soon as one is wanted.
    var nextProbeAt: LinkSeconds?
    /// A reconnect or a return to the foreground asked for a probe, even of a watch shown not to have the
    /// app.
    var probeRequested = false
    var probesWithoutAnswer = 0

    public internal(set) var telemetry = WatchLinkTelemetry()

    public init() {}

    /// The watch can take a message now.
    public var isReady: Bool { paired && device == .connected && shownReady && appInstalled != false }

    /// What is waiting to be sent, for diagnostics.
    public var queued: [OutboxItem] { WatchLinkReducer.order(self) }

    mutating func derivePhase(now: LinkSeconds, reason: String, limit: Int) {
        let next: WatchLinkPhase
        if !paired {
            next = .notPaired
        } else if appInstalled == false {
            next = .appNotInstalled
        } else if !isReady {
            next = .unreachable
        } else if inFlight != nil {
            next = .awaitingReply
        } else if backoffUntil != nil {
            next = .backingOff
        } else {
            next = .reachable
        }
        guard next != phase else { return }
        telemetry.transitions.append(.init(at: now, from: phase, to: next, reason: reason))
        if telemetry.transitions.count > limit {
            telemetry.transitions.removeFirst(telemetry.transitions.count - limit)
        }
        phase = next
    }
}
