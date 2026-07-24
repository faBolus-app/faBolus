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
        case awaiting      // begun, not yet written to the pump
        case delivering    // written to the pump; outcome not yet known
        case indeterminate // outcome unknown (timeout/disconnect after the initiate write — FB-02)
        case terminal      // known outcome recorded
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
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let cap: Int

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

    /// Record intent to deliver. Returns the decision the caller must honor.
    public mutating func begin(peerId: String, requestId: String, doseKey: String) -> Decision {
        let k = key(peerId, requestId)
        if let e = entries[k] {
            if e.doseKey != doseKey { return .conflict }
            switch e.state {
            case .terminal:
                return .replay(status: e.terminalStatus ?? "unknown",
                               message: e.terminalMessage, deliveredUnits: e.deliveredUnits)
            case .awaiting, .delivering, .indeterminate:
                return .duplicateInFlight
            }
        }
        entries[k] = Entry(doseKey: doseKey, state: .awaiting)
        order.append(k)
        evictIfNeeded()
        return .proceed
    }

    /// Transition to `delivering` immediately before the first pump write. This is the **durable point**:
    /// the host should persist the ledger right after this returns, so a crash mid-write still finds a
    /// `delivering` entry on relaunch and blocks a duplicate until reconciled.
    public mutating func markDelivering(peerId: String, requestId: String, bolusId: Int? = nil) {
        mutate(peerId, requestId) { $0.state = .delivering; if let bolusId { $0.bolusId = bolusId } }
    }

    /// Record the pump-assigned bolus id (for later reconciliation) without changing state.
    public mutating func setBolusId(peerId: String, requestId: String, bolusId: Int) {
        mutate(peerId, requestId) { $0.bolusId = bolusId }
    }

    /// Mark the outcome UNKNOWN (FB-02): a timeout/disconnect after the initiate write. The request is
    /// neither retryable nor confirmed until reconciled against the pump's bolus history by `bolusId`.
    public mutating func markIndeterminate(peerId: String, requestId: String) {
        mutate(peerId, requestId) { if $0.state != .terminal { $0.state = .indeterminate } }
    }

    /// Record the terminal outcome for a request that `begin` returned `.proceed` for (or that was
    /// reconciled from an indeterminate state).
    public mutating func settle(peerId: String, requestId: String, status: String,
                                message: String? = nil, deliveredUnits: Double? = nil) {
        mutate(peerId, requestId) {
            $0.state = .terminal
            $0.terminalStatus = status
            $0.terminalMessage = message
            $0.deliveredUnits = deliveredUnits
        }
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

    /// Requests that were mid-flight when the process stopped: `delivering` or `indeterminate`. The host
    /// reconciles these at launch (look up each `bolusId` in pump history) before allowing new deliveries.
    public func unreconciled() -> [(peerId: String, requestId: String, bolusId: Int?)] {
        order.compactMap { k in
            guard let e = entries[k], e.state == .delivering || e.state == .indeterminate else { return nil }
            let parts = k.split(separator: "\u{1F}", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2 else { return nil }
            return (String(parts[0]), String(parts[1]), e.bolusId)
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
