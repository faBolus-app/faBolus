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
/// persist-before-post) and removed only when the underlying condition resolves or is acknowledged
/// (`NotificationCoordinator.withdraw(_:)` / `withdrawAll(for:)`, BOTH of which must prune it — a
/// category-wide withdrawal that left a durable entry behind would replay it after the condition
/// resolved).
@MainActor
final class SafetyAlertStore {
    static let key = AppGroupKeys.safetyAlerts
    private let store: UserDefaults
    private(set) var entries: [String: Entry]  // keyed by dedupeKey

    /// Whether the persisted entry is a one-shot immediate post (the T0 disconnect/CGM-loss/
    /// reconciliation banner) or a delayed `DisconnectEscalation` step scheduled for a future `deadline`.
    enum Kind: String, Codable, Sendable { case immediate, delayed }

    /// Lifecycle marker. `.issued` is the only state ever persisted today — an entry whose condition
    /// resolves (reconnect / CGM feed resumes / an authoritative reconciliation) is pruned outright by
    /// `withdraw`/`withdrawAll` rather than transitioned to a terminal state, since nothing else ever
    /// needs to read a resolved entry. Modeled as an explicit enum (not inferred from mere presence in
    /// the dictionary) so the replay contract is self-documenting and any future terminal state slots in
    /// without a shape change.
    enum LifecycleState: String, Codable, Sendable { case issued }

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

    /// Every still-unresolved persisted entry, for replay on launch.
    func unresolvedEntries() -> [Entry] { Array(entries.values) }

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
        allowCritical: Bool = false,
        now: Date = Date(),
        add: (UNNotificationRequest) -> Void = { UNUserNotificationCenter.current().add($0) }
    ) -> NotificationBroker.Decision {
        let entry = SafetyAlertStore.Entry(
            category: message.category, severity: message.severity, title: message.title,
            body: message.body, dedupeKey: message.dedupeKey,
            userInfo: SafetyAlertStore.sanitize(userInfo), categoryIdentifier: categoryId,
            issuedDate: now, deadline: deadline, kind: deadline == nil ? .immediate : .delayed,
            lifecycleState: .issued)
        store.record(entry)  // persist BEFORE post — never the reverse order
        return NotificationPoster.post(
            message, runtime: runtime, userInfo: userInfo, categoryId: categoryId,
            trigger: trigger, allowCritical: allowCritical, now: now, add: add)
    }
}
