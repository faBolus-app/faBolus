import Foundation

/// P14 Slice 7 — durable persistence for the setting provenance / change-log sidecar (§2.1(3)(4)).
/// Modeled 1:1 on `RemoteBolusLedgerStore`: an injectable persisting protocol (so a test can script a
/// corrupt/failing store without the filesystem), atomic writes, an App-Group-backed default URL, and a
/// `LoadOutcome` that distinguishes a fresh install from a corrupt store.
///
/// **Fail-closed semantics differ from the delivery ledger.** For the ledger, a corrupt file must BLOCK
/// delivery. Here it must NOT block anything (provenance is disclosure, not a gate) — but it must not be
/// silently swallowed either: a corrupt store returns an EMPTY log with `failedClosed == true` so the UI
/// can surface "settings history unavailable" rather than misrepresenting every value as an unchanged
/// consensus-default. The distinction is the point of separating the two outcomes.
public protocol StoredSettingChangePersisting: AnyObject {
    func loadOutcome() -> StoredSettingChangeStore.LoadOutcome
    func save(_ log: SettingChangeLog) throws
    func saveBestEffort(_ log: SettingChangeLog)
}

public final class StoredSettingChangeStore: StoredSettingChangePersisting {
    private let url: URL
    private let cap: Int
    private let retentionSeconds: Int

    /// §2.1(4) B1(c) — audit-log retention window, applied ALONGSIDE the count `cap` (both bounds hold).
    /// 30 days: the handoff's stated one-tap-revert horizon. Pruning touches only the visible audit trail
    /// (`log`), never a key's `latest` record, so an old-but-current value stays revertible past 30 days.
    public static let defaultRetentionSeconds = 30 * 24 * 60 * 60

    public init(url: URL, cap: Int = 512, retentionSeconds: Int = StoredSettingChangeStore.defaultRetentionSeconds) {
        self.url = url
        self.cap = cap
        self.retentionSeconds = retentionSeconds
    }

    /// F1 (§13) — at-rest protection for the setting-change (provenance) sidecar. Same class as the
    /// delivery ledger, `completeUntilFirstUserAuthentication`: encrypted at rest, readable after first
    /// unlock (a background write can annotate a therapy edit while locked). Not `.completeFileProtection`.
    public static let fileProtection: Data.WritingOptions = .completeFileProtectionUntilFirstUserAuthentication

    /// A change-log file inside an App Group container (shared with extensions), else Application Support.
    public static func defaultURL(appGroupID: String?) -> URL? {
        let fm = FileManager.default
        let dir: URL?
        if let appGroupID, let g = fm.containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            dir = g
        } else {
            dir = try? fm.url(for: .applicationSupportDirectory, in: .userDomainMask,
                              appropriateFor: nil, create: true)
        }
        return dir?.appendingPathComponent("setting-change-log.json")
    }

    public struct LoadOutcome: Sendable {
        public let log: SettingChangeLog
        /// True when a persisted file exists but could not be read/decoded. The returned `log` is empty;
        /// the UI should show "settings history unavailable" rather than treat everything as unchanged.
        public let failedClosed: Bool
        public init(log: SettingChangeLog, failedClosed: Bool) {
            self.log = log; self.failedClosed = failedClosed
        }
    }

    public func load() -> SettingChangeLog { loadOutcome().log }

    /// P14 S8/§2.1(2)(3)(4): the edit-path write — load the current log, record `change` (replace the
    /// key's `latest`, append to the cap-bounded audit trail), and persist best-effort. Never throws and
    /// never blocks: provenance is disclosure, so a failed persist must not affect the therapy write it
    /// annotates. A corrupt store yields an empty log from `loadOutcome`, so a record after a corruption
    /// starts a fresh honest trail rather than mutating an unreadable one.
    public func record(_ change: StoredSettingChange) {
        var log = loadOutcome().log
        log.record(change, cap: cap)
        // B1(c): apply the retention window using THIS record's own timestamp as "now" — the store never
        // reads the wall clock (determinism), and a change is by definition recorded at its `atSeconds`.
        log.pruneExpired(retentionSeconds: retentionSeconds, nowSeconds: change.atSeconds)
        saveBestEffort(log)
    }

    /// B1(c) — persist a consensus-default BASELINE for a key (§2.1(4)) without appending to the visible
    /// audit trail (`SettingChangeLog.setBaseline`). Gives an unedited therapy value an explicit origin +
    /// a revert anchor. Best-effort + fail-open, like `record`. Callers gate on "key has no record yet"
    /// so this never overwrites a real edit or re-baselines.
    public func recordBaseline(_ change: StoredSettingChange) {
        var log = loadOutcome().log
        log.setBaseline(change)
        saveBestEffort(log)
    }

    public func loadOutcome() -> LoadOutcome {
        // No file yet ⇒ fresh install ⇒ empty log, not a failure.
        guard FileManager.default.fileExists(atPath: url.path) else {
            return LoadOutcome(log: SettingChangeLog(), failedClosed: false)
        }
        // File exists but won't read/decode, OR is a newer schema than we understand ⇒ empty + flag,
        // never a mis-decode (a newer version could re-key or re-shape records).
        guard let data = try? Data(contentsOf: url),
              let log = try? JSONDecoder().decode(SettingChangeLog.self, from: data),
              log.version <= SettingChangeLog.currentVersion else {
            return LoadOutcome(log: SettingChangeLog(), failedClosed: true)
        }
        return LoadOutcome(log: log, failedClosed: false)
    }

    /// Atomically persist the log (a crash mid-save can't leave a truncated file).
    public func save(_ log: SettingChangeLog) throws {
        let data = try JSONEncoder().encode(log)
        try data.write(to: url, options: [.atomic, Self.fileProtection])   // F1 §13: AfterFirstUnlock at rest
    }

    public func saveBestEffort(_ log: SettingChangeLog) { try? save(log) }
}
