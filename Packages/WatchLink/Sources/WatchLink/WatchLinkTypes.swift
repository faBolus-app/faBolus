import Foundation
import RemoteProtocol

/// Seconds on a monotonic clock. Wall-clock changes don't move the link's timers.
public typealias LinkSeconds = Double

/// Where the phone's link to the watch stands. Derived from the facts in `WatchLinkState`, never set
/// directly, so it can't disagree with them.
public enum WatchLinkPhase: String, Sendable, Hashable, CaseIterable {
    /// No watch is selected.
    case notPaired
    /// The watch says the faBolus app isn't on it.
    case appNotInstalled
    /// A watch is selected but can't take a message now: out of range, Bluetooth off, or not yet shown to
    /// be ready.
    case unreachable
    /// Ready, nothing in flight.
    case reachable
    /// A message has gone to the transport and its completion hasn't arrived.
    case awaitingReply
    /// A send failed or stalled; the next one waits.
    case backingOff
}

/// What the transport says about the selected watch.
public enum WatchDeviceStatus: String, Sendable, Hashable {
    case unknown
    case connected
    case notConnected
    case bluetoothOff
    case notFound
    case invalid
}

/// How a send ended, as the transport reports it. Connect IQ's results map onto these.
public enum WatchSendResult: Sendable, Hashable {
    case delivered
    /// Worth trying again later: the watch was busy or away, or the transfer timed out.
    case transientFailure(String)
    /// The watch app isn't installed. Nothing more is sent until it is.
    case appNotFound
    /// This message can never be delivered (too large, or a type the watch can't take). It is dropped.
    case undeliverable(String)
}

/// Everything the link reacts to.
public enum WatchLinkInput: Sendable {
    case paired(Bool)
    case deviceStatus(WatchDeviceStatus)
    /// The transport has finished setting up with the watch; it can take messages.
    case characteristicsDiscovered
    /// The answer to a probe: is the app installed? `nil` when the transport couldn't tell.
    case appStatus(installed: Bool?, probe: Int)
    case sendProgress(send: Int)
    case sendCompleted(send: Int, WatchSendResult)
    /// A message from the watch, as the transport received it.
    case received(WireValue)
    /// The watch sent something that isn't a message at all.
    case receivedUnreadable
    case appActive(Bool)
    // What the host wants the watch to have.
    case setConfig(WatchConfig)
    case setStatus(StatusPayload)
    case setHistory(HistoryPayload)
    /// A bolus outcome or a dismiss result for one request. A newer one for the same request replaces one
    /// not yet sent.
    case sendResult(RemoteMessage)
    case tick
}

/// What the host is asked to do because of a message from the watch.
public enum HostRequest: Sendable, Hashable {
    case bolus(BolusRequestPayload)
    case cancel(CancelPayload)
    case dismiss(DismissPayload)
    /// The watch is waiting on this request's outcome; send it again.
    case outcome(requestId: String)
    case history
    case refreshGlucose
    /// A bolus request that couldn't be read. Nothing is done with it but answer it as failed.
    case unreadableBolus(requestId: String)
}

public enum WatchLinkEffect: Sendable, Hashable {
    case transmit(send: Int, WireValue)
    case probeAppStatus(probe: Int)
    /// Rebuild the transport's registration with the watch, as re-selecting the watch by hand would.
    case reregister
    case host(HostRequest)
}

public struct WatchLinkConfiguration: Sendable {
    /// A send with no progress for this long is treated as stalled.
    public var noProgressTimeout: LinkSeconds = 8
    /// A send still going after this long is treated as stalled, however it trickles.
    public var hardCeiling: LinkSeconds = 60
    /// Tries per message before it's dropped. A dropped message is resent when the watch next asks (its
    /// poll names its config revision and the request it's waiting on) or when the content changes.
    public var maxAttempts = 3
    /// Waits after consecutive failures; the last repeats.
    public var backoff: [LinkSeconds] = [2, 4, 8, 16, 30]
    /// Fraction of a backoff added at random, so a phone and a watch don't retry in step.
    public var backoffJitter = 0.5
    /// Stalls in a row (no completion at all) before the registration is rebuilt.
    public var stallsBeforeReregister = 3
    public var minReregisterInterval: LinkSeconds = 30
    /// A stalled send counts as still with the SDK for this long after its last sign of life (the hand-over
    /// or its last progress), and the next send waits for it: one handed over on top of it would queue
    /// behind it, so each stall would add to the pile. One stranded by a suspension is past this when the
    /// app resumes, and holds nothing.
    public var stalledSendHold: LinkSeconds = 40
    /// Stalled sends kept for their late completion, newest last.
    public var maxStalledKept = 8
    /// Waits between probes while the watch is connected but not shown ready; the last repeats.
    public var probeIntervals: [LinkSeconds] = [20, 60]
    public var maxQueuedResults = 16
    public var maxQueuedLegacyReplies = 4
    public var transitionLogLimit = 50
    public init() {}
}

/// Counts and recent transitions, for the diagnostics export.
public struct WatchLinkTelemetry: Sendable, Hashable {
    public struct Transition: Sendable, Hashable {
        public var at: LinkSeconds
        public var from: WatchLinkPhase
        public var to: WatchLinkPhase
        public var reason: String
    }
    public var transmits = 0
    public var delivered = 0
    public var transientFailures = 0
    public var undeliverable = 0
    public var appNotFound = 0
    public var stalls = 0
    /// Completions that arrived after their send was given up on: the transport was slower than the
    /// watchdog, not dead.
    public var lateCompletions = 0
    /// Late completions that said delivered: the message got there after all and isn't sent again.
    public var lateDeliveries = 0
    public var reregistrations = 0
    public var probes = 0
    /// Messages dropped after `maxAttempts`, or pushed out of a full queue.
    public var dropped = 0
    public var received = 0
    public var receivedLegacy = 0
    public var receivedOtherVersion = 0
    public var receivedMalformed = 0
    public var receivedUnexpected = 0
    public var lastFailure: String?
    public var lastReceivedAt: LinkSeconds?
    public var lastDeliveredAt: LinkSeconds?
    public var transitions: [Transition] = []
    public init() {}
}
