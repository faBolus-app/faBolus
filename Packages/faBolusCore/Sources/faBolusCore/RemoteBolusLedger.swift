import Foundation

/// A bounded, **durable** idempotency ledger so a duplicated or retried remote bolus command cannot cause
/// a second delivery (audit A-02 / FB-03). Remote transports (Watch, Garmin, sealed peers) can redeliver a
/// message on reconnect/retry, and the sealed-transport replay counter resets on every new session — so
/// dedup must live above the transport, keyed by authenticated peer identity + the command's `requestId`.
///
/// FB-03 makes the ledger survive process restart: entries carry an explicit lifecycle
/// `State` (`awaiting` → `delivering` → `indeterminate`/`terminal`) and the whole ledger is `Codable`, so a
/// host persists it (atomically, BEFORE the first pump write) via `RemoteBolusLedgerStore` and restores it
/// at launch. A relaunch that finds a `delivering`/`indeterminate` entry still blocks a retry of that
/// request until its outcome is reconciled against the pump.
///
/// Usage (on the `@MainActor` host): `begin` synchronously right before delivering; only `.proceed` may
/// deliver. `markDelivering` immediately before the first pump write (persist here — the durable point).
/// On a lost/unknown outcome `markIndeterminate` (FB-02); on a known outcome `settle`. A later duplicate
/// then gets `.duplicateInFlight` (still working / unknown) or `.replay` (terminal), never a second dose.
public struct RemoteBolusLedger: Codable, Sendable {

    /// Lifecycle of a tracked request. Anything not `terminal` blocks a re-delivery of the same id.
    public enum State: String, Codable, Sendable {
        case awaiting  // begun, not yet written to the pump
        case delivering  // written to the pump; outcome not yet known
        case indeterminate  // outcome unknown (timeout/disconnect after the initiate write — FB-02)
        case terminal  // known outcome recorded
    }

    public enum Decision: Sendable, Equatable {
        /// New request — the caller should deliver, then `settle`.
        case proceed
        /// Same (peer, requestId) is currently delivering or indeterminate — do NOT deliver again.
        case duplicateInFlight
        /// Same (peer, requestId) already reached a terminal outcome — replay it, do NOT deliver.
        case replay(status: String, message: String?, deliveredUnits: Double?)
        /// Same requestId reused with *different* dose parameters — fail closed (do NOT deliver).
        case conflict
    }

    private struct Entry: Codable {
        var doseKey: String
        var state: State
        var terminalStatus: String?
        var terminalMessage: String?
        var deliveredUnits: Double?
        /// The pump-assigned bolus id, once known — used to reconcile an indeterminate outcome.
        var bolusId: Int?
        /// Round-3 §5: an EXPLICIT phase flag — true once the pump has granted permission and the id was
        /// durably recorded, i.e. the initiate write is imminent/issued. Reconciliation must NOT infer
        /// "not sent" merely from a missing bolus id; a nonterminal record with `sentToPump == true` stays
        /// globally blocked (reconcile by id), while `false` proves pre-initiate (safe to auto-clear).
        var sentToPump: Bool = false
        /// Addendum B (Option B): DURABLE provenance — true iff this dose's correction basis was the host's
        /// OWN acknowledged stale CGM reading (the include-stale path). A pure audit sidecar: it is NOT part
        /// of `doseKey`, never influences the conflict/replay/in-flight decision, and defaults false on a
        /// carbs-only or fresh-reading dose (and on any ledger persisted before this field existed).
        var usedIncludedStaleBG: Bool = false

        init(doseKey: String, state: State, usedIncludedStaleBG: Bool = false) {
            self.doseKey = doseKey
            self.state = state
            self.usedIncludedStaleBG = usedIncludedStaleBG
        }
        // Tolerant decode so a ledger persisted before `sentToPump`/`usedIncludedStaleBG` existed still
        // loads (both default false).
        private enum K: String, CodingKey {
            case doseKey, state, terminalStatus, terminalMessage, deliveredUnits, bolusId, sentToPump,
                usedIncludedStaleBG
        }
        init(from d: Decoder) throws {
            let c = try d.container(keyedBy: K.self)
            doseKey = try c.decode(String.self, forKey: .doseKey)
            state = try c.decode(State.self, forKey: .state)
            terminalStatus = try c.decodeIfPresent(String.self, forKey: .terminalStatus)
            terminalMessage = try c.decodeIfPresent(String.self, forKey: .terminalMessage)
            deliveredUnits = try c.decodeIfPresent(Double.self, forKey: .deliveredUnits)
            bolusId = try c.decodeIfPresent(Int.self, forKey: .bolusId)
            sentToPump = try c.decodeIfPresent(Bool.self, forKey: .sentToPump) ?? false
            usedIncludedStaleBG = try c.decodeIfPresent(Bool.self, forKey: .usedIncludedStaleBG) ?? false
        }
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let cap: Int

    /// An ADDITIVE content+time duplicate-recency index —
    /// `[peerId+doseKey: Date]` mapping a PEER's dose-content fingerprint to the most recent time an
    /// outcome for it became authoritatively delivered-or-maybe-delivered (see `settle`/
    /// `markIndeterminate`). LoopKit's `syncIdentifier` content-identity philosophy layered ON TOP of the
    /// existing `(peer,requestId)` exactly-once key: `begin()` NEVER reads this map and this map NEVER
    /// influences `.conflict`/`.replay`/`.duplicateInFlight`. Callers (e.g. `AppModel.remoteDeliver`)
    /// consult `hasRecentlyDeliveredDuplicate(peerId:doseKey:)` SEPARATELY, BEFORE calling `begin()`, so a
    /// re-composed dose under a FRESH requestId is caught independent of the exactly-once key.
    ///
    /// Scoped PER PEER (not global): the hazard this closes is a settled-echo-loss RETRY — the SAME
    /// remote actor recomposing its own just-settled request under a new id because it never saw the
    /// terminal echo — not a coincidental content match from an unrelated actor (e.g. the phone's own
    /// separate local dose happening to use the same units). Still transport/session-independent within
    /// that peer (a peer's authenticated identity survives a BLE reconnect / sealed-transport session
    /// reset, unlike its requestId), matching CONTEXT.md's "protects all remotes" framing.
    ///
    /// Deliberately NOT part of `CodingKeys` (in-process only, not persisted): the (peer,requestId)
    /// ledger remains the sole durable-across-restart defense; this recency map only needs to survive the
    /// seconds-scale window while the app process is alive.
    private var recentAuthoritativeDeliveries: [String: Date] = [:]

    /// Composite key for `recentAuthoritativeDeliveries` — same separator convention as `key(_:_:)`.
    private func recencyKey(_ peerId: String, _ doseKey: String) -> String { peerId + "\u{1F}" + doseKey }

    // Codable: persist entries + order + cap (the maps use the composite key string).
    private enum CodingKeys: String, CodingKey { case entries, order, cap }

    /// - Parameter cap: max retained requests (LRU-evicted). Default comfortably covers the
    ///   reconnect/relaunch window of every transport.
    public init(cap: Int = 256) { self.cap = max(1, cap) }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        entries = try c.decodeIfPresent([String: Entry].self, forKey: .entries) ?? [:]
        order = try c.decodeIfPresent([String].self, forKey: .order) ?? []
        cap = max(1, try c.decodeIfPresent(Int.self, forKey: .cap) ?? 256)
    }

    private func key(_ peerId: String, _ requestId: String) -> String { peerId + "\u{1F}" + requestId }

    /// A stable fingerprint of the dose-defining request parameters, so reuse of one requestId with
    /// different parameters is caught as a `.conflict`. Round to avoid float-formatting noise.
    public static func doseKey(units: Double?, carbsGrams: Double?, bgMgdl: Int?) -> String {
        func f(_ d: Double?) -> String { d.map { String(format: "%.4f", $0) } ?? "-" }
        return "u:\(f(units))|c:\(f(carbsGrams))|bg:\(bgMgdl.map(String.init) ?? "-")"
    }

    /// The recency window for `hasRecentlyDeliveredDuplicate`. Mirrors
    /// `RemoteCommandFreshness.maxAgeSec` — both bound "how long is a remote's stale view of host state
    /// still a double-dose hazard," so keeping the two windows equal avoids reasoning about two different
    /// double-dose time bounds in the same codebase.
    public static let recentDuplicateWindowSec: TimeInterval = RemoteCommandFreshness.maxAgeSec

    /// Record intent to deliver. Returns the decision the caller must honor. `usedIncludedStaleBG` is a
    /// DURABLE provenance sidecar only (Addendum B): it is stored on a freshly-created entry but plays NO
    /// part in the decision — `doseKey`, conflict, replay, and in-flight logic are all unchanged.
    public mutating func begin(
        peerId: String, requestId: String, doseKey: String,
        usedIncludedStaleBG: Bool = false
    ) -> Decision {
        let k = key(peerId, requestId)
        if let e = entries[k] {
            if e.doseKey != doseKey { return .conflict }
            switch e.state {
            case .terminal:
                return .replay(
                    status: e.terminalStatus ?? "unknown",
                    message: e.terminalMessage, deliveredUnits: e.deliveredUnits)
            case .awaiting, .delivering, .indeterminate:
                return .duplicateInFlight
            }
        }
        entries[k] = Entry(doseKey: doseKey, state: .awaiting, usedIncludedStaleBG: usedIncludedStaleBG)
        order.append(k)
        evictIfNeeded()
        return .proceed
    }

    /// Transition to `delivering` immediately before the first pump write. This is the **durable point**:
    /// the host should persist the ledger right after this returns, so a crash mid-write still finds a
    /// `delivering` entry on relaunch and blocks a duplicate until reconciled.
    public mutating func markDelivering(peerId: String, requestId: String, bolusId: Int? = nil) {
        // A bolus id exists only because the PUMP assigned one, which means the pump was written to.
        // An id therefore implies `sentToPump`, and the two must never disagree: reconciliation keys on
        // the phase, so an id-bearing record left at `sentToPump == false` would read as "never sent"
        // and auto-clear the delivery block on a dose that may well have landed.
        mutate(peerId, requestId) {
            $0.state = .delivering
            if let bolusId {
                $0.bolusId = bolusId
                $0.sentToPump = true
            }
        }
    }

    /// Record the pump-assigned bolus id (for later reconciliation) without changing state.
    public mutating func setBolusId(peerId: String, requestId: String, bolusId: Int) {
        mutate(peerId, requestId) {
            $0.bolusId = bolusId
            $0.sentToPump = true
        }
    }

    /// Round-3 §5: the pump granted permission and assigned `bolusId` — record it AND flip the explicit
    /// `sentToPump` phase, together, so a durable save of this transition proves the initiate is
    /// imminent/issued. The host persists (throwing) right after and only proceeds to initiate on success.
    public mutating func markSent(peerId: String, requestId: String, bolusId: Int) {
        mutate(peerId, requestId) {
            $0.bolusId = bolusId
            $0.sentToPump = true
        }
    }

    /// Whether this request's initiate is imminent/issued (permission granted + id durably recorded).
    public func wasSentToPump(peerId: String, requestId: String) -> Bool {
        entries[key(peerId, requestId)]?.sentToPump ?? false
    }

    /// Mark the outcome UNKNOWN (FB-02): a timeout/disconnect after the initiate write. The request is
    /// neither retryable nor confirmed until reconciled against the pump's bolus history by `bolusId`.
    ///
    /// - Parameter now: the ambiguous (may-have-delivered) outcome fail-closes into the
    ///   content+time recency index (see `hasRecentlyDeliveredDuplicate`), stamped at `now`. Only when
    ///   this call ACTUALLY transitions the entry to `.indeterminate` (not already `.terminal`).
    public mutating func markIndeterminate(peerId: String, requestId: String, now: Date = Date()) {
        let k = key(peerId, requestId)
        guard var e = entries[k], e.state != .terminal else { return }
        e.state = .indeterminate
        entries[k] = e
        recentAuthoritativeDeliveries[recencyKey(peerId, e.doseKey)] = now
    }

    /// Record the terminal outcome for a request that `begin` returned `.proceed` for (or that was
    /// reconciled from an indeterminate state).
    ///
    /// - Parameter now: when this outcome was authoritatively delivered or MAY have been
    ///   (`sentToPump == true` OR `(deliveredUnits ?? 0) > 0`), the doseKey is stamped into the
    ///   content+time recency index at `now` (see `hasRecentlyDeliveredDuplicate`). A clean pre-pump
    ///   failure (`sentToPump == false`, 0/nil units) or a genuine 0 U cancellation before the pump write
    ///   is deliberately EXCLUDED — it must never block a legitimate retry (Addresses codex HIGH: this
    ///   method sets `.terminal` for EVERY outcome, so a naive "scan terminal entries" would wrongly flag
    ///   those too).
    public mutating func settle(
        peerId: String, requestId: String, status: String,
        message: String? = nil, deliveredUnits: Double? = nil, now: Date = Date()
    ) {
        let k = key(peerId, requestId)
        guard var e = entries[k] else { return }
        e.state = .terminal
        e.terminalStatus = status
        e.terminalMessage = message
        e.deliveredUnits = deliveredUnits
        entries[k] = e
        if e.sentToPump || (deliveredUnits ?? 0) > 0 {
            recentAuthoritativeDeliveries[recencyKey(peerId, e.doseKey)] = now
        }
    }

    /// True when `peerId`'s `doseKey` was recorded (by `settle`/
    /// `markIndeterminate`) as authoritatively delivered-or-maybe-delivered within `window` seconds of
    /// `now` — REGARDLESS of which requestId a FRESH `begin()` call for the same content would use. Scoped
    /// to `peerId` (a settled-echo-loss retry is the SAME actor recomposing its own request; see the
    /// `recentAuthoritativeDeliveries` doc comment). NEVER consulted by `begin()` itself; callers must
    /// query this SEPARATELY, before `begin()`, to close the cross-requestId gap the exactly-once key
    /// cannot see.
    public func hasRecentlyDeliveredDuplicate(
        peerId: String, doseKey: String,
        within window: TimeInterval = recentDuplicateWindowSec,
        now: Date = Date()
    ) -> Bool {
        guard let at = recentAuthoritativeDeliveries[recencyKey(peerId, doseKey)] else { return false }
        return now.timeIntervalSince(at) <= window
    }

    /// Whether ANY ledger entry already exists for this EXACT `(peerId, requestId)`, in any
    /// lifecycle state. Callers use this to skip the content+time recency guard for a genuine protocol
    /// retry of the SAME id — `begin()` already handles that case correctly via `.replay`/
    /// `.duplicateInFlight`/`.conflict`. The recency guard exists ONLY to catch a FRESH requestId reusing
    /// recently-authoritative content, never to override the exactly-once key's own handling of its id.
    public func hasExistingEntry(peerId: String, requestId: String) -> Bool {
        entries[key(peerId, requestId)] != nil
    }

    private mutating func mutate(_ peerId: String, _ requestId: String, _ body: (inout Entry) -> Void) {
        let k = key(peerId, requestId)
        guard var e = entries[k] else { return }
        body(&e)
        entries[k] = e
    }

    /// True when the request has a recorded terminal outcome (test/introspection helper).
    public func isSettled(peerId: String, requestId: String) -> Bool {
        entries[key(peerId, requestId)]?.state == .terminal
    }

    public func state(peerId: String, requestId: String) -> State? {
        entries[key(peerId, requestId)]?.state
    }

    /// Addendum B: whether this request's recorded dose used the host's acknowledged stale reading for its
    /// correction basis (durable provenance; introspection helper). False for unknown/absent requests.
    public func usedIncludedStaleBG(peerId: String, requestId: String) -> Bool {
        entries[key(peerId, requestId)]?.usedIncludedStaleBG ?? false
    }

    /// Requests that were mid-flight when the process stopped: `delivering` or `indeterminate`. The host
    /// reconciles these at launch (look up each `bolusId` in pump history) before allowing new deliveries.
    public func unreconciled() -> [(peerId: String, requestId: String, bolusId: Int?, sentToPump: Bool)] {
        order.compactMap { k in
            guard let e = entries[k] else { return nil }
            // An id always means the pump was written to (only the pump mints one), and `sentToPump`
            // decodes to `false` for a ledger written before that field existed — so treat either as sent.
            let sent = e.sentToPump || e.bolusId != nil
            // `awaiting` + sent is ALSO mid-flight: `markSent` records the pump-assigned id durably
            // while the state is still `awaiting`, immediately before the initiate write. A crash in
            // that window leaves a record that must be reconciled against pump history — skipping it
            // (as "not yet written") would clear the block on a bolus that may have been issued.
            let midFlight =
                e.state == .delivering || e.state == .indeterminate
                || (e.state == .awaiting && sent)
            guard midFlight else { return nil }
            let parts = k.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]), e.bolusId, sent)
        }
    }

    /// R2-12: the terminal outcomes recorded for `peerId`, oldest→newest, for re-echoing to a remote that may
    /// have missed them across an app restart. Read-only; does not mutate ledger state.
    public func terminalOutcomes(peerId: String) -> [(
        requestId: String, status: String, message: String?, deliveredUnits: Double?
    )] {
        order.compactMap { k in
            guard let e = entries[k], e.state == .terminal else { return nil }
            let parts = k.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, String(parts[0]) == peerId else { return nil }
            return (String(parts[1]), e.terminalStatus ?? "unknown", e.terminalMessage, e.deliveredUnits)
        }
    }

    private mutating func evictIfNeeded() {
        // Never evict a non-terminal (still-tracked) entry — only settle-able history is LRU-dropped.
        while order.count > cap {
            guard let idx = order.firstIndex(where: { entries[$0]?.state == .terminal }) else { break }
            let k = order.remove(at: idx)
            entries.removeValue(forKey: k)
        }
    }
}

public extension RemoteBolusLedger {
    /// The PURE global delivery-block precedence
    /// `noDurableStore > ledgerFailedClosed > terminalSaveFailed > unresolved`, plus the live-in-flight vs
    /// genuinely-unresolved message split. Lifted verbatim from the app-target
    /// `DeliveryLedgerCoordinator.computeDeliveryBlockReason()` so the strings have ONE source of truth
    /// with zero-`AppModel` unit coverage (see `RemoteBolusLedgerTests`). Byte-identical to the copy the
    /// 09-01 `LedgerBlockPrecedenceGuardTests` pins — this function does not change any wording.
    ///
    /// - Parameters:
    ///   - noDurableStore: Round-3 §5.8 — no durable safety-ledger location exists.
    ///   - ledgerFailedClosed: the durable ledger existed but couldn't be read (corrupt/unreadable).
    ///   - terminalSaveFailed: a terminal (or manual-clear) ledger save failed.
    ///   - unresolved: `RemoteBolusLedger.unreconciled()` — mid-flight entries the caller consulted first
    ///     (evaluating it triggers the lazy ledger load that sets `ledgerFailedClosed`, so the caller must
    ///     compute it before calling this function).
    ///   - inFlightDeliveryKey: the (peer, requestId) currently delivering in THIS process, if any.
    static func blockReason(
        noDurableStore: Bool, ledgerFailedClosed: Bool, terminalSaveFailed: Bool,
        unresolved: [(peerId: String, requestId: String, bolusId: Int?, sentToPump: Bool)],
        inFlightDeliveryKey: (peerId: String, requestId: String)?
    ) -> String? {
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
                unresolved.allSatisfy({ $0.peerId == live.peerId && $0.requestId == live.requestId })
            {
                return "A bolus is already being delivered — wait for it to finish before sending another."
            }
            return "A previous bolus outcome is unconfirmed — check the pump/t:connect before dosing again."
        }
        return nil
    }
}
