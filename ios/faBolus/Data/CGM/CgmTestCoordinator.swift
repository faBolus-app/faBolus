import Foundation
import faBolusCore

/// Phase 16 GO-1 Step 3 (REMED-16): the CGM "Test" flow's poll-loop state machine, extracted
/// verbatim out of `AppModel` behind the `DeliveryLedgerCoordinator` closure-binding idiom (D-04).
///
/// Depends ONLY on an injected `probe` closure bound to `AppModel.glucoseSourceProbe` (never reads
/// `glucoseSource` directly — `glucoseSource` stays private, INV-A) plus injected `now`/
/// `scheduleTick` clock seams (CX-A-08: deterministic under test — no wall-clock `Date()`/
/// `Task.sleep` call inside the poll-loop logic itself; only the production-bound default of
/// `scheduleTick` uses a real sleep). `AppModel` mirrors this coordinator's published `State` into
/// its own `@Observable` stored properties via `onStateChanged`, exactly like `deliveryBlockedReason`
/// mirrors `DeliveryLedgerCoordinator.onDeliveryBlockChanged` — every existing SwiftUI observer
/// (`CgmCredentialsView`/`CgmStatusView` reading `model.cgmTestInProgress`/`cgmTestOutcome`/etc.)
/// keeps working unchanged.
///
/// This coordinator never doses, never gates, never holds a whole-`AppModel` back-pointer (D-04
/// rule 1/5).
@MainActor
final class CgmTestCoordinator {

    /// The shape of `AppModel.glucoseSourceProbe` (a read-only snapshot of the live production
    /// failover source — id / connectionKind / latest reading / status). A `typealias` over the
    /// SAME anonymous tuple shape `AppModel.glucoseSourceProbe` already returns, so the `probe`
    /// closure below is wired with zero conversion at the call site.
    typealias Probe = (
        id: String, connectionKind: GlucoseConnectionKind, latest: GlucoseSample?, status: GlucoseSourceStatus
    )

    /// The 4 fields the Test flow publishes — moved verbatim from `AppModel.swift`'s
    /// `cgmTestInProgress`/`cgmTestElapsedSeconds`/`cgmTestTimeoutSeconds`/`cgmTestOutcome`.
    struct State: Equatable {
        var inProgress = false
        var elapsedSeconds = 0
        var timeoutSeconds = 0
        var outcome: CgmTestOutcome?
    }

    // MARK: - Injected seam bindings + side-effect hooks (D-04)
    //
    // `var`s with safe no-op defaults, wired by `AppModel` as SEPARATE statements right after
    // construction (Swift's two-phase init forbids a `[weak self]`-capturing closure literal inside
    // the very expression that initializes the property holding it).

    /// Bound to `AppModel.glucoseSourceProbe`. Never reads `glucoseSource` directly (INV-A).
    var probe: () -> Probe? = { nil }
    /// Bound to `AppModel.failoverAutoDisabled != nil`, read at the moment `start()` finds no probe —
    /// composes the same "temporarily disabled" vs. "no fallback source" detail string AppModel used
    /// to build inline.
    var failoverAutoDisabled: () -> Bool = { false }
    /// CX-A-08 clock seam: production binds this to `Date()`; tests inject a scripted/advancing clock.
    var now: () -> Date = { Date() }
    /// CX-A-08 tick seam: production binds this to the pre-existing real 1s `Task.sleep`; tests inject
    /// a deterministic advance (e.g. `{ }` or `{ await Task.yield() }`) — no wall-clock sleep in the
    /// loop body itself.
    var scheduleTick: () async -> Void = { try? await Task.sleep(nanoseconds: 1_000_000_000) }
    /// Mirrors the freshly computed `State` into `AppModel`'s own `@Observable` stored properties
    /// (mirrors `DeliveryLedgerCoordinator.onDeliveryBlockChanged`).
    var onStateChanged: (State) -> Void = { _ in }

    // MARK: - State (moved verbatim from AppModel.swift's cgmTest* fields)

    private(set) var state = State() {
        didSet { if state != oldValue { onStateChanged(state) } }
    }
    private var pollTask: Task<Void, Never>?

    /// How long the Test flow waits before concluding TIMEOUT — keyed on the source's typed
    /// `connectionKind` (D-06/D-09), NOT on `id`-string literals. Moved verbatim from
    /// `AppModel.cgmTestTimeout(for:)`.
    static func cgmTestTimeout(for kind: GlucoseConnectionKind) -> TimeInterval {
        switch kind {
        case .localBLE: return 6 * 60  // one full Dexcom wake/connect cycle (~5 min) + margin
        case .cloudPoll: return 20  // auth handshake + one network round-trip (~15–20s)
        case .localOnDevice: return 10  // near-instant read of the shared on-device store
        }
    }

    /// W-03: the Test poll loop must ABORT when the live probe no longer matches the source the Test
    /// STARTED against — the user switched or cleared the failover source mid-Test. Moved verbatim
    /// from `AppModel.cgmTestShouldAbort`.
    static func cgmTestShouldAbort(startedSourceId: String, currentProbeId: String?) -> Bool {
        currentProbeId != startedSourceId
    }

    /// A single poll-loop decision step (W-03) — pure over `probe()`/`now()` evaluated AT CALL TIME,
    /// so it is directly unit-testable without driving the async `Task` loop below. Returns `true`
    /// when the run reached a terminal state (success/timeout/abort) and the loop should stop;
    /// `false` when it should `await scheduleTick()` and evaluate again.
    @discardableResult
    func performTick(startedSourceId: String, startedAt: Date, timeout: TimeInterval) -> Bool {
        guard let probeValue = probe(),
            !Self.cgmTestShouldAbort(startedSourceId: startedSourceId, currentProbeId: probeValue.id)
        else {
            // W-03: source changed/cleared mid-Test — clear BOTH the in-progress flag AND the
            // outcome so no frozen stale `.waiting` screen is left behind.
            state.inProgress = false
            state.outcome = nil
            return true
        }
        let elapsed = now().timeIntervalSince(startedAt)
        state.elapsedSeconds = Int(elapsed)
        let outcome = CgmTestOutcome.testOutcome(
            latest: probeValue.latest, status: probeValue.status,
            elapsed: elapsed, timeout: timeout)
        state.outcome = outcome
        if case .waiting = outcome { return false }
        state.inProgress = false
        return true
    }

    /// Start (or restart) the Test flow. OBSERVES `probe()` on a poll instead of building a second
    /// central, so an already-buffered reading resolves `.success` on the very first tick. Reports an
    /// immediate `.timeout` (not a spin) when no production instance exists — moved verbatim from
    /// `AppModel.startCgmTest`.
    func start() {
        pollTask?.cancel()
        guard let probeValue = probe() else {
            state = State(
                inProgress: false, elapsedSeconds: 0, timeoutSeconds: 0,
                outcome: .timeout(
                    detail: failoverAutoDisabled()
                        ? "The fallback source was temporarily disabled after repeated unclean starts — it will automatically retry, or re-select it in Settings now."
                        : "No fallback source is selected."))
            return
        }
        let sourceId = probeValue.id
        let timeout = Self.cgmTestTimeout(for: probeValue.connectionKind)
        state = State(inProgress: true, elapsedSeconds: 0, timeoutSeconds: Int(timeout), outcome: nil)
        let startedAt = now()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let done = self.performTick(startedSourceId: sourceId, startedAt: startedAt, timeout: timeout)
                if done { return }
                await self.scheduleTick()
            }
        }
    }

    /// Test-only: await the in-flight poll `Task`'s completion, so an end-to-end `start()` ->
    /// terminal-state characterization test can await the real async path once, deterministically,
    /// instead of racing `Task.yield()` calls against the scheduler.
    func waitForPollTaskToFinish() async {
        await pollTask?.value
    }
}
