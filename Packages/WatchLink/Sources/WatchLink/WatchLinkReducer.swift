import Foundation
import RemoteProtocol

/// The phone's link to the watch as a pure function: state and an input in, the new state and effects out.
/// All link state lives in `WatchLinkState`; the driver only performs effects and keeps the one timer the
/// next deadline asks for.
///
/// Every retry is bounded. A message gets `maxAttempts` tries with growing waits between them and is then
/// dropped; whatever the watch still needs it asks for again, because its poll names its config revision and
/// the bolus request it's waiting on. So nothing is retried forever and nothing waits behind a message that
/// can't be delivered.
public enum WatchLinkReducer {
    public static func reduce(
        _ state: inout WatchLinkState, _ input: WatchLinkInput, now: LinkSeconds, jitter: Double = 0,
        configuration: WatchLinkConfiguration = .init()
    ) -> [WatchLinkEffect] {
        var step = Step(configuration: configuration, now: now, jitter: jitter)
        let wasReady = state.isReady
        // A completion or progress report for the send in flight is evidence about that send, so it's applied
        // before any overdue watchdog: after a suspension both arrive together, and the send did complete.
        if case .sendCompleted(let send, _) = input, send == state.inFlight?.send {
            step.apply(input, to: &state)
            step.catchUp(&state)
        } else if case .sendProgress(let send) = input, send == state.inFlight?.send {
            step.apply(input, to: &state)
            step.catchUp(&state)
        } else {
            step.catchUp(&state)
            step.apply(input, to: &state)
        }
        if !wasReady && state.isReady { step.becameReady(&state) }
        step.probeIfDue(&state)
        step.pump(&state)
        state.derivePhase(
            now: now, reason: step.reason ?? Self.describe(input), limit: configuration.transitionLogLimit)
        return step.effects
    }

    /// When the link next needs a `.tick`, if ever.
    public static func nextDeadline(_ state: WatchLinkState, configuration: WatchLinkConfiguration = .init())
        -> LinkSeconds?
    {
        var deadlines: [LinkSeconds] = []
        if let f = state.inFlight {
            deadlines.append(
                min(f.lastProgressAt + configuration.noProgressTimeout, f.startedAt + configuration.hardCeiling))
        }
        if let until = state.backoffUntil { deadlines.append(until) }
        if let at = probeTime(state, configuration: configuration) { deadlines.append(at) }
        return deadlines.min()
    }

    /// The items waiting, in the order they'll be sent: results first (a bolus outcome mustn't wait behind a
    /// status), then replies to other versions, then config before the status that names its revision.
    static func order(_ state: WatchLinkState) -> [OutboxItem] {
        var items = state.resultOrder
        items += state.legacyOrder.map { .legacyReply($0) }
        items.append(.incompatible)
        if !state.peerIsLegacy { items += [.config, .status, .history] }
        return items.filter { state.due[$0] != nil }
    }

    /// When the next probe goes out, or the outstanding one is given up on; `nil` when no probe is wanted.
    /// A probe is wanted while the watch is connected but not yet shown ready: at once, again 20 s later
    /// if unanswered, then every 60 s. A watch shown not to have the app is probed again only after a
    /// reconnect or a return to the foreground; otherwise a watch without the app would be probed forever.
    static func probeTime(_ state: WatchLinkState, configuration: WatchLinkConfiguration) -> LinkSeconds? {
        guard state.paired, state.device == .connected else { return nil }
        if state.probeOutstanding { return state.nextProbeAt }
        let unknown = !state.shownReady && state.appInstalled != false
        let askedAgain = state.appInstalled == false && state.probeRequested
        guard unknown || askedAgain else { return nil }
        return state.nextProbeAt ?? -.infinity
    }

    static func describe(_ input: WatchLinkInput) -> String {
        switch input {
        case .paired(let p): return p ? "paired" : "unpaired"
        case .deviceStatus(let s): return "device \(s.rawValue)"
        case .characteristicsDiscovered: return "characteristics discovered"
        case .appStatus(let installed, _): return "app status \(installed.map { "\($0)" } ?? "unknown")"
        case .sendProgress: return "send progress"
        case .sendCompleted(_, let r): return "send completed \(r)"
        case .received: return "received"
        case .receivedUnreadable: return "received unreadable"
        case .appActive(let a): return a ? "app active" : "app inactive"
        case .setConfig: return "config set"
        case .setStatus: return "status set"
        case .setHistory: return "history set"
        case .sendResult: return "result queued"
        case .tick: return "tick"
        }
    }
}

/// One reduction. Kept as a value with the state passed in, so nothing reads the state while it's being
/// changed.
private struct Step {
    let configuration: WatchLinkConfiguration
    let now: LinkSeconds
    let jitter: Double
    var effects: [WatchLinkEffect] = []
    /// Why the phase changed, when something more specific than the input explains it.
    var reason: String?

    init(configuration: WatchLinkConfiguration, now: LinkSeconds, jitter: Double) {
        self.configuration = configuration
        self.now = now
        self.jitter = jitter
    }

    // MARK: Timers

    /// Deadlines that passed while nothing was running (timers don't fire while the app is suspended).
    mutating func catchUp(_ state: inout WatchLinkState) {
        if let f = state.inFlight,
            now - f.lastProgressAt >= configuration.noProgressTimeout || now - f.startedAt >= configuration.hardCeiling
        {
            stall(&state)
        }
        if let until = state.backoffUntil, now >= until { state.backoffUntil = nil }
        if state.probeOutstanding, let at = state.nextProbeAt, now >= at {
            // The transport never answered the probe. Count it; the next one is due now.
            state.probeOutstanding = false
            state.probesWithoutAnswer += 1
        }
    }

    // MARK: Inputs

    mutating func apply(_ input: WatchLinkInput, to state: inout WatchLinkState) {
        switch input {
        case .paired(let paired):
            state.paired = paired
            if !paired { forget(&state) }
        case .deviceStatus(let status):
            let reconnected = status == .connected && state.device != .connected
            state.device = status
            if status != .connected {
                state.shownReady = false
                state.probeOutstanding = false
            }
            if reconnected { probeSoon(&state) }
        case .characteristicsDiscovered:
            state.device = .connected
            markShownReady(&state)
        case .appStatus(let installed, let probe):
            guard probe == state.probe, state.probeOutstanding else { return }
            state.probeOutstanding = false
            // An answer for a watch that has since disconnected says nothing about the next connection.
            guard state.device == .connected else { return }
            switch installed {
            case true?:
                state.appInstalled = true
                markShownReady(&state)
            case false?:
                state.appInstalled = false
                reason = "app not installed"
            case nil:
                state.probesWithoutAnswer += 1
            }
        case .sendProgress(let send):
            if send == state.inFlight?.send { state.inFlight?.lastProgressAt = now }
        case .sendCompleted(let send, let result):
            completed(send: send, result, &state)
        case .received(let wire):
            received(wire, &state)
        case .receivedUnreadable:
            state.telemetry.received += 1
            state.telemetry.receivedMalformed += 1
            state.telemetry.lastReceivedAt = now
        case .appActive(let active):
            // Coming back to the foreground is when the user may have installed the app or fixed the watch.
            if active { probeSoon(&state) }
        case .setConfig(let config):
            guard config.revision != state.config?.revision else { return }
            state.config = config
            setDue(.config, &state)
        case .setStatus(let status):
            state.status = status
            setDue(.status, &state)
        case .setHistory(let history):
            state.history = history
            setDue(.history, &state)
        case .sendResult(let message):
            queueResult(message, &state)
        case .tick:
            break
        }
    }

    private mutating func completed(send: Int, _ result: WatchSendResult, _ state: inout WatchLinkState) {
        // Any completion shows the channel is alive, so a run of stalls is broken.
        state.stallStreak = 0
        guard let f = state.inFlight, f.send == send else {
            state.telemetry.lateCompletions += 1
            return
        }
        state.inFlight = nil
        switch result {
        case .delivered:
            state.telemetry.delivered += 1
            state.telemetry.lastDeliveredAt = now
            state.backoffLevel = 0
            if state.due[f.item]?.version == f.version { remove(f.item, &state) }
        case .transientFailure(let why):
            state.telemetry.transientFailures += 1
            state.telemetry.lastFailure = why
            countAttempt(f, &state)
            backOff(&state)
        case .appNotFound:
            state.telemetry.appNotFound += 1
            state.telemetry.lastFailure = "app not found"
            state.appInstalled = false
            reason = "app not found"
        case .undeliverable(let why):
            state.telemetry.undeliverable += 1
            state.telemetry.lastFailure = why
            // It can never go, so it's dropped at once rather than retried.
            if state.due[f.item]?.version == f.version {
                remove(f.item, &state)
                state.telemetry.dropped += 1
            }
        }
    }

    private mutating func received(_ wire: WireValue, _ state: inout WatchLinkState) {
        state.telemetry.received += 1
        state.telemetry.lastReceivedAt = now
        switch RemoteMessage.receive(wire) {
        case .message(let message):
            guard !message.kind.fromPhone else {
                state.telemetry.receivedUnexpected += 1
                return
            }
            shownReachable(&state)
            state.peerIsLegacy = false
            switch message {
            case .poll(let poll):
                if let config = state.config, poll.configRevision != config.revision { setDue(.config, &state) }
                if state.status != nil { setDue(.status, &state) }
                if poll.wantsHistory { effects.append(.host(.history)) }
                if poll.freshGlucose { effects.append(.host(.refreshGlucose)) }
                if let id = poll.awaitingRequestId { effects.append(.host(.outcome(requestId: id))) }
            case .bolus(let p): effects.append(.host(.bolus(p)))
            case .cancel(let p): effects.append(.host(.cancel(p)))
            case .dismiss(let p): effects.append(.host(.dismiss(p)))
            case .status, .config, .history, .bolusOutcome, .dismissResult, .incompatible: break
            }
        case .legacy(let message):
            state.telemetry.receivedLegacy += 1
            shownReachable(&state)
            state.peerIsLegacy = true
            // A cancel is never gated, so the old app's is acted on too; nothing else of version 1 is.
            if message.kind == LegacyV1.cancelKind {
                effects.append(.host(.cancel(CancelPayload(requestId: message.requestId ?? "v1", bolusRequestId: nil))))
            }
            guard let reply = LegacyV1.reply(to: message) else { return }
            let n = state.nextLegacy
            state.nextLegacy += 1
            state.legacyOrder.append(n)
            setDue(.legacyReply(n), &state, legacy: reply)
            while state.legacyOrder.count > configuration.maxQueuedLegacyReplies,
                let oldest = state.legacyOrder.first(where: { state.inFlight?.item != .legacyReply($0) })
            {
                remove(.legacyReply(oldest), &state)
                state.telemetry.dropped += 1
            }
        case .otherVersion(let version):
            state.telemetry.receivedOtherVersion += 1
            shownReachable(&state)
            setDue(.incompatible, &state, message: .incompatible(IncompatiblePayload(peerVersion: version)))
        case .malformed(let error):
            state.telemetry.receivedMalformed += 1
            state.telemetry.lastFailure = "malformed: \(error)"
            shownReachable(&state)
            if let id = RemoteMessage.unreadableBolusRequestId(wire) {
                effects.append(.host(.unreadableBolus(requestId: id)))
            }
        case .unrecognized:
            state.telemetry.receivedUnexpected += 1
        }
    }

    // MARK: Readiness

    /// A message from the watch shows it's connected and the app is on it.
    private mutating func shownReachable(_ state: inout WatchLinkState) {
        guard state.paired else { return }
        state.device = .connected
        state.appInstalled = true
        markShownReady(&state)
    }

    /// The watch just became able to take messages: it gets the config in full and a status.
    mutating func becameReady(_ state: inout WatchLinkState) {
        reason = "ready"
        state.backoffUntil = nil
        state.backoffLevel = 0
        if state.config != nil { setDue(.config, &state) }
        if state.status != nil { setDue(.status, &state) }
    }

    private mutating func probeSoon(_ state: inout WatchLinkState) {
        state.nextProbeAt = nil
        state.probeRequested = true
        state.probesWithoutAnswer = 0
        state.probeOutstanding = false
    }

    /// The watch has been shown ready; an outstanding probe no longer matters.
    private mutating func markShownReady(_ state: inout WatchLinkState) {
        state.shownReady = true
        state.probeOutstanding = false
        state.probesWithoutAnswer = 0
    }

    mutating func probeIfDue(_ state: inout WatchLinkState) {
        guard !state.probeOutstanding, let at = WatchLinkReducer.probeTime(state, configuration: configuration),
            now >= at
        else { return }
        let intervals = configuration.probeIntervals
        state.probe += 1
        state.probeOutstanding = true
        state.probeRequested = false
        state.nextProbeAt = now + intervals[min(state.probesWithoutAnswer, intervals.count - 1)]
        state.telemetry.probes += 1
        effects.append(.probeAppStatus(probe: state.probe))
    }

    // MARK: Sending

    mutating func pump(_ state: inout WatchLinkState) {
        guard state.isReady, state.inFlight == nil, state.backoffUntil == nil else { return }
        for item in WatchLinkReducer.order(state) {
            guard let pending = state.due[item] else { continue }
            guard let wire = wire(for: item, pending, state) else {
                remove(item, &state)
                continue
            }
            state.inFlight = .init(
                send: state.nextSend, item: item, version: pending.version, startedAt: now, lastProgressAt: now)
            state.nextSend += 1
            state.telemetry.transmits += 1
            effects.append(.transmit(send: state.nextSend - 1, wire))
            return
        }
    }

    private func wire(for item: OutboxItem, _ pending: WatchLinkState.Pending, _ state: WatchLinkState) -> WireValue? {
        switch item {
        case .outcome, .dismissResult, .incompatible: return pending.message?.wire
        case .legacyReply: return pending.legacy
        case .config: return state.config.map { RemoteMessage.config($0).wire }
        case .status: return state.status.map { RemoteMessage.status($0).wire }
        case .history: return state.history.map { RemoteMessage.history($0).wire }
        }
    }

    private mutating func stall(_ state: inout WatchLinkState) {
        guard let f = state.inFlight else { return }
        state.inFlight = nil
        state.telemetry.stalls += 1
        state.telemetry.lastFailure = "no completion"
        countAttempt(f, &state)
        state.stallStreak += 1
        reason = "send stalled"
        if state.stallStreak >= configuration.stallsBeforeReregister,
            state.lastReregisterAt.map({ now - $0 >= configuration.minReregisterInterval }) ?? true
        {
            state.stallStreak = 0
            state.lastReregisterAt = now
            state.telemetry.reregistrations += 1
            effects.append(.reregister)
            reason = "re-registered after stalls"
            // The rebuilt registration has to show it's ready again before anything more goes.
            state.shownReady = false
            probeSoon(&state)
        }
        backOff(&state)
    }

    private mutating func backOff(_ state: inout WatchLinkState) {
        let steps = configuration.backoff
        state.backoffLevel = min(state.backoffLevel + 1, steps.count)
        let base = steps[state.backoffLevel - 1]
        state.backoffUntil = now + base * (1 + max(0, min(1, jitter)) * configuration.backoffJitter)
    }

    private mutating func countAttempt(_ f: WatchLinkState.InFlight, _ state: inout WatchLinkState) {
        guard var pending = state.due[f.item], pending.version == f.version else { return }
        pending.attempts += 1
        if pending.attempts >= configuration.maxAttempts {
            remove(f.item, &state)
            state.telemetry.dropped += 1
        } else {
            state.due[f.item] = pending
        }
    }

    // MARK: The outbox

    private mutating func setDue(
        _ item: OutboxItem, _ state: inout WatchLinkState, message: RemoteMessage? = nil, legacy: WireValue? = nil
    ) {
        state.contentVersion += 1
        state.due[item] = .init(message: message, legacy: legacy, version: state.contentVersion)
    }

    private mutating func queueResult(_ message: RemoteMessage, _ state: inout WatchLinkState) {
        let item: OutboxItem
        switch message {
        case .bolusOutcome(let p):
            item = .outcome(requestId: p.requestId)
            // Outcomes reach the link from more than one task, so a newer one can be queued before an
            // older one. The older one never replaces it: a queued outcome only moves forward.
            if case .bolusOutcome(let queued)? = state.due[item]?.message, !queued.outcome.canMove(to: p.outcome) {
                return
            }
        case .dismissResult(let p):
            item = .dismissResult(requestId: p.requestId)
        default:
            return
        }
        if !state.resultOrder.contains(item) { state.resultOrder.append(item) }
        setDue(item, &state, message: message)
        // Over the cap, dismiss results go before bolus outcomes, oldest first, never the one in flight.
        while state.resultOrder.count > configuration.maxQueuedResults {
            let candidates = state.resultOrder.filter { state.inFlight?.item != $0 }
            guard
                let oldest = candidates.first(where: { if case .dismissResult = $0 { true } else { false } })
                    ?? candidates.first
            else { break }
            remove(oldest, &state)
            state.telemetry.dropped += 1
        }
    }

    private mutating func remove(_ item: OutboxItem, _ state: inout WatchLinkState) {
        state.due[item] = nil
        switch item {
        case .outcome, .dismissResult: state.resultOrder.removeAll { $0 == item }
        case .legacyReply(let n): state.legacyOrder.removeAll { $0 == n }
        case .incompatible, .config, .status, .history: break
        }
    }

    /// The watch was deselected: nothing queued for it is wanted any more.
    private mutating func forget(_ state: inout WatchLinkState) {
        state.device = .unknown
        state.shownReady = false
        state.appInstalled = nil
        state.due = [:]
        state.resultOrder = []
        state.legacyOrder = []
        state.peerIsLegacy = false
        state.inFlight = nil
        state.backoffUntil = nil
        state.backoffLevel = 0
        state.stallStreak = 0
        state.probeOutstanding = false
        state.nextProbeAt = nil
        state.probeRequested = false
        state.probesWithoutAnswer = 0
    }
}
