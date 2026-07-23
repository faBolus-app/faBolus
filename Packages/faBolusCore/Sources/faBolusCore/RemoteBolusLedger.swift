import Foundation

/// A bounded idempotency ledger so a duplicated or retried remote bolus command cannot cause a second
/// delivery (audit A-02). Remote transports (Watch, Garmin, sealed peers) can redeliver a message on
/// reconnect/retry, and the sealed-transport replay counter resets on every new session — so dedup must
/// live above the transport, keyed by authenticated peer identity + the command's `requestId`.
///
/// Usage (on the `@MainActor` host): call `begin` synchronously right before delivering; only `.proceed`
/// may deliver. Because `begin` is synchronous it marks the request in-flight before the delivery's
/// first `await`, so a concurrent duplicate observes `.duplicateInFlight`. After the delivery settles
/// (success, failure, or rejection) call `settle` to record the terminal outcome; a later duplicate then
/// gets `.replay` and the prior status is re-echoed without touching the pump.
public struct RemoteBolusLedger: Sendable {

    public enum Decision: Sendable, Equatable {
        /// New request — the caller should deliver, then `settle`.
        case proceed
        /// Same (peer, requestId) is currently delivering — do NOT deliver again.
        case duplicateInFlight
        /// Same (peer, requestId) already reached a terminal outcome — replay it, do NOT deliver.
        case replay(status: String, message: String?, deliveredUnits: Double?)
        /// Same requestId reused with *different* dose parameters — fail closed (do NOT deliver).
        case conflict
    }

    private struct Entry {
        var doseKey: String
        var terminalStatus: String?
        var terminalMessage: String?
        var deliveredUnits: Double?
    }

    private var entries: [String: Entry] = [:]
    private var order: [String] = []
    private let cap: Int

    /// - Parameter cap: max retained requests (LRU-evicted). Default comfortably covers the
    ///   reconnect/relaunch window of every transport.
    public init(cap: Int = 256) { self.cap = max(1, cap) }

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
            if let s = e.terminalStatus {
                return .replay(status: s, message: e.terminalMessage, deliveredUnits: e.deliveredUnits)
            }
            return .duplicateInFlight
        }
        entries[k] = Entry(doseKey: doseKey, terminalStatus: nil, terminalMessage: nil)
        order.append(k)
        evictIfNeeded()
        return .proceed
    }

    /// Record the terminal outcome for a request that `begin` returned `.proceed` for.
    public mutating func settle(peerId: String, requestId: String, status: String,
                                message: String? = nil, deliveredUnits: Double? = nil) {
        let k = key(peerId, requestId)
        guard var e = entries[k] else { return }
        e.terminalStatus = status
        e.terminalMessage = message
        e.deliveredUnits = deliveredUnits
        entries[k] = e
    }

    /// True when the request has a recorded terminal outcome (test/introspection helper).
    public func isSettled(peerId: String, requestId: String) -> Bool {
        entries[key(peerId, requestId)]?.terminalStatus != nil
    }

    private mutating func evictIfNeeded() {
        while order.count > cap {
            let k = order.removeFirst()
            entries.removeValue(forKey: k)
        }
    }
}
