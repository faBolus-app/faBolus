import Foundation
import faBolusCore
import UserNotifications

/// Persist-then-replay of issued safety alerts (`.pumpDisconnect` / `.cgmDataLoss` /
/// `.bolusReconciliation`), so a still-unresolved alert issued before a cold-restoration relaunch —
/// one whose live in-memory schedule (or an OS-pending request) didn't survive — is guaranteed to
/// reach the user rather than silently vanish.
///
/// Holds the FULL content `NotificationPoster.post` needs to reconstruct a `UNNotificationRequest`
/// byte-for-byte — NOT merely `{dedupeKey, issuedDate, escalationStep}` (that shape can't reconstruct
/// the alert, and an inherently-immediate alert like `.cgmDataLoss`/`.bolusReconciliation` has no
/// escalation step at all). Persisted through the same App-Group `UserDefaults` Codable idiom
/// `NotificationRuntime` already uses.
///
/// An entry is written BEFORE the OS request is submitted (`SafetyAlertPoster.post` —
/// persist-before-post). It is removed on any of three routes, and a category has exactly one of them:
/// - the underlying CONDITION resolves or is acknowledged (`NotificationCoordinator.withdraw(_:)` /
///   `withdrawAll(for:)`, BOTH of which must prune it — a category-wide withdrawal that left a durable
///   entry behind would replay it after the condition resolved);
/// - the entry ANNOUNCES an already-settled result (`bolusReconciliation`) and has been PRESENTED, so
///   there is nothing left to keep alarming about — see `NotificationBroker.shouldReplayPersistedAlert`
///   and `LifecycleState.presented`. This route is what `bolusReconciliation` lacked: its per-delivery
///   dedupe key had no fixed list to withdraw by, so the launch replay re-announced a long-settled dose
///   forever;
/// - the one-time `purgeLegacyReconciliationEntriesOnce()` migration, for records written before the
///   route above existed.
@MainActor
final class SafetyAlertStore {
    static let key = AppGroupKeys.safetyAlerts
    private let store: UserDefaults
    private(set) var entries: [String: Entry]  // keyed by dedupeKey

    /// Whether the persisted entry is a one-shot immediate post (the T0 disconnect/CGM-loss/
    /// reconciliation banner) or a delayed `DisconnectEscalation` step scheduled for a future `deadline`.
    enum Kind: String, Codable, Sendable { case immediate, delayed }

    /// Lifecycle marker. An entry whose CONDITION resolves (reconnect / CGM feed resumes) is pruned
    /// outright by `withdraw`/`withdrawAll` rather than transitioned to a terminal state, since nothing
    /// else ever needs to read a resolved entry. Modeled as an explicit enum (not inferred from mere
    /// presence in the dictionary) so the replay contract is self-documenting.
    ///
    /// `.presented` is set once the OS has accepted the request (`SafetyAlertPoster.post`, immediately
    /// after the `add(_:)` closure returns for a delivered decision). It is the ONLY positive evidence
    /// available that the wearer was actually shown the alert, and it is what retires a
    /// `bolusReconciliation` record — an announcement of an already-settled dose is finished once it has
    /// been shown, whereas a condition record keeps replaying regardless (see
    /// `NotificationBroker.shouldReplayPersistedAlert`). An entry stuck at `.issued` was persisted but
    /// never handed to the OS (a process death in that window), so it must still replay: that is exactly
    /// the case the durable log exists for.
    ///
    /// Decoding is forward-safe: a blob written before `.presented` existed contains only `"issued"`.
    enum LifecycleState: String, Codable, Sendable { case issued, presented }

    /// The full replay contract for one issued safety alert — everything
    /// `NotificationPoster.post`/`NotificationCoordinator.replayTrigger` need to reconstruct and re-post
    /// it identically.
    struct Entry: Codable, Equatable, Sendable {
        var category: NotificationBroker.Category
        var severity: NotificationBroker.Severity
        var title: String
        var body: String
        var dedupeKey: String
        /// Sanitized (`String`-only) subset of the original `[AnyHashable: Any]` userInfo — safe to
        /// persist/decode without that type's non-Codable, non-Sendable shape. Every existing safety-post
        /// call site passes `[:]` today; kept general for a future caller. See `SafetyAlertStore.sanitize`.
        var userInfo: [String: String]
        var categoryIdentifier: String
        var issuedDate: Date
        /// The absolute fire time for a `.delayed` entry (`issuedDate + stepInterval`); `nil` for
        /// `.immediate`. NEVER used to compute a 0s interval directly on replay — the coordinator always
        /// re-derives a strictly-positive interval relative to `now`, or posts immediately if elapsed.
        var deadline: Date?
        var kind: Kind
        var lifecycleState: LifecycleState
    }

    /// App-Group-backed by default, mirroring `NotificationRuntime`.
    init(store: UserDefaults? = UserDefaults(suiteName: WidgetStore.appGroup)) {
        let store = store ?? .standard
        self.store = store
        self.entries = Self.load(store)
    }

    private static func load(_ store: UserDefaults) -> [String: Entry] {
        guard let data = store.data(forKey: key),
            let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        else { return [:] }
        return decoded
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(entries) { store.set(data, forKey: Self.key) }
    }

    /// Persist `entry` (keyed by its own `dedupeKey`, replacing any prior entry with the same key) —
    /// called BEFORE the OS request is submitted so a process death between the two can never lose the
    /// alert's intent (`SafetyAlertPoster.post`).
    func record(_ entry: Entry) {
        entries[entry.dedupeKey] = entry
        persist()
    }

    /// Prune the matching durable entries by dedupe key — the durable-store counterpart to
    /// `NotificationCoordinator.withdraw(_:)`.
    func remove(dedupeKeys: [String]) {
        guard !dedupeKeys.isEmpty else { return }
        for key in dedupeKeys { entries.removeValue(forKey: key) }
        persist()
    }

    /// Category-wide prune — the durable-store counterpart to `withdrawAll(for:)`'s OS-outstanding
    /// query; matches by `category` (not a fixed dedupe-key list) so it also covers
    /// `.bolusReconciliation`'s per-attempt dynamic keys (`reconcile-<peerId>-<requestId>`).
    func removeAll(for category: NotificationBroker.Category) {
        let keys = entries.values.filter { $0.category == category }.map(\.dedupeKey)
        guard !keys.isEmpty else { return }
        for key in keys { entries.removeValue(forKey: key) }
        persist()
    }

    /// Mark an entry `.presented` — the OS accepted its request, so the wearer has been shown it. Called
    /// from `SafetyAlertPoster.post` AFTER the `add(_:)` closure returns, which keeps the
    /// persist-before-post ordering untouched (the record is written before the post; only this marker
    /// moves afterwards). A no-op for an unknown key, so a withdrawal that raced the post cannot
    /// resurrect a pruned entry.
    func markPresented(dedupeKey: String) {
        guard var entry = entries[dedupeKey], entry.lifecycleState != .presented else { return }
        entry.lifecycleState = .presented
        entries[dedupeKey] = entry
        persist()
    }

    /// Every still-unresolved persisted entry, for replay on launch.
    func unresolvedEntries() -> [Entry] { Array(entries.values) }

    // MARK: - One-time purge of the legacy reconciliation replay records

    /// Purge the `bolusReconciliation` replay records an older build left behind — **once per install**,
    /// gated by `AppGroupKeys.safetyAlertsReconciliationPurged`. Returns the keys removed (empty on every
    /// subsequent launch). Requested explicitly by the owner, whose device carries a stuck record that had
    /// been re-announced at every launch since it was written.
    ///
    /// **Predicate, stated explicitly:** remove every persisted entry whose `category` is
    /// `.bolusReconciliation`, and nothing else. Not keyed on age, not on a timer, not on the dedupe-key
    /// shape, and not on `lifecycleState` (every legacy record reads `.issued`, so that would not
    /// discriminate).
    ///
    /// **Why this cannot discard a record about a genuinely unresolved dose:**
    /// 1. A `.bolusReconciliation` post is emitted only from `reconcileUnresolvedDeliveries()`, and at
    ///    BOTH of its post sites the ledger entry has already been terminally settled by the immediately
    ///    preceding `RemoteBolusLedger.settle(…)`. There is no code path that creates one of these records
    ///    for an unresolved dose, so every record this removes describes an already-terminal delivery.
    /// 2. The dose interlock is the durable LEDGER, never this notification record. An unresolved delivery
    ///    keeps its ledger entry non-terminal, keeps the global delivery block on, is retried at every
    ///    launch and every reconnect, and posts a FRESH announcement once it settles. Removing a
    ///    notification record cannot settle a ledger entry, cannot release a block, and cannot make a dose
    ///    look resolved.
    /// 3. Scope is one category. `pumpDisconnect` / `pumpConnectionUnstable` / `urgentLowGlucose` records
    ///    — the ones that track a still-live condition — are untouched.
    ///
    /// **Accepted cost, stated:** if the purge lands on a launch where a reconciliation record had been
    /// persisted but not yet presented (a process death between the persist and the OS `add`), the wearer
    /// misses ONE informational banner about a dose that is already settled and already visible in the
    /// app. That is the price of the owner's explicit request to clear the stuck record; it is one-time
    /// and cannot recur, because from here on a record is retired by presentation instead.
    @discardableResult
    func purgeLegacyReconciliationEntriesOnce() -> [String] {
        guard !store.bool(forKey: AppGroupKeys.safetyAlertsReconciliationPurged) else { return [] }
        let keys = entries.values.filter { $0.category == .bolusReconciliation }.map(\.dedupeKey)
        // Set the flag even when there is nothing to remove: a fresh install must not keep re-checking,
        // and a later legitimate reconciliation must never be caught by this purge.
        store.set(true, forKey: AppGroupKeys.safetyAlertsReconciliationPurged)
        guard !keys.isEmpty else { return [] }
        for key in keys { entries.removeValue(forKey: key) }
        persist()
        return keys
    }

    /// Erase the durable replay log outright (for "Delete all on-device data"). Called from
    /// `NotificationRuntime.eraseStoredBlobs`, which owns the notification-runtime blobs in this App
    /// Group; before this the replay log was omitted there, so a stuck record survived a full data erase.
    ///
    /// Caveat, same as the sibling runtime blobs it is called beside: this clears the PERSISTED blob, not
    /// the in-memory `entries` of a store instance that is already alive, so a mutation later in the same
    /// process would write its cached dictionary back. It is a belt, not the load-bearing mechanism —
    /// `purgeLegacyReconciliationEntriesOnce()` and retirement-on-presentation are what actually stop a
    /// settled reconciliation re-alarming, and neither depends on an erase.
    static func eraseStoredBlob(store: UserDefaults?) {
        store?.removeObject(forKey: key)
    }

    /// Sanitize an arbitrary `[AnyHashable: Any]` userInfo dict to the Codable `[String: String]` shape
    /// this store persists — drops any key that isn't already a `String`, rather than crashing or
    /// silently corrupting the persisted blob on an unexpected type.
    static func sanitize(_ userInfo: [AnyHashable: Any]) -> [String: String] {
        var out: [String: String] = [:]
        for (k, v) in userInfo {
            guard let key = k as? String else { continue }
            out[key] = String(describing: v)
        }
        return out
    }
}

/// Wraps `NotificationPoster.post` with persist-before-post for the never-suppressible safety
/// categories: the full replay content is written to `store` BEFORE the OS `add(_:)` closure runs, so
/// a process death between persist and post can never lose the alert, and a process death AFTER
/// persist-but-before-post still leaves a durable, replayable record.
@MainActor
enum SafetyAlertPoster {
    @discardableResult
    static func post(
        _ message: NotificationBroker.Message,
        store: SafetyAlertStore,
        runtime: NotificationRuntime,
        userInfo: [AnyHashable: Any] = [:],
        categoryId: String = "",
        trigger: UNNotificationTrigger? = nil,
        deadline: Date? = nil,
        now: Date = Date(),
        rules: NotificationRules.Cascade? = nil,
        timeSensitiveAvailable: Bool = false,
        add: (UNNotificationRequest) -> Void = { UNUserNotificationCenter.current().add($0) }
    ) -> NotificationBroker.Decision {
        let entry = SafetyAlertStore.Entry(
            category: message.category, severity: message.severity, title: message.title,
            body: message.body, dedupeKey: message.dedupeKey,
            userInfo: SafetyAlertStore.sanitize(userInfo), categoryIdentifier: categoryId,
            issuedDate: now, deadline: deadline, kind: deadline == nil ? .immediate : .delayed,
            lifecycleState: .issued)
        store.record(entry)  // persist BEFORE post — never the reverse order
        let decision = NotificationPoster.post(
            message, runtime: runtime, userInfo: userInfo, categoryId: categoryId,
            trigger: trigger, now: now,
            rules: rules, timeSensitiveAvailable: timeSensitiveAvailable, add: add)
        // The OS has the request: mark it presented. This is what lets an announcement of an
        // already-settled dose (`Category.announcesSettledResult`) be retired instead of replayed at
        // every launch forever, and it is deliberately AFTER the post, so an entry stuck at `.issued`
        // still means "persisted but never handed to the OS" and still replays.
        if decision.deliver { store.markPresented(dedupeKey: message.dedupeKey) }
        return decision
    }
}
