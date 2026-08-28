import Foundation

/// The durable-persistence seam the host depends on, so the round-3 §5 fault matrix can inject a store
/// that fails on demand (save throws at a specific transition, load reports corrupt, etc.) without
/// touching the filesystem. Production uses `RemoteBolusLedgerStore`; tests use a scripted fake.
/// Kept deliberately small — the three operations the host actually calls.
public protocol RemoteBolusLedgerPersisting: AnyObject {
    func loadOutcome() -> RemoteBolusLedgerStore.LoadOutcome
    func save(_ ledger: RemoteBolusLedger) throws
    func saveBestEffort(_ ledger: RemoteBolusLedger)
}

/// File-backed persistence for `RemoteBolusLedger` (FB-03). The host loads once at launch and saves after
/// every state transition — crucially, right after `markDelivering` and BEFORE the first pump write — so
/// exactly-once survives a crash or relaunch mid-delivery.
///
/// Writes are atomic (`Data.write(options: .atomic)`), so a crash mid-save can't leave a truncated ledger.
/// A missing or corrupt file loads as an empty ledger (fail-safe: an unreadable ledger must not crash the
/// app nor silently permit a retry of a request it can't see — callers still gate on the pump before any
/// new delivery). Backing it in the App Group container lets widgets/extensions share one ledger.
public final class RemoteBolusLedgerStore: RemoteBolusLedgerPersisting {
    private let url: URL
    private let cap: Int

    public init(url: URL, cap: Int = 256) {
        self.url = url
        self.cap = cap
    }

    /// F1 (§13) — the at-rest data-protection class the durable ledger is written with:
    /// `completeUntilFirstUserAuthentication` ("after first unlock"). The file is encrypted at rest but
    /// stays **readable at a locked background relaunch**, so crash-recovery / reconciliation of an
    /// in-flight delivery still works. This is the LOAD-BEARING safety choice: it is deliberately NOT
    /// `.completeFileProtection` (which locks the file whenever the device locks) — that class would make
    /// the ledger unreadable during a locked background relaunch and break reconciliation of a delivery
    /// that was in flight. Exposed so a test can pin AfterFirstUnlock and assert it is never `.complete`.
    public static let fileProtection: Data.WritingOptions = .completeFileProtectionUntilFirstUserAuthentication

    /// Convenience: a ledger file inside an App Group container (shared with widgets), else Application
    /// Support. Returns nil only if no usable directory exists.
    public static func defaultURL(appGroupID: String?) -> URL? {
        let fm = FileManager.default
        let dir: URL?
        if let appGroupID, let g = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            dir = g
        } else {
            dir = try? fm.url(
                for: .applicationSupportDirectory, in: .userDomainMask,
                appropriateFor: nil, create: true)
        }
        return dir?.appendingPathComponent("remote-bolus-ledger.json")
    }

    /// Load the persisted ledger, or a fresh empty one if absent/corrupt (legacy convenience; prefer
    /// `loadOutcome()` which distinguishes a never-initialized store from a corrupt one so callers can
    /// fail closed on corruption — P0).
    public func load() -> RemoteBolusLedger { loadOutcome().ledger }

    /// The result of a load that separates "no store yet" (safe empty) from "store existed but is
    /// unreadable/corrupt" (must fail closed — an unreadable ledger may be hiding an unresolved delivery,
    /// so the host must block all delivery until the user verifies on the pump). P0 invariant #9.
    public struct LoadOutcome: Sendable {
        public let ledger: RemoteBolusLedger
        /// True when a persisted file exists but could not be read/decoded. The returned `ledger` is empty
        /// (so idempotency still functions) but the host MUST treat this as a global delivery block.
        public let failedClosed: Bool
        /// Public so a test double conforming to `RemoteBolusLedgerPersisting` can construct outcomes
        /// (the §5 fault matrix). Production builds these inside `loadOutcome()` above.
        public init(ledger: RemoteBolusLedger, failedClosed: Bool) {
            self.ledger = ledger
            self.failedClosed = failedClosed
        }
    }

    /// Load the ledger, reporting whether a corrupt/unreadable existing store forced a fail-closed empty.
    public func loadOutcome() -> LoadOutcome {
        // No file yet ⇒ genuinely fresh install / first run ⇒ safe empty ledger, delivery allowed.
        guard FileManager.default.fileExists(atPath: url.path) else {
            return LoadOutcome(ledger: RemoteBolusLedger(cap: cap), failedClosed: false)
        }
        // File exists but won't read/decode ⇒ it may be masking an unresolved delivery ⇒ FAIL CLOSED.
        // Do NOT silently convert corruption into an empty, delivery-enabled ledger.
        guard let data = try? Data(contentsOf: url),
            let ledger = try? JSONDecoder().decode(RemoteBolusLedger.self, from: data)
        else {
            return LoadOutcome(ledger: RemoteBolusLedger(cap: cap), failedClosed: true)
        }
        return LoadOutcome(ledger: ledger, failedClosed: false)
    }

    /// Atomically persist the ledger. Throwing is surfaced so the caller can decide (a delivery MUST NOT
    /// proceed if its intent couldn't be recorded — see the host's use).
    public func save(_ ledger: RemoteBolusLedger) throws {
        let data = try JSONEncoder().encode(ledger)
        // F1 (§13): atomic + AfterFirstUnlock at-rest protection. NEVER `.completeFileProtection` — the
        // ledger must be readable at a locked background relaunch for crash-recovery (see `fileProtection`).
        try data.write(to: url, options: [.atomic, Self.fileProtection])
    }

    /// Best-effort save that never throws (for the settle/echo paths where the write already happened and
    /// losing the terminal record only risks a redundant reconcile, not a double dose).
    public func saveBestEffort(_ ledger: RemoteBolusLedger) {
        try? save(ledger)
    }
}
