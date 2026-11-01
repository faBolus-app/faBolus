import Foundation
import RemoteProtocol
import Testing

@testable import WatchLink

/// Drives the reducer directly, with time moved by hand.
struct Harness {
    var state = WatchLinkState()
    var now: LinkSeconds = 1000
    var configuration = WatchLinkConfiguration()
    var effects: [WatchLinkEffect] = []

    @discardableResult
    mutating func send(_ input: WatchLinkInput) -> [WatchLinkEffect] {
        let out = WatchLinkReducer.reduce(&state, input, now: now, jitter: 0, configuration: configuration)
        effects += out
        // No reduction may leave a deadline that's already due: the driver would tick again at once.
        if let deadline = WatchLinkReducer.nextDeadline(state, configuration: configuration) {
            #expect(deadline > now, "a deadline at or before now would loop")
        }
        return out
    }

    /// Moves time on and delivers the tick the driver would.
    @discardableResult
    mutating func advance(_ seconds: LinkSeconds) -> [WatchLinkEffect] {
        var out: [WatchLinkEffect] = []
        let end = now + seconds
        while let deadline = WatchLinkReducer.nextDeadline(state, configuration: configuration), deadline <= end {
            now = max(now, deadline)
            out += send(.tick)
        }
        now = end
        return out
    }

    /// A watch that is paired, connected and ready, with a config and a status set and both delivered.
    static func ready() -> Harness {
        var h = Harness()
        h.send(.setConfig(Fixture.config))
        h.send(.setStatus(Fixture.status()))
        h.send(.paired(true))
        h.send(.deviceStatus(.connected))
        h.send(.characteristicsDiscovered)
        h.deliverAll()
        h.effects = []
        return h
    }

    /// The send in flight, if any.
    var inFlight: Int? { state.inFlight?.send }

    /// Completes every send as delivered until nothing is left.
    mutating func deliverAll(limit: Int = 50) {
        var n = 0
        while let send = inFlight, n < limit {
            self.send(.sendCompleted(send: send, .delivered))
            n += 1
        }
    }

    var transmitted: [WireValue] {
        effects.compactMap { if case .transmit(_, let w) = $0 { return w } else { return nil } }
    }

    var transmittedKinds: [String] {
        transmitted.map { wire in
            guard case .object(let o) = wire, case .string(let k)? = o["kind"] else { return "?" }
            return k
        }
    }

    var hostRequests: [HostRequest] {
        effects.compactMap { if case .host(let r) = $0 { return r } else { return nil } }
    }

    var probes: Int { effects.filter { if case .probeAppStatus = $0 { return true } else { return false } }.count }
}

enum Fixture {
    static let config = GoldenFixtures.config

    static func status(_ sentAt: Int = GoldenFixtures.now) -> StatusPayload {
        var s = GoldenFixtures.status
        s.sentAt = sentAt
        return s
    }

    static func outcome(_ id: String, _ outcome: OutcomeToken) -> RemoteMessage {
        .bolusOutcome(
            BolusOutcomePayload(
                requestId: id, outcome: outcome, requestedMilliunits: 1000, deliveredMilliunits: nil, message: nil,
                sentAt: GoldenFixtures.now))
    }

    static func poll(revision: String?, awaiting: String? = nil, history: Bool = false) -> WireValue {
        RemoteMessage.poll(
            PollPayload(
                configRevision: revision, awaitingRequestId: awaiting, wantsHistory: history, freshGlucose: false,
                appVersion: "0.1.0")
        ).wire
    }
}

/// A clock moved by hand. While `suspended`, nothing fires, as on iOS; timers that came due fire on resume.
@MainActor
final class ManualClock: WatchLinkClock {
    final class Timer: WatchLinkTimer {
        var cancelled = false
        func cancel() { cancelled = true }
    }

    private(set) var now: LinkSeconds = 1000
    var suspended = false
    private var scheduled: [(due: LinkSeconds, timer: Timer, action: @MainActor () -> Void)] = []

    func schedule(after seconds: LinkSeconds, _ action: @escaping @MainActor () -> Void) -> any WatchLinkTimer {
        let timer = Timer()
        scheduled.append((now + seconds, timer, action))
        return timer
    }

    var pending: Int { scheduled.filter { !$0.timer.cancelled }.count }

    func advance(_ seconds: LinkSeconds) {
        let end = now + seconds
        var fired = 0
        while !suspended,
            let next = scheduled.enumerated().filter({ !$0.element.timer.cancelled && $0.element.due <= end })
                .min(by: { $0.element.due < $1.element.due })
        {
            scheduled.remove(at: next.offset)
            now = max(now, next.element.due)
            next.element.action()
            fired += 1
            precondition(fired < 10_000, "timers fired without end")
        }
        now = end
        scheduled.removeAll { $0.timer.cancelled }
    }

    func resume() {
        suspended = false
        advance(0)
    }
}

/// Records what the link asks of it; the test plays the watch's and the SDK's part.
@MainActor
final class FakeTransport: WatchTransport {
    var handler: (@MainActor (WatchTransportEvent) -> Void)?
    var sent: [(send: Int, wire: WireValue)] = []
    var probes: [Int] = []
    var reregistrations = 0
    /// Answer each send at once, inside `transmit`, as a synchronous SDK might.
    var completeImmediately: WatchSendResult?

    func start(_ handler: @escaping @MainActor (WatchTransportEvent) -> Void) { self.handler = handler }

    func transmit(_ message: WireValue, send: Int) {
        sent.append((send, message))
        if let result = completeImmediately { handler?(.sendCompleted(send: send, result)) }
    }

    func probeAppStatus(probe: Int) { probes.append(probe) }
    func reregister() { reregistrations += 1 }

    func emit(_ event: WatchTransportEvent) { handler?(event) }

    var kinds: [String] {
        sent.map { s in
            guard case .object(let o) = s.wire, case .string(let k)? = o["kind"] else { return "?" }
            return k
        }
    }
}
