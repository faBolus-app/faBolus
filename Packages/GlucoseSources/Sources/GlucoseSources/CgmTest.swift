import Foundation
import faBolusCore

/// The result of the CGM test from settings. Determinate: the coordinator re-evaluates on a timer
/// rather than spinning. A reading already held always wins, even past the timeout, so a late tick
/// never downgrades a real result. A source that reports a problem (or needs setup) ends the test at
/// once with that reason; there is nothing to wait for.
public enum CgmTestOutcome: Equatable, Sendable {
    case waiting
    case success(GlucoseSample)
    case timeout(detail: String?)

    public static func testOutcome(
        latest: GlucoseSample?, status: GlucoseSourceStatus, elapsed: TimeInterval, timeout: TimeInterval
    ) -> CgmTestOutcome {
        if let latest { return .success(latest) }
        switch status {
        case .unavailable(let problem): return .timeout(detail: problem.message)
        case .needsSetup: return .timeout(detail: "Not set up yet.")
        default: break
        }
        if elapsed >= timeout { return .timeout(detail: nil) }
        return .waiting
    }
}

/// Runs the CGM test against the source already running, never a second instance: a second
/// Bluetooth central would need a second restore identifier, and a reading the running source
/// already has should show at once. Depends only on injected closures, so its states are tested
/// without a source or a clock.
@MainActor
public final class CgmTestCoordinator {
    /// What the test watches: the running source's id, kind and state.
    public struct Probe: Sendable {
        public let id: String
        public let connectionKind: GlucoseConnectionKind
        public let state: GlucoseSourceState

        public init(id: String, connectionKind: GlucoseConnectionKind, state: GlucoseSourceState) {
            self.id = id
            self.connectionKind = connectionKind
            self.state = state
        }

        /// A snapshot of `source`.
        public static func of(_ source: any GlucoseSource) async -> Probe {
            Probe(id: source.id, connectionKind: source.connectionKind, state: await source.state)
        }
    }

    public struct State: Equatable, Sendable {
        public var inProgress = false
        public var elapsedSeconds = 0
        public var timeoutSeconds = 0
        public var outcome: CgmTestOutcome?
    }

    /// The running source, or `nil` when none is selected.
    public var probe: @MainActor () async -> Probe? = { nil }
    /// Whether the selected source is held off after repeated unclean starts.
    public var failoverAutoDisabled: @MainActor () -> Bool = { false }
    public var now: @MainActor () -> Date = { Date() }
    public var scheduleTick: @MainActor () async -> Void = { try? await Task.sleep(for: .seconds(1)) }
    public var onStateChanged: @MainActor (State) -> Void = { _ in }

    public private(set) var state = State() {
        didSet { if state != oldValue { onStateChanged(state) } }
    }
    private var pollTask: Task<Void, Never>?

    public init() {}

    /// How long the test waits: one Dexcom wake cycle and a margin for Bluetooth, a sign-in and a
    /// round trip for the cloud.
    public static func timeout(for kind: GlucoseConnectionKind) -> TimeInterval {
        switch kind {
        case .localBLE: return 6 * 60
        case .cloudPoll: return 20
        case .localOnDevice: return 10
        }
    }

    /// The test stops when the running source is no longer the one it started against.
    public static func shouldAbort(startedSourceID: String, currentProbeID: String?) -> Bool {
        currentProbeID != startedSourceID
    }

    /// One step of the test. Returns `true` when the run ended (success, timeout or abort).
    @discardableResult
    public func performTick(startedSourceID: String, startedAt: Date, timeout: TimeInterval) async -> Bool {
        let current = await probe()
        // A run replaced by a newer `start` while it waited leaves the new run's state alone.
        guard !Task.isCancelled else { return true }
        guard let probe = current, !Self.shouldAbort(startedSourceID: startedSourceID, currentProbeID: probe.id)
        else {
            // Source changed or cleared: leave no frozen "waiting" behind.
            state.inProgress = false
            state.outcome = nil
            return true
        }
        let elapsed = now().timeIntervalSince(startedAt)
        state.elapsedSeconds = Int(elapsed)
        let outcome = CgmTestOutcome.testOutcome(
            latest: probe.state.latest, status: probe.state.status, elapsed: elapsed, timeout: timeout)
        state.outcome = outcome
        if case .waiting = outcome { return false }
        state.inProgress = false
        return true
    }

    /// Starts (or restarts) the test. With no source selected it ends at once.
    public func start() async {
        pollTask?.cancel()
        guard let probe = await probe() else {
            state = State(
                outcome: .timeout(
                    detail: failoverAutoDisabled()
                        ? "The backup source was paused after repeated unclean starts. It retries on its own, or select it again in Settings."
                        : "No backup source is selected."))
            return
        }
        let timeout = Self.timeout(for: probe.connectionKind)
        state = State(inProgress: true, elapsedSeconds: 0, timeoutSeconds: Int(timeout), outcome: nil)
        let startedAt = now()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                if await self.performTick(startedSourceID: probe.id, startedAt: startedAt, timeout: timeout) { return }
                await self.scheduleTick()
            }
        }
    }

    /// Waits for the running test to end. For tests.
    func waitForPollTask() async {
        await pollTask?.value
    }

    // MARK: - Copy, by connection kind (Bluetooth copy never leaks into cloud or on-device copy)

    public nonisolated static func waitingHeadline(kind: GlucoseConnectionKind, sourceName: String) -> String {
        switch kind {
        case .localBLE:
            return
                "Waiting for the next Dexcom reading, up to about 5 min. Keep the Dexcom app running; you can leave this screen and we'll keep listening."
        case .cloudPoll:
            return "Checking your sign-in and connection to \(sourceName). This usually takes a few seconds."
        case .localOnDevice:
            return "Checking whether \(sourceName) is syncing readings on this device. This is usually near-instant."
        }
    }

    public nonisolated static func timeoutHeadline(kind: GlucoseConnectionKind, sourceName: String, elapsedSeconds: Int)
        -> String
    {
        switch kind {
        case .localBLE:
            return
                "No reading yet after \(max(1, elapsedSeconds / 60)) min. Make sure the Dexcom app is running and showing readings."
        case .cloudPoll:
            return
                "No reading after \(max(1, elapsedSeconds)) s from \(sourceName). Check your username, password and internet connection."
        case .localOnDevice:
            return
                "No reading yet from \(sourceName). Make sure the app that provides it is installed and syncing glucose on this device."
        }
    }
}

/// The badge shown while the live glucose comes from a backup source instead of the pump.
public enum FailoverBadgePresenter {
    /// A short source name and the reason, or `nil` while the pump's feed is shown. `name(for:)` looks
    /// up a source's display name; an unknown id shows as itself.
    public static func failoverBadge(provenance: GlucoseProvenance, name: (String) -> String?)
        -> (name: String, reason: String)?
    {
        guard case .failover(let sourceID, let reason) = provenance else { return nil }
        let full = name(sourceID) ?? sourceID
        switch reason {
        case .pumpMissing: return (shortSourceName(full), "Showing \(full) — the pump has no CGM reading.")
        case .pumpStale: return (shortSourceName(full), "Showing \(full) — the pump's CGM reading went stale.")
        }
    }

    /// The name without its qualifier, so it fits the badge: "Dexcom Share (cloud)" → "Dexcom Share".
    public static func shortSourceName(_ full: String) -> String {
        var name = full
        for separator in [" (", " — ", " / "] {
            if let range = name.range(of: separator) { name = String(name[..<range.lowerBound]) }
        }
        return name.trimmingCharacters(in: .whitespaces)
    }
}
