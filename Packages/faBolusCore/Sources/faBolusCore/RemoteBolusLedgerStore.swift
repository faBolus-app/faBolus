import Foundation

/// File-backed persistence for `RemoteBolusLedger` (FB-03). The host loads once at launch and saves after
/// every state transition — crucially, right after `markDelivering` and BEFORE the first pump write — so
/// exactly-once survives a crash or relaunch mid-delivery.
///
/// Writes are atomic (`Data.write(options: .atomic)`), so a crash mid-save can't leave a truncated ledger.
/// A missing or corrupt file loads as an empty ledger (fail-safe: an unreadable ledger must not crash the
/// app nor silently permit a retry of a request it can't see — callers still gate on the pump before any
/// new delivery). Backing it in the App Group container lets widgets/extensions share one ledger.
public final class RemoteBolusLedgerStore {
    private let url: URL
    private let cap: Int

    public init(url: URL, cap: Int = 256) {
        self.url = url
        self.cap = cap
    }

    /// Convenience: a ledger file inside an App Group container (shared with widgets), else Application
    /// Support. Returns nil only if no usable directory exists.
    public static func defaultURL(appGroupID: String?) -> URL? {
        let fm = FileManager.default
        let dir: URL?
        if let appGroupID, let g = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            dir = g
        } else {
            dir = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
        }
        return dir?.appendingPathComponent("remote-bolus-ledger.json")
    }

    /// Load the persisted ledger, or a fresh empty one if absent/corrupt.
    public func load() -> RemoteBolusLedger {
        guard let data = try? Data(contentsOf: url),
              let ledger = try? JSONDecoder().decode(RemoteBolusLedger.self, from: data) else {
            return RemoteBolusLedger(cap: cap)
        }
        return ledger
    }

    /// Atomically persist the ledger. Throwing is surfaced so the caller can decide (a delivery MUST NOT
    /// proceed if its intent couldn't be recorded — see the host's use).
    public func save(_ ledger: RemoteBolusLedger) throws {
        let data = try JSONEncoder().encode(ledger)
        try data.write(to: url, options: .atomic)
    }

    /// Best-effort save that never throws (for the settle/echo paths where the write already happened and
    /// losing the terminal record only risks a redundant reconcile, not a double dose).
    public func saveBestEffort(_ ledger: RemoteBolusLedger) {
        try? save(ledger)
    }
}
