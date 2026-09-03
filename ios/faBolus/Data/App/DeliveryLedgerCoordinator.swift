import Foundation
import faBolusCore

/// Ledger / global-block **host state machine**. Owns the durable idempotency ledger + store, the 4
/// fail-closed flags, the in-flight delivery key, the persist/retry paths, the global-block
/// computation, and the two funnels every delivery surface goes through (`runLedgeredDelivery` /
/// `reconcileUnresolvedDeliveries`).
///
/// Depends ONLY on the existing seam (via closures bound to `source.reconcile` /
/// `source.lastBolusCancelled`, plus the per-call `deliver` closure) and injected side-effect hooks —
/// never a whole `AppModel` back-pointer. `AppModel` stays the single `@Observable` publisher of
/// `deliveryBlockedReason`/`deliveryGloballyBlocked`.
///
/// This is ONE of the two independent fail-closed layers in the dosing path. It must never be
/// unified with `TandemBackend.validateDeliver`'s own local `deliveryOutcomeUnknown` block.
@MainActor
final class DeliveryLedgerCoordinator {

    // MARK: - Injected seam bindings + side-effect hooks
    //
    // `var`s with safe no-op defaults, set by `AppModel` right after construction (mirroring how
    // `AppModel.init` already wires `source.onChange`/`source.commitBolusId` as separate statements
    // AFTER `source` is assigned) — NOT `init` parameters. Swift's two-phase init forbids an `[weak
    // self]`-capturing closure from appearing inside the very expression that initializes the stored
    // property holding it (the property isn't "initialized" until that expression finishes evaluating),
    // so these must be assigned once `self.deliveryLedgerCoordinator` itself already holds a value.

    /// Bound to `source.reconcile(bolusId:)`.
    var reconcile: (Int) async -> BolusReconciliation = { _ in .unavailable }
    /// Bound to `source.lastBolusCancelled`, read immediately after `deliver()` completes.
    var lastBolusCancelled: () -> Bool = { false }
    /// Bound to `AppModel.connectionTelemetry.recordReconciliation`.
    var recordReconciliation: (ConnectionTelemetry.ReconcileOutcome) -> Void = { _ in }
    /// Bound to `AppModel`'s private `postSafety(_:severity:title:body:dedupeKey:)`.
    var postSafety: (NotificationBroker.Category, NotificationBroker.Severity, String, String, String) -> Void = {
        _, _, _, _, _ in
    }
    /// Bound to `AppModel.refresh()`.
    var refresh: () -> Void = {}
    /// Mirrors the freshly computed block reason into `AppModel`'s own `@Observable` stored property
    /// (source of the published `deliveryBlockedReason`/`deliveryGloballyBlocked`), so SwiftUI
    /// observation is unbroken.
    var onDeliveryBlockChanged: (String?) -> Void = { _ in }
    /// Bound to `AppModel.currentPumpIdentity()` — the stable identity of the pump connected RIGHT NOW.
    /// Used to scope a ledger entry's outcome to the pump that wrote it: no new
    /// pump-protocol read, and the identity concept `PumpSwitchStore.decide` already compares.
    var currentPumpIdentity: () -> String = { RemoteBolusLedger.unpairedPumpKeySentinel }
    /// Bound to `source.clearUnknownOutcomeAfterManualVerification()` — the backend's OWN in-memory
    /// fail-closed flag, independent of this coordinator's durable ledger block. Manual verification
    /// must release both together (never one alone); see `clearDeliveryBlockAfterVerification()`.
    var clearUnknownOutcome: () -> Void = {}
    /// Bound to `AppModel.snapshot.connection` — read LIVE at each periodic-retry decision (never
    /// captured once), so a link that drops between arming and firing stops the bounded retry
    /// driver below rather than asking a pump that is no longer there.
    var currentConnection: () -> PumpConnectionState = { .disconnected }

    // MARK: - Ledger + store

    /// Idempotency ledger: a duplicated/retried remote bolus (same peer + requestId) cannot deliver
    /// twice. Keyed by authenticated peer identity + requestId; MainActor-isolated.
    /// Durable — persisted (App Group) so exactly-once survives a process restart mid-delivery.
    private let remoteBolusLedgerStore: any RemoteBolusLedgerPersisting
    private lazy var remoteBolusLedger: RemoteBolusLedger = {
        let outcome = remoteBolusLedgerStore.loadOutcome()
        if outcome.failedClosed { ledgerFailedClosed = true }
        return outcome.ledger
    }()
    /// True when the durable ledger existed but couldn't be read (corrupt/unreadable). An unreadable
    /// ledger may be hiding an unresolved delivery, so while this is set ALL delivery is blocked (fail
    /// closed) until the user verifies on the pump and clears it.
    private var ledgerFailedClosed = false
    /// No durable safety-ledger location exists (no App Group / Application Support). Delivery
    /// must stay disabled rather than fall back to a volatile store.
    private var noDurableStore = false
    /// A terminal (or manual-clear) ledger save failed; keep the global block until a
    /// clean save succeeds, and retry persistence in the background.
    private var terminalSaveFailed = false
    /// The ledger entry (peer, requestId) whose delivery is currently in flight, so the pump's
    /// `commitBolusId` handshake lands the assigned bolus id on the right entry. Deliveries are
    /// serialized (one at a time), so a single slot suffices.
    private var inFlightDeliveryKey: (peerId: String, requestId: String)?

    // MARK: - Bounded periodic re-reconcile
    //
    // Reconciliation otherwise fires on EDGES only: launch, the disconnect→connect edge, and
    // `onPaired`. While an unresolved entry exists AND the link stays connected, this re-enters the
    // SAME `reconcileUnresolvedDeliveries()` funnel below on a fixed interval, capped at a bounded
    // number of attempts, then stays silent until the next genuine (non-periodic) call resets the
    // budget. Never a second search body — every tick calls this one function again.
    private static let periodicReconcileInterval: TimeInterval = 20
    private static let periodicReconcileMaxAttempts = 5
    /// Test seam, mirroring `TandemBackend.historySearchPageTimeoutOverride` /
    /// `deliveryPollTimeoutOverride` — lets a test drive several ticks without a real multi-second wait.
    var periodicReconcileIntervalOverride: TimeInterval?
    private var periodicReconcileTask: Task<Void, Never>?
    private var periodicReconcileAttempts = 0
    #if DEBUG
    /// Test seam, mirroring `TandemBackend.reconcileIndeterminateDeliveryCallCountForTesting` —
    /// counts only the SELF-scheduled ticks below (never the edge-triggered calls this function's
    /// caller already makes), so a test can prove a retry fired with no connect edge and no BLE.
    private(set) var periodicReconcileCallCountForTesting = 0
    #endif

    /// - Parameter ledgerStoreURL: overrides the durable idempotency-ledger file. Tests inject a
    ///   unique temp URL so instances don't share the App Group ledger; production uses the default.
    /// - Parameter ledgerStore: injects the durable store directly (a store that throws on a chosen
    ///   save, or reports a corrupt load). Takes precedence over `ledgerStoreURL`. Production leaves
    ///   it nil. `forceNoDurableStore` exercises the no-storage-location block, which the filesystem
    ///   path can't reproduce on a normal test host.
    init(
        ledgerStoreURL: URL? = nil,
        ledgerStore: (any RemoteBolusLedgerPersisting)? = nil,
        forceNoDurableStore: Bool = false
    ) {
        // Require a DURABLE store (App Group / test override). If none exists, do NOT fall
        // back to a volatile /tmp file — create a placeholder store but keep delivery disabled via
        // `noDurableStore` (surfaced as a recoverable block), so a bolus is never tracked in a store that
        // can vanish.
        if let ledgerStore {
            self.remoteBolusLedgerStore = ledgerStore
            self.noDurableStore = forceNoDurableStore
        } else {
            let durableURL = ledgerStoreURL ?? RemoteBolusLedgerStore.defaultURL(appGroupID: WidgetStore.appGroup)
            if durableURL == nil || forceNoDurableStore { self.noDurableStore = true }
            self.remoteBolusLedgerStore = RemoteBolusLedgerStore(
                url: durableURL
                    ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent(
                        "remote-bolus-ledger-unavailable.json"))
        }
    }

    /// Persist the ledger. Best-effort — for non-terminal writes (intent / indeterminate) where losing the
    /// record only risks a redundant reconcile, since the entry already blocks. Terminal transitions use
    /// `persistTerminalOrBlock()` (which keeps the block until the clean save lands).
    private func persistLedger() { remoteBolusLedgerStore.saveBestEffort(remoteBolusLedger) }

    /// Persist a TERMINAL/clean ledger state durably; if the save fails, retain the
    /// global block (`terminalSaveFailed`) and retry — never release the block on an unsaved terminal.
    private func persistTerminalOrBlock() {
        do {
            try remoteBolusLedgerStore.save(remoteBolusLedger)
            terminalSaveFailed = false
        } catch {
            terminalSaveFailed = true
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                self?.retryTerminalPersist()
            }
        }
    }
    private func retryTerminalPersist() {
        guard terminalSaveFailed else { return }
        do {
            try remoteBolusLedgerStore.save(remoteBolusLedger)
            terminalSaveFailed = false
            refreshDeliveryBlock()
        } catch {
            Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                self?.retryTerminalPersist()
            }
        }
    }

    #if DEBUG
    /// Test seam: `retryTerminalPersist()` is private and, on failure, re-schedules itself on a 5 s
    /// `Task.sleep` — untestable deterministically without this. Calls the SAME production method
    /// synchronously so a test can drive the release-on-retry-success path without sleeping. Test
    /// scaffolding only; it compiles to nothing in Release and never changes production
    /// dose/delivery/wire behavior.
    func retryTerminalPersistForTesting() { retryTerminalPersist() }
    #endif

    /// The backend's acknowledged bolus-id handshake. Records the pump-assigned id on the
    /// in-flight entry AND flips its explicit `sentToPump` phase, then saves DURABLY. Returns true only if
    /// the save succeeded — the backend must abort before writing metadata/initiate on false, so a save
    /// failure can never leave an id-less record a relaunch mistakes for "not sent."
    func commitInFlightBolusId(_ bolusId: Int) async -> Bool {
        guard let key = inFlightDeliveryKey else { return false }
        remoteBolusLedger.markSent(
            peerId: key.peerId, requestId: key.requestId, bolusId: bolusId, pumpKey: currentPumpIdentity())
        do {
            try remoteBolusLedgerStore.save(remoteBolusLedger)
            return true
        } catch { return false }
    }

    // MARK: - Global delivery block

    private func computeDeliveryBlockReason() -> String? {
        // Evaluate `unreconciled()` first so the lazy ledger load runs (which sets `ledgerFailedClosed`).
        let unresolved = remoteBolusLedger.unreconciled()
        // A different-pump key takes precedence over the live-in-flight/genuinely-unresolved split —
        // `blockReason`'s `unresolved:` parameter predates the ledger's `pumpKey` field, so the
        // comparison is done here and only its RESULT (a reason string, or nil) is passed through.
        let current = currentPumpIdentity()
        let pumpMismatchReason =
            unresolved.contains { RemoteBolusLedger.comparePumpKey($0.pumpKey, to: current) == .mismatch }
            ? RemoteBolusLedger.pumpMismatchBlockReason
            : nil
        // The precedence itself is a pure faBolusCore function (`RemoteBolusLedger.blockReason`) —
        // this is the ONLY caller in the app target, so the strings have one source of truth with
        // zero-`AppModel` unit coverage in `RemoteBolusLedgerTests`.
        let narrowed = unresolved.map {
            (peerId: $0.peerId, requestId: $0.requestId, bolusId: $0.bolusId, sentToPump: $0.sentToPump)
        }
        return RemoteBolusLedger.blockReason(
            noDurableStore: noDurableStore, ledgerFailedClosed: ledgerFailedClosed,
            terminalSaveFailed: terminalSaveFailed, unresolved: narrowed,
            inFlightDeliveryKey: inFlightDeliveryKey,
            pumpMismatchReason: pumpMismatchReason)
    }
    /// Recompute the current block reason and push it through `onDeliveryBlockChanged`. Exposed
    /// (not `private`) so `AppModel.init` can force one SYNCHRONOUS publish of any ledger state restored
    /// from a previous run before its own `init` returns — mirroring the original `AppModel` ordering
    /// where a caller could read `deliveryBlockedReason`/`deliveryGloballyBlocked` immediately after
    /// construction, before the async `reconcileUnresolvedDeliveries()` launched at the end of `init`
    /// completes.
    func refreshDeliveryBlock() { onDeliveryBlockChanged(computeDeliveryBlockReason()) }

    /// Escape hatch: the user has checked the pump/t:connect and confirms there is no unconfirmed
    /// delivery. Settle every unresolved entry as verified and clear a fail-closed (corrupt-ledger) lock,
    /// writing a fresh clean ledger, so delivery can resume. Never called automatically.
    func clearDeliveryBlockAfterVerification() {
        for entry in remoteBolusLedger.unreconciled() {
            remoteBolusLedger.settle(
                peerId: entry.peerId, requestId: entry.requestId,
                status: RemoteCommand.Status.manuallyCleared.rawValue,
                message: "Manually cleared after checking the pump — the app did not confirm delivery.")
        }
        // Only release the block once the clean ledger is durably saved. The backend's own in-memory
        // unknown-outcome flag is a SECOND, independent fail-closed layer guarding the same delivery
        // path (`validateDeliver`) — clear it together with the durable block, never separately, so a
        // successful manual clear doesn't leave the other layer re-refusing the dose it just unblocked.
        do {
            try remoteBolusLedgerStore.save(remoteBolusLedger)
            ledgerFailedClosed = false
            terminalSaveFailed = false
            clearUnknownOutcome()
        } catch {
            terminalSaveFailed = true
        }
        refreshDeliveryBlock()
    }

    // MARK: - On-device data export/erase support
    //
    // `AppModel.buildPrivacyExport` / `eraseAllOnDeviceHealthData` / `maybeHandlePumpSwitch` consult
    // the ledger via these narrow accessors instead of reaching into coordinator-private state.

    /// A read-only snapshot of the ledger for the unified privacy-data export. Pure read.
    var currentLedgerSnapshot: RemoteBolusLedger { remoteBolusLedger }

    /// True while a delivery is in flight or the global block is set — used by callers (pump-switch
    /// handling) that must DEFER rather than disturb ledger/snapshot state a crash-recovery reconcile
    /// still needs. No message; see `eraseRefusalReason()` for the erase path's own worded refusal.
    var hasInFlightOrUnresolvedDelivery: Bool { inFlightDeliveryKey != nil || computeDeliveryBlockReason() != nil }

    /// Whether the given (peer, requestId) already reached a terminal outcome (used by
    /// `presentRemoteBolus` to ignore a duplicate/already-handled remote request).
    func isSettled(peerId: String, requestId: String) -> Bool {
        remoteBolusLedger.isSettled(peerId: peerId, requestId: requestId)
    }

    /// Thin read-only passthrough to the durable ledger's additive
    /// content+time duplicate-recency query (scoped per peer — see `RemoteBolusLedger`'s doc comment).
    /// `AppModel.remoteDeliver` consults this BEFORE `runLedgeredDelivery`/`begin()` so a re-composed dose
    /// under a FRESH requestId is refused independent of the (peer,requestId) exactly-once key. Never
    /// mutates the ledger.
    func hasRecentlyDeliveredDuplicate(peerId: String, doseKey: String) -> Bool {
        remoteBolusLedger.hasRecentlyDeliveredDuplicate(peerId: peerId, doseKey: doseKey)
    }

    /// Thin read-only passthrough — whether the EXACT `(peerId, requestId)` already has a
    /// tracked ledger entry, in any lifecycle state. `AppModel.remoteDeliver` uses this to skip the
    /// recency guard for a genuine protocol retry of the SAME id (`begin()` already replays/blocks it
    /// correctly); the recency guard exists ONLY to catch a FRESH requestId reusing recent content.
    func hasExistingEntry(peerId: String, requestId: String) -> Bool {
        remoteBolusLedger.hasExistingEntry(peerId: peerId, requestId: requestId)
    }

    /// The durable terminal outcomes recorded for the Garmin peer, oldest→newest, so the bridge can
    /// re-seed its terminal-echo outbox at launch (a bolus outcome recorded in the ledger but never echoed
    /// across an app restart). Thin read-only passthrough — the bridge never touches the private ledger.
    func garminTerminalOutcomes() -> [(requestId: String, status: String, message: String?, deliveredUnits: Double?)] {
        remoteBolusLedger.terminalOutcomes(peerId: "garmin")
    }

    /// The SAME refusal gate `eraseAllOnDeviceHealthData` enforces — never erase over an in-flight or
    /// otherwise unresolved delivery (the ledger + snapshot are needed to reconcile it). Returns the
    /// worded refusal reason, or nil when it's safe to proceed.
    func eraseRefusalReason() -> String? {
        if inFlightDeliveryKey != nil {
            return "A bolus is being delivered right now. Wait for it to finish, then try again."
        }
        if let reason = computeDeliveryBlockReason() {
            return "Can't erase while a delivery is unresolved — this data is needed to reconcile it. \(reason)"
        }
        return nil
    }

    /// Reset the ledger audit trail to fresh/empty, persisted durably (best-effort — the caller has
    /// already confirmed via `eraseRefusalReason()` that no unresolved entry exists to lose).
    func resetLedgerForErase() {
        remoteBolusLedger = RemoteBolusLedger()
        remoteBolusLedgerStore.saveBestEffort(remoteBolusLedger)
    }

    // MARK: - Durable delivery ledger

    /// The outcome of a delivery routed through the durable ledger + global unresolved-delivery block.
    enum DeliveryOutcome {
        case delivered(units: Double, cancelled: Bool)
        case indeterminate
        case failed(String)
        /// Nothing was sent to the pump — a global block, an idempotency conflict, or an intent-record fail.
        case blocked(String)
        case duplicateInFlight
        case replay(status: String, message: String?, deliveredUnits: Double?)
    }

    /// Route EVERY delivery surface (local standard/extended, widget, Watch, Garmin, Mac, peer) through
    /// this one method so exactly-once idempotency AND the global unresolved-delivery block are enforced in
    /// a single place. It (1) refuses to start while any prior sent transaction is unresolved or the
    /// ledger is unreadable, (2) records intent DURABLY before the first pump write, (3) tags the in-flight
    /// entry so the pump's assigned bolus id is persisted before initiate, and (4) settles /
    /// marks-indeterminate on outcome. `onStarted` fires only after intent is durably recorded.
    func runLedgeredDelivery(
        peerId: String, requestId: String, doseKey: String,
        usedIncludedStaleBG: Bool = false,
        onStarted: (() -> Void)? = nil,
        deliver: () async throws -> Double
    ) async -> DeliveryOutcome {
        // Global block: survives restart via the durable ledger; corrupt ledger fails closed.
        if let reason = computeDeliveryBlockReason() { return .blocked(reason) }

        // `usedIncludedStaleBG` is DURABLE provenance only: recorded on a new ledger entry,
        // never part of `doseKey` or the conflict/replay/in-flight decision.
        switch remoteBolusLedger.begin(
            peerId: peerId, requestId: requestId, doseKey: doseKey,
            usedIncludedStaleBG: usedIncludedStaleBG)
        {
        case .proceed: break
        case .duplicateInFlight: return .duplicateInFlight
        case .replay(let s, let m, let u): return .replay(status: s, message: m, deliveredUnits: u)
        case .conflict: return .blocked("Duplicate request id with different dose — rejected.")
        }
        defer { refreshDeliveryBlock() }
        // Durable point: mark delivering + persist atomically BEFORE the first pump write. If the
        // intent can't be recorded, refuse to deliver (a crash after an unrecorded write could double-dose).
        remoteBolusLedger.markDelivering(peerId: peerId, requestId: requestId)
        do { try remoteBolusLedgerStore.save(remoteBolusLedger) } catch {
            remoteBolusLedger.settle(
                peerId: peerId, requestId: requestId,
                status: RemoteCommand.Status.failed.rawValue, message: "Could not record delivery intent")
            persistLedger()
            return .failed("Could not record delivery intent — not delivered.")
        }
        // Tag this entry so the backend's `commitBolusId` handshake (at pump permission, before initiate)
        // durably records the pump bolus id + `sentToPump` phase on THIS entry.
        inFlightDeliveryKey = (peerId, requestId)
        defer { inFlightDeliveryKey = nil }
        onStarted?()
        do {
            let delivered = try await deliver()
            let cancelled = lastBolusCancelled()
            remoteBolusLedger.settle(
                peerId: peerId, requestId: requestId,
                status: (cancelled ? RemoteCommand.Status.cancelled : .delivered).rawValue,
                deliveredUnits: delivered)
            persistTerminalOrBlock()  // keep the block until this terminal state is durably saved
            return .delivered(units: delivered, cancelled: cancelled)
        } catch let e as BolusError where e.isIndeterminate {
            // Sent but outcome unknown (timeout/disconnect after initiate) → leave the entry
            // unreconciled (keeps the GLOBAL block on) and tell the surface to verify. This is
            // indeterminate, not failed — a retry of the same request must not redose.
            // Reconciliation by bolus id clears it later.
            _ = e
            remoteBolusLedger.markIndeterminate(peerId: peerId, requestId: requestId)
            persistLedger()
            return .indeterminate
        } catch {
            remoteBolusLedger.settle(
                peerId: peerId, requestId: requestId,
                status: RemoteCommand.Status.failed.rawValue, message: error.localizedDescription)
            persistTerminalOrBlock()
            return .failed(error.localizedDescription)
        }
    }

    /// Reconcile every unresolved delivery in the durable ledger against the pump, releasing the
    /// global block only for entries settled from an AUTHORITATIVE pump result. Call at launch and on
    /// every reconnect. An entry with NO pump bolus id was interrupted before the pump granted permission
    /// (so nothing could have been delivered) → safe to settle as not-delivered. An entry WITH an id is
    /// reconciled by that id; a mismatch/`.unavailable` keeps it blocked (verify on the pump).
    ///
    /// - Parameter viaPeriodicRetry: true only when THIS call is a self-scheduled bounded-retry tick
    ///   (see the periodic-retry block below); every other caller (launch / connect edge / manual
    ///   verification flows) leaves the default `false`, which re-arms the retry budget below.
    func reconcileUnresolvedDeliveries(viaPeriodicRetry: Bool = false) async {
        if !viaPeriodicRetry {
            // A genuine (non-periodic) call supersedes any tick already scheduled and resets the
            // bounded budget — it is the "next connect edge" the driver waits for after cap exhaustion.
            periodicReconcileTask?.cancel()
            periodicReconcileTask = nil
            periodicReconcileAttempts = 0
        }
        // Decide, on every exit path (including the empty-ledger early return below), whether one
        // more bounded retry is owed — never only on the path that found work to do.
        defer { scheduleNextPeriodicReconcileIfNeeded() }
        // Collapse a legacy ledger holding more than one unresolved id-bearing entry — written before
        // the global block existed, when the two fresh-connect triggers could still diverge onto
        // distinct ids. Must run before the read below: the block guarantees at most one going forward,
        // so more than one predates it entirely and needs re-establishing, not reconciling by id.
        var changed = remoteBolusLedger.collapseLegacyMultiEntryUnresolved()
        let unresolved = remoteBolusLedger.unreconciled()
        guard !unresolved.isEmpty else {
            refreshDeliveryBlock()
            return
        }
        for entry in unresolved {
            // Decide from the EXPLICIT phase, not merely a missing id. `sentToPump == false`
            // proves pre-initiate (the id was never durably recorded, so the backend aborted before the
            // initiate write) → safe to settle as not-delivered. `sentToPump == true` means the initiate is
            // imminent/issued → reconcile by id; stay blocked unless the pump authoritatively resolves it.
            if !entry.sentToPump {
                remoteBolusLedger.settle(
                    peerId: entry.peerId, requestId: entry.requestId,
                    status: RemoteCommand.Status.failed.rawValue,
                    message: "Interrupted before the pump accepted it — not delivered.",
                    deliveredUnits: 0)
                // The dedupe key is minted by `RemoteBolusLedger.reconciliationDedupeKey` (byte-identical
                // to the literal that used to be inline here) so this dynamic per-delivery family has one
                // constructor and a matching recognizer — which is what nothing could enumerate before,
                // and therefore what nothing ever withdrew. Emitted immediately AFTER `settle(…)` above:
                // this record always describes an already-terminal delivery, which is the fact
                // `NotificationBroker.shouldReplayPersistedAlert` and the one-time purge both rely on.
                postSafety(
                    .bolusReconciliation, .warning, "Bolus not delivered",
                    "A bolus that was interrupted never reached the pump (0 U). Re-enter it if you still need it.",
                    RemoteBolusLedger.reconciliationDedupeKey(peerId: entry.peerId, requestId: entry.requestId))
                recordReconciliation(.notDelivered)
                changed = true
                continue
            }
            guard let bolusId = entry.bolusId else { continue }  // sent but no id (rare) → stay blocked
            // Scope reconciliation to the pump that wrote the entry: a nil key is GRANDFATHERED
            // (identity unknown, not a mismatch — settle as today, note it in the record); a DIFFERENT
            // key is refused — never search THIS pump's history for an id another pump minted.
            // `computeDeliveryBlockReason()` already surfaces the durable mismatch reason, so this just
            // avoids the pointless per-reconnect history search.
            let pumpKeyComparison = RemoteBolusLedger.comparePumpKey(entry.pumpKey, to: currentPumpIdentity())
            if pumpKeyComparison == .mismatch {
                recordReconciliation(.unavailable)
                continue
            }
            switch await reconcile(bolusId) {
            case .resolved(let delivered, let cancelled):
                remoteBolusLedger.settle(
                    peerId: entry.peerId, requestId: entry.requestId,
                    status: (cancelled ? RemoteCommand.Status.cancelled : .delivered).rawValue,
                    message: pumpKeyComparison == .grandfathered
                        ? "Reconciled from pump history. Pump identity unknown for this entry."
                        : "Reconciled from pump history.",
                    deliveredUnits: delivered)
                let f = formatUnits(delivered)
                // Same key constructor, and again emitted immediately AFTER `settle(…)` — see the note on
                // the not-delivered post above.
                postSafety(
                    .bolusReconciliation,
                    .info,
                    cancelled ? "Bolus cancelled" : "Bolus delivered",
                    cancelled
                        ? "Reconciled from the pump: \(f) U delivered before it was cancelled."
                        : "Reconciled from the pump: \(f) U delivered.",
                    RemoteBolusLedger.reconciliationDedupeKey(peerId: entry.peerId, requestId: entry.requestId))
                recordReconciliation(cancelled ? .cancelled : .delivered)
                changed = true
            case .unavailable:
                // Stay blocked; retry on next reconnect / manual verification.
                recordReconciliation(.unavailable)  // stayed unresolved
            }
        }
        // Release the block only once the settled ledger is durably saved.
        if changed { persistTerminalOrBlock() }
        refreshDeliveryBlock()
        refresh()
    }

    /// While an unresolved entry still exists AND the link is STILL connected, arm one more bounded
    /// retry through the SAME `reconcileUnresolvedDeliveries()` funnel above — never a second search
    /// body. Trigger on the unresolved-entries predicate + a LIVE connection read, never on
    /// `computeDeliveryBlockReason()`, which is also non-nil for a missing store, an unreadable
    /// ledger, or a failed terminal save — none of which a history search can fix, and none of which
    /// leave an entry in `unreconciled()` to begin with. Past the hard cap, this stays a no-op until
    /// the next non-periodic call resets `periodicReconcileAttempts` above.
    private func scheduleNextPeriodicReconcileIfNeeded() {
        guard !remoteBolusLedger.unreconciled().isEmpty,
            currentConnection() == .connected,
            periodicReconcileAttempts < Self.periodicReconcileMaxAttempts
        else {
            periodicReconcileTask?.cancel()
            periodicReconcileTask = nil
            return
        }
        periodicReconcileAttempts += 1
        let interval = periodicReconcileIntervalOverride ?? Self.periodicReconcileInterval
        periodicReconcileTask?.cancel()
        periodicReconcileTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, interval) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            #if DEBUG
            self?.periodicReconcileCallCountForTesting += 1
            #endif
            await self?.reconcileUnresolvedDeliveries(viaPeriodicRetry: true)
        }
    }
}
