import Foundation
import faBolusCore

/// Phase 09 Wave 2, Target A (D-03): the ledger / global-block **host state machine**, extracted
/// verbatim out of `AppModel` behind the unchanged `PumpBackend` seam. Owns the durable idempotency
/// ledger + store, the 4 fail-closed flags, the in-flight delivery key, the persist/retry paths, the
/// global-block computation, and the two funnels every delivery surface goes through
/// (`runLedgeredDelivery` / `reconcileUnresolvedDeliveries`).
///
/// Depends ONLY on the existing seam (via closures `AppModel` binds to `source.reconcile` /
/// `source.lastBolusCancelled`, plus the per-call `deliver` closure `AppModel` passes to
/// `runLedgeredDelivery`) and a small set of injected side-effect hooks (`recordReconciliation`,
/// `postSafety`, `refresh`, `onDeliveryBlockChanged`) — never a whole `AppModel` back-pointer (D-04).
/// `AppModel` stays the single `@Observable` publisher of `deliveryBlockedReason`/
/// `deliveryGloballyBlocked`: this coordinator computes the reason and pushes it through
/// `onDeliveryBlockChanged`, which `AppModel` uses to mirror the value into its own stored property so
/// every existing SwiftUI observer keeps working unchanged.
///
/// D-09: this is ONE of the two independent fail-closed layers in the dosing path. It must never be
/// unified with `TandemBackend.validateDeliver`'s own local `deliveryOutcomeUnknown` block.
@MainActor
final class DeliveryLedgerCoordinator {

    // MARK: - Injected seam bindings + side-effect hooks (D-04)
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
    var postSafety: (NotificationBroker.Category, NotificationBroker.Severity, String, String, String) -> Void = { _, _, _, _, _ in }
    /// Bound to `AppModel.refresh()`.
    var refresh: () -> Void = {}
    /// Mirrors the freshly computed block reason into `AppModel`'s own `@Observable` stored property
    /// (source of the published `deliveryBlockedReason`/`deliveryGloballyBlocked`), so SwiftUI
    /// observation is unbroken (D-04).
    var onDeliveryBlockChanged: (String?) -> Void = { _ in }

    // MARK: - Ledger + store (moved verbatim from AppModel.swift :523-545)

    /// Idempotency ledger: a duplicated/retried remote bolus (same peer + requestId) cannot deliver
    /// twice (audit A-02). Keyed by authenticated peer identity + requestId; MainActor-isolated.
    /// FB-03: durable — persisted (App Group) so exactly-once survives a process restart mid-delivery.
    private let remoteBolusLedgerStore: any RemoteBolusLedgerPersisting
    private lazy var remoteBolusLedger: RemoteBolusLedger = {
        let outcome = remoteBolusLedgerStore.loadOutcome()
        if outcome.failedClosed { ledgerFailedClosed = true }
        return outcome.ledger
    }()
    /// P0: true when the durable ledger existed but couldn't be read (corrupt/unreadable). An unreadable
    /// ledger may be hiding an unresolved delivery, so while this is set ALL delivery is blocked (fail
    /// closed) until the user verifies on the pump and clears it.
    private var ledgerFailedClosed = false
    /// Round-3 §5.8: no durable safety-ledger location exists (no App Group / Application Support). Delivery
    /// must stay disabled rather than fall back to a volatile store.
    private var noDurableStore = false
    /// Round-3 §5.6/5.7: a terminal (or manual-clear) ledger save failed; keep the global block until a
    /// clean save succeeds, and retry persistence in the background.
    private var terminalSaveFailed = false
    /// P0: the ledger entry (peer, requestId) whose delivery is currently in flight, so the pump's
    /// `commitBolusId` handshake lands the assigned bolus id on the right entry. Deliveries are
    /// serialized (one at a time), so a single slot suffices.
    private var inFlightDeliveryKey: (peerId: String, requestId: String)?

    /// - Parameter ledgerStoreURL: overrides the durable idempotency-ledger file (FB-03). Tests inject a
    ///   unique temp URL so instances don't share the App Group ledger; production uses the default.
    /// - Parameter ledgerStore: injects the durable store directly (round-3 §5 fault-injection matrix —
    ///   a store that throws on a chosen save, or reports a corrupt load). Takes precedence over
    ///   `ledgerStoreURL`. Production leaves it nil. `forceNoDurableStore` exercises the §5.8
    ///   no-storage-location block, which the filesystem path can't reproduce on a normal test host.
    init(ledgerStoreURL: URL? = nil,
         ledgerStore: (any RemoteBolusLedgerPersisting)? = nil,
         forceNoDurableStore: Bool = false) {
        // Round-3 §5.8: require a DURABLE store (App Group / test override). If none exists, do NOT fall
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
                url: durableURL ?? URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("remote-bolus-ledger-unavailable.json"))
        }
    }

    /// Persist the ledger. Best-effort — for non-terminal writes (intent / indeterminate) where losing the
    /// record only risks a redundant reconcile, since the entry already blocks. Terminal transitions use
    /// `persistTerminalOrBlock()` (which keeps the block until the clean save lands).
    private func persistLedger() { remoteBolusLedgerStore.saveBestEffort(remoteBolusLedger) }

    /// Round-3 §5.6/5.7: persist a TERMINAL/clean ledger state durably; if the save fails, retain the
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
    /// synchronously so a test can drive the release-on-retry-success path (Wave 1 gap A3) without
    /// sleeping. Test scaffolding only — relocated here from `AppModel` in Wave 2 (D-03); it compiles to
    /// nothing in Release and never changes production dose/delivery/wire behavior.
    func retryTerminalPersistForTesting() { retryTerminalPersist() }
    #endif

    /// Round-3 §5: the backend's acknowledged bolus-id handshake. Records the pump-assigned id on the
    /// in-flight entry AND flips its explicit `sentToPump` phase, then saves DURABLY. Returns true only if
    /// the save succeeded — the backend must abort before writing metadata/initiate on false, so a save
    /// failure can never leave an id-less record a relaunch mistakes for "not sent."
    func commitInFlightBolusId(_ bolusId: Int) async -> Bool {
        guard let key = inFlightDeliveryKey else { return false }
        remoteBolusLedger.markSent(peerId: key.peerId, requestId: key.requestId, bolusId: bolusId)
        do { try remoteBolusLedgerStore.save(remoteBolusLedger); return true }
        catch { return false }
    }

    // MARK: - Global delivery block (P0)

    private func computeDeliveryBlockReason() -> String? {
        // Evaluate `unreconciled()` first so the lazy ledger load runs (which sets `ledgerFailedClosed`).
        let unresolved = remoteBolusLedger.unreconciled()
        if noDurableStore {
            return "Delivery is locked: no durable safety store is available on this device. Delivery stays "
                + "disabled until a storage location can be created."
        }
        if ledgerFailedClosed {
            return "Delivery is locked: the safety ledger is unreadable. Check the pump/t:connect for any "
                + "unconfirmed bolus, then clear the lock in Settings."
        }
        if terminalSaveFailed {
            return "Delivery is locked: the last bolus outcome could not be saved. Check the pump/t:connect; "
                + "delivery resumes once the safety ledger is written."
        }
        if !unresolved.isEmpty {
            // S6 — this global "one delivery at a time" block IS the cross-client mutex: it lives at this
            // funnel (not in a PumpBackend, which a second backend would not share) and rejects a
            // concurrent request BEFORE it writes the durable ledger, so two different clients requesting
            // the same (or any) dose can never double-deliver. Verified by CrossClientMutexTests.
            //
            // Message: distinguish a LIVE in-flight delivery (this process is delivering right now — a
            // concurrent request should simply wait) from a genuinely unresolved/indeterminate outcome
            // (e.g. a crash mid-delivery, found at relaunch) that needs manual pump verification. Only the
            // latter should tell the user to check the pump.
            if let live = inFlightDeliveryKey,
               unresolved.allSatisfy({ $0.peerId == live.peerId && $0.requestId == live.requestId }) {
                return "A bolus is already being delivered — wait for it to finish before sending another."
            }
            return "A previous bolus outcome is unconfirmed — check the pump/t:connect before dosing again."
        }
        return nil
    }
    /// Recompute the current block reason and push it through `onDeliveryBlockChanged` (D-04). Exposed
    /// (not `private`) so `AppModel.init` can force one SYNCHRONOUS publish of any ledger state restored
    /// from a previous run before its own `init` returns — mirroring the original `AppModel` ordering
    /// where a caller could read `deliveryBlockedReason`/`deliveryGloballyBlocked` immediately after
    /// construction, before the async `reconcileUnresolvedDeliveries()` launched at the end of `init`
    /// completes.
    func refreshDeliveryBlock() { onDeliveryBlockChanged(computeDeliveryBlockReason()) }

    /// P0 escape hatch: the user has checked the pump/t:connect and confirms there is no unconfirmed
    /// delivery. Settle every unresolved entry as verified and clear a fail-closed (corrupt-ledger) lock,
    /// writing a fresh clean ledger, so delivery can resume. Never called automatically.
    func clearDeliveryBlockAfterVerification() {
        for entry in remoteBolusLedger.unreconciled() {
            remoteBolusLedger.settle(peerId: entry.peerId, requestId: entry.requestId,
                                     status: RemoteCommand.Status.delivered.rawValue,
                                     message: "Cleared after manual verification on the pump.")
        }
        // Round-3 §5.6: only release the block once the clean ledger is durably saved.
        do {
            try remoteBolusLedgerStore.save(remoteBolusLedger)
            ledgerFailedClosed = false
            terminalSaveFailed = false
        } catch {
            terminalSaveFailed = true
        }
        refreshDeliveryBlock()
    }

    // MARK: - F1 (§13) on-device data export/erase support
    //
    // These are NOT part of the original :523-653/:2386-2507 D-03 cluster, but they read/mutate the same
    // ledger internals (moved here with everything else) — `AppModel.buildPrivacyExport` /
    // `eraseAllOnDeviceHealthData` / `maybeHandlePumpSwitch` consult them via these narrow accessors
    // instead of reaching into coordinator-private state.

    /// F1: a read-only snapshot of the ledger for the unified privacy-data export. Pure read.
    var currentLedgerSnapshot: RemoteBolusLedger { remoteBolusLedger }

    /// True while a delivery is in flight or the global block is set — used by callers (pump-switch
    /// handling) that must DEFER rather than disturb ledger/snapshot state a crash-recovery reconcile
    /// still needs. No message; see `eraseRefusalReason()` for the erase path's own worded refusal.
    var hasInFlightOrUnresolvedDelivery: Bool { inFlightDeliveryKey != nil || computeDeliveryBlockReason() != nil }

    /// F1: whether the given (peer, requestId) already reached a terminal outcome (used by
    /// `presentRemoteBolus` to ignore a duplicate/already-handled remote request).
    func isSettled(peerId: String, requestId: String) -> Bool {
        remoteBolusLedger.isSettled(peerId: peerId, requestId: requestId)
    }

    /// F1: the SAME refusal gate `eraseAllOnDeviceHealthData` enforces — never erase over an in-flight or
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

    /// F1: reset the ledger audit trail to fresh/empty, persisted durably (best-effort — the caller has
    /// already confirmed via `eraseRefusalReason()` that no unresolved entry exists to lose).
    func resetLedgerForErase() {
        remoteBolusLedger = RemoteBolusLedger()
        remoteBolusLedgerStore.saveBestEffort(remoteBolusLedger)
    }

    // MARK: - Durable delivery ledger (P0)

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
    /// a single place (P0). It (1) refuses to start while any prior sent transaction is unresolved or the
    /// ledger is unreadable, (2) records intent DURABLY before the first pump write, (3) tags the in-flight
    /// entry so the pump's assigned bolus id is persisted before initiate, and (4) settles /
    /// marks-indeterminate on outcome. `onStarted` fires only after intent is durably recorded.
    func runLedgeredDelivery(peerId: String, requestId: String, doseKey: String,
                             usedIncludedStaleBG: Bool = false,
                             onStarted: (() -> Void)? = nil,
                             deliver: () async throws -> Double) async -> DeliveryOutcome {
        // Global block: survives restart via the durable ledger; corrupt ledger fails closed.
        if let reason = computeDeliveryBlockReason() { return .blocked(reason) }

        // `usedIncludedStaleBG` is DURABLE provenance only (Addendum B): recorded on a new ledger entry,
        // never part of `doseKey` or the conflict/replay/in-flight decision.
        switch remoteBolusLedger.begin(peerId: peerId, requestId: requestId, doseKey: doseKey,
                                       usedIncludedStaleBG: usedIncludedStaleBG) {
        case .proceed: break
        case .duplicateInFlight: return .duplicateInFlight
        case .replay(let s, let m, let u): return .replay(status: s, message: m, deliveredUnits: u)
        case .conflict: return .blocked("Duplicate request id with different dose — rejected.")
        }
        defer { refreshDeliveryBlock() }
        // Durable point (FB-03): mark delivering + persist atomically BEFORE the first pump write. If the
        // intent can't be recorded, refuse to deliver (a crash after an unrecorded write could double-dose).
        remoteBolusLedger.markDelivering(peerId: peerId, requestId: requestId)
        do { try remoteBolusLedgerStore.save(remoteBolusLedger) }
        catch {
            remoteBolusLedger.settle(peerId: peerId, requestId: requestId,
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
            remoteBolusLedger.settle(peerId: peerId, requestId: requestId,
                                     status: (cancelled ? RemoteCommand.Status.cancelled : .delivered).rawValue,
                                     deliveredUnits: delivered)
            persistTerminalOrBlock()   // §5.6: keep the block until this terminal state is durably saved
            return .delivered(units: delivered, cancelled: cancelled)
        } catch let e as BolusError where e.isIndeterminate {
            // FB-02: sent but outcome unknown → leave the entry unreconciled (keeps the GLOBAL block on)
            // and tell the surface to verify. Reconciliation by bolus id clears it later.
            _ = e
            remoteBolusLedger.markIndeterminate(peerId: peerId, requestId: requestId)
            persistLedger()
            return .indeterminate
        } catch {
            remoteBolusLedger.settle(peerId: peerId, requestId: requestId,
                                     status: RemoteCommand.Status.failed.rawValue, message: error.localizedDescription)
            persistTerminalOrBlock()
            return .failed(error.localizedDescription)
        }
    }

    /// P0 — reconcile every unresolved delivery in the durable ledger against the pump, releasing the
    /// global block only for entries settled from an AUTHORITATIVE pump result. Call at launch and on
    /// every reconnect. An entry with NO pump bolus id was interrupted before the pump granted permission
    /// (so nothing could have been delivered) → safe to settle as not-delivered. An entry WITH an id is
    /// reconciled by that id; a mismatch/`.unavailable` keeps it blocked (verify on the pump).
    func reconcileUnresolvedDeliveries() async {
        let unresolved = remoteBolusLedger.unreconciled()
        guard !unresolved.isEmpty else { refreshDeliveryBlock(); return }
        var changed = false
        for entry in unresolved {
            // Round-3 §5: decide from the EXPLICIT phase, not merely a missing id. `sentToPump == false`
            // proves pre-initiate (the id was never durably recorded, so the backend aborted before the
            // initiate write) → safe to settle as not-delivered. `sentToPump == true` means the initiate is
            // imminent/issued → reconcile by id; stay blocked unless the pump authoritatively resolves it.
            if !entry.sentToPump {
                remoteBolusLedger.settle(peerId: entry.peerId, requestId: entry.requestId,
                                         status: RemoteCommand.Status.failed.rawValue,
                                         message: "Interrupted before the pump accepted it — not delivered.",
                                         deliveredUnits: 0)
                postSafety(.bolusReconciliation, .warning, "Bolus not delivered",
                           "A bolus that was interrupted never reached the pump (0 U). Re-enter it if you still need it.",
                           "reconcile-\(entry.peerId)-\(entry.requestId)")
                recordReconciliation(.notDelivered)   // §5.2.8
                changed = true
                continue
            }
            guard let bolusId = entry.bolusId else { continue }   // sent but no id (rare) → stay blocked
            switch await reconcile(bolusId) {
            case .resolved(let delivered, let cancelled):
                remoteBolusLedger.settle(peerId: entry.peerId, requestId: entry.requestId,
                                         status: (cancelled ? RemoteCommand.Status.cancelled : .delivered).rawValue,
                                         message: "Reconciled from pump history.", deliveredUnits: delivered)
                let f = formatUnits(delivered)
                postSafety(.bolusReconciliation,
                           .info,
                           cancelled ? "Bolus cancelled" : "Bolus delivered",
                           cancelled
                               ? "Reconciled from the pump: \(f) U delivered before it was cancelled."
                               : "Reconciled from the pump: \(f) U delivered.",
                           "reconcile-\(entry.peerId)-\(entry.requestId)")
                recordReconciliation(cancelled ? .cancelled : .delivered)   // §5.2.8
                changed = true
            case .unavailable:
                recordReconciliation(.unavailable)   // §5.2.8: stayed unresolved
                break   // stay blocked; retry on next reconnect / manual verification
            }
        }
        // Round-3 §5.6: release the block only once the settled ledger is durably saved.
        if changed { persistTerminalOrBlock() }
        refreshDeliveryBlock()
        refresh()
    }
}
