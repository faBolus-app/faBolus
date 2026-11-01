import Foundation
import RemoteProtocol

/// What a transport reports. Authentication is the transport's own business: Connect IQ only delivers
/// messages from the selected watch's copy of the app, and an Apple Watch or Mac transport adds whatever it
/// needs before handing a message over.
public enum WatchTransportEvent: Sendable {
    case paired(Bool)
    case deviceStatus(WatchDeviceStatus)
    case characteristicsDiscovered
    case appStatus(installed: Bool?, probe: Int)
    case sendProgress(send: Int)
    case sendCompleted(send: Int, WatchSendResult)
    case received(WireValue)
    case receivedUnreadable

    var input: WatchLinkInput {
        switch self {
        case .paired(let p): return .paired(p)
        case .deviceStatus(let s): return .deviceStatus(s)
        case .characteristicsDiscovered: return .characteristicsDiscovered
        case .appStatus(let installed, let probe): return .appStatus(installed: installed, probe: probe)
        case .sendProgress(let send): return .sendProgress(send: send)
        case .sendCompleted(let send, let result): return .sendCompleted(send: send, result)
        case .received(let wire): return .received(wire)
        case .receivedUnreadable: return .receivedUnreadable
        }
    }
}

/// A way to reach a remote: converts between its SDK and the link's inputs and effects, and holds no state
/// of its own beyond the SDK's handles. Called on the main actor, where Connect IQ's iOS SDK expects to be.
@MainActor
public protocol WatchTransport: AnyObject {
    /// Begin reporting events. Called once; the transport reports `.paired` and the device's status first.
    func start(_ handler: @escaping @MainActor (WatchTransportEvent) -> Void)
    /// Send one message; report `.sendProgress` and exactly one `.sendCompleted` for `send` if the SDK
    /// gives one. A completion that never comes is the link's watchdog's job.
    func transmit(_ message: WireValue, send: Int)
    /// Ask whether the app is installed; report `.appStatus` with `probe`.
    func probeAppStatus(probe: Int)
    /// Rebuild the registration with the watch.
    func reregister()
}

@MainActor
public protocol WatchLinkClock: AnyObject {
    var now: LinkSeconds { get }
    func schedule(after seconds: LinkSeconds, _ action: @escaping @MainActor () -> Void) -> any WatchLinkTimer
}

@MainActor
public protocol WatchLinkTimer: AnyObject {
    func cancel()
}

/// The phone's link to the watch. It applies inputs one at a time through `WatchLinkReducer` (an input
/// that arrives while one is being applied waits its turn), performs the effects, and keeps one timer, for
/// the reducer's next deadline. It holds no link state of its own.
@MainActor
public final class WatchLink {
    public private(set) var state = WatchLinkState()
    /// What the watch asks of the host, in order. One consumer.
    public let hostRequests: AsyncStream<HostRequest>
    /// Called after every input, for diagnostics.
    public var onChange: ((WatchLinkState) -> Void)?

    private let transport: any WatchTransport
    private let clock: any WatchLinkClock
    private let configuration: WatchLinkConfiguration
    private let jitter: () -> Double
    private let hostContinuation: AsyncStream<HostRequest>.Continuation
    private var timer: (any WatchLinkTimer)?
    private var timerDeadline: LinkSeconds?
    private var inbox: [WatchLinkInput] = []
    private var applying = false
    private var started = false

    public init(
        transport: any WatchTransport, clock: any WatchLinkClock, configuration: WatchLinkConfiguration = .init(),
        jitter: @escaping () -> Double = { Double.random(in: 0...1) }
    ) {
        self.transport = transport
        self.clock = clock
        self.configuration = configuration
        self.jitter = jitter
        (hostRequests, hostContinuation) = AsyncStream.makeStream(of: HostRequest.self)
    }

    public func start() {
        guard !started else { return }
        started = true
        transport.start { [weak self] event in self?.submit(event.input) }
    }

    /// Hand the link an input. Host inputs (`setStatus`, `setConfig`, `setHistory`, `sendResult`,
    /// `appActive`) come through here too.
    public func submit(_ input: WatchLinkInput) {
        inbox.append(input)
        guard !applying else { return }
        applying = true
        defer { applying = false }
        while !inbox.isEmpty {
            let next = inbox.removeFirst()
            let effects = WatchLinkReducer.reduce(
                &state, next, now: clock.now, jitter: jitter(), configuration: configuration)
            for effect in effects { perform(effect) }
            rearm()
            onChange?(state)
        }
    }

    private func perform(_ effect: WatchLinkEffect) {
        switch effect {
        case .transmit(let send, let wire): transport.transmit(wire, send: send)
        case .probeAppStatus(let probe): transport.probeAppStatus(probe: probe)
        case .reregister: transport.reregister()
        case .host(let request): hostContinuation.yield(request)
        }
    }

    private func rearm() {
        let deadline = WatchLinkReducer.nextDeadline(state, configuration: configuration)
        guard deadline != timerDeadline else { return }
        timer?.cancel()
        timer = nil
        timerDeadline = deadline
        guard let deadline else { return }
        timer = clock.schedule(after: max(0, deadline - clock.now)) { [weak self] in
            guard let self else { return }
            self.timerDeadline = nil
            self.timer = nil
            self.submit(.tick)
        }
    }
}

/// The production clock: monotonic seconds and main-queue timers. Timers don't fire while the app is
/// suspended; the reducer catches up on the next input.
@MainActor
public final class SystemWatchLinkClock: WatchLinkClock {
    private final class Timer: WatchLinkTimer {
        var work: DispatchWorkItem?
        func cancel() { work?.cancel() }
    }

    public init() {}

    public var now: LinkSeconds { Double(DispatchTime.now().uptimeNanoseconds) / 1e9 }

    public func schedule(after seconds: LinkSeconds, _ action: @escaping @MainActor () -> Void) -> any WatchLinkTimer {
        let timer = Timer()
        let work = DispatchWorkItem { MainActor.assumeIsolated { action() } }
        timer.work = work
        DispatchQueue.main.asyncAfter(deadline: .now() + seconds, execute: work)
        return timer
    }
}
