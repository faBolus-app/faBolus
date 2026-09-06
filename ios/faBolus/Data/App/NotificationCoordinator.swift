import Foundation
import faBolusCore
import TandemMessages
import UserNotifications
import UIKit

/// The single owner of the local-notification path.
///
/// Before this, three independent posters built `UNNotificationRequest`s directly, only one handled
/// authorization or a notification category, and none shared any governance. Now **every** notification —
/// pump alerts, the five app-own safety-set categories and remote-bolus rejections — is decided by
/// `NotificationBroker` and built in exactly one place (`NotificationPoster.post`), so per-category
/// enable, the daily budget, one-per-episode, and the unified Off/Quiet/Alert/Urgent ladder apply
/// uniformly. Safety categories resolve through that same ladder (defaulting to Alert, tunable to Off).
///
/// Three collaborators:
/// - `NotificationRuntime` holds and persists the broker's mutable `State` (+ the per-category settings
///   and budget). Backed by the **App Group** so the main app and an out-of-process App Intent share one
///   governed state. Pure enough to unit-test without a notification center.
/// - `NotificationPoster` is the one function that turns a governed `Message` into a real request — usable
///   both in-process (the coordinator) and out-of-process (an App Intent when the app isn't live).
/// - `NotificationCoordinator` owns the `UNUserNotificationCenter` plumbing: the sole delegate,
///   non-destructive category registration, the pump-alert fan-in, and the "Clear" action.

// MARK: - Runtime (persisted broker state)

@MainActor
final class NotificationRuntime {
    private let store: UserDefaults
    // Key strings live in the central `AppGroupKeys` registry — values unchanged.
    static let stateKey = AppGroupKeys.notificationBrokerState
    static let telemetryKey = AppGroupKeys.notificationBrokerTelemetry
    /// Per-category `NotificationBroker.CategorySettings` — App-Group-persisted like `state`/`telemetry`
    /// so a preference the user sets survives a relaunch and is honored by every out-of-process poster.
    static let settingsKey = AppGroupKeys.notificationBrokerSettings
    private let stateKey = NotificationRuntime.stateKey
    private let telemetryKey = NotificationRuntime.telemetryKey
    private let settingsKey = NotificationRuntime.settingsKey
    /// App-Group flag (default false, opt-in) gating telemetry accrual — App-Group-backed so the
    /// out-of-process mode-reminder intent honors the same choice the main app made.
    static let telemetryEnabledKey = AppGroupKeys.notificationTelemetryEnabled
    private(set) var state: NotificationBroker.State
    /// Per-category requested/dismissed/acted-upon counts PLUS the real accrual window start (§6 #7). A
    /// separate blob from `state` so it never affects the decision round-trip; cumulative + local-only;
    /// accrued only when opted in.
    private(set) var telemetrySnapshot: NotificationBroker.TelemetrySnapshot
    /// The per-category counts, unwrapped for the many call sites that only ever want `telemetry[key]` —
    /// unchanged shape from before the window-start field existed.
    var telemetry: [String: NotificationBroker.CategoryTelemetry] { telemetrySnapshot.perCategory }
    /// When this install's notification telemetry began accruing — `nil` until the first opted-in
    /// requested/dismissed/acted-upon event, exactly like `ConnectionTelemetry.windowStart`.
    var telemetryWindowStart: Date? { telemetrySnapshot.windowStart }
    var settings: [NotificationBroker.Category: NotificationBroker.CategorySettings]
    var budget: NotificationBroker.Budget

    /// App-Group-backed by default so every process that posts shares one governed state.
    init(
        store: UserDefaults? = UserDefaults(suiteName: WidgetStore.appGroup),
        settings: [NotificationBroker.Category: NotificationBroker.CategorySettings]? = nil,
        budget: NotificationBroker.Budget = .init()
    ) {
        let store = store ?? .standard
        self.store = store
        self.budget = budget
        // The explicit `settings:` parameter always wins (tests inject via it); otherwise load whatever is
        // persisted, filling any category the blob doesn't yet cover with its default (Pattern 2 growth).
        if let settings {
            self.settings = settings
        } else {
            self.settings = Self.loadSettings(store, NotificationRuntime.settingsKey)
        }
        if let data = store.data(forKey: stateKey),
            let decoded = try? JSONDecoder().decode(NotificationBroker.State.self, from: data)
        {
            self.state = decoded
        } else {
            self.state = .init()
        }
        self.telemetrySnapshot = Self.loadTelemetrySnapshot(store, telemetryKey)
        reencodePersistedBlobsOnce()
    }

    /// One-shot, at first construction on a given App-Group store: re-encode the persisted `state` and
    /// `settings` blobs so fields the app-own notification rewrite retired (the meal sub-budget counter,
    /// the safety-ack flag) do not linger as unread keys in JSON an older build wrote. `decode` already
    /// tolerates those extra keys, and `settings` is round-tripped through the current struct here, so no
    /// value is translated — this only rewrites what is already loaded, then marks itself done so it
    /// never runs again (owner Amendment A: no migration code).
    private func reencodePersistedBlobsOnce() {
        guard !store.bool(forKey: AppGroupKeys.notificationBrokerBlobReencoded) else { return }
        if store.data(forKey: stateKey) != nil, let data = try? JSONEncoder().encode(state) {
            store.set(data, forKey: stateKey)
        }
        if store.data(forKey: settingsKey) != nil {
            persistSettings()
        }
        store.set(true, forKey: AppGroupKeys.notificationBrokerBlobReencoded)
    }

    /// True when the user has opted into local notification telemetry (default false).
    var telemetryEnabled: Bool { store.bool(forKey: Self.telemetryEnabledKey) }

    /// Erase the persisted broker runtime state, the per-category telemetry, and the durable
    /// safety-alert REPLAY LOG from the App Group (for "Delete all on-device data"). Leaves the opt-in
    /// flag and per-category SETTINGS alone — those are preferences, not accumulated data.
    ///
    /// The replay log was omitted here originally, which is why a `bolusReconciliation` record with no
    /// pruning path survived a full "Delete all on-device data" and kept re-announcing a long-settled
    /// dose. It is accumulated data like the other two, and it is erased with them.
    static func eraseStoredBlobs(store: UserDefaults? = UserDefaults(suiteName: WidgetStore.appGroup)) {
        guard let store else { return }
        store.removeObject(forKey: stateKey)
        store.removeObject(forKey: telemetryKey)
        SafetyAlertStore.eraseStoredBlob(store: store)
    }

    /// Record a broker-approved notification REQUEST for `category` (opt-in only) — named for what it
    /// counts (a submission), not for what it cannot prove (a presentation). Called from the poster's
    /// deliver path, before the OS `add(_:)` call.
    func recordRequested(_ category: NotificationBroker.Category, now: Date = Date()) {
        bumpTelemetry(category.rawValue, now: now) { $0.requested += 1 }
    }

    /// Record the user's response to a notification (opt-in only): a system dismiss (swipe) → `dismissed`;
    /// opening it or tapping an action (CLEAR / SNOOZE / default) → `actedUpon`.
    func recordResponse(categoryRawValue raw: String, actionIdentifier: String, now: Date = Date()) {
        bumpTelemetry(raw, now: now) {
            if actionIdentifier == UNNotificationDismissActionIdentifier {
                $0.dismissed += 1
            } else {
                $0.actedUpon += 1
            }
        }
    }

    /// `now` seeds `telemetrySnapshot.windowStart` on the first mutate that finds it `nil` (a fresh opt-in,
    /// or the first event after "Delete all on-device data" erased the blob) and is left untouched on
    /// every later call — mirrors `ConnectionTelemetryStore.bump`'s window-start idiom exactly.
    private func bumpTelemetry(
        _ key: String, now: Date = Date(), _ mutate: (inout NotificationBroker.CategoryTelemetry) -> Void
    ) {
        guard telemetryEnabled else { return }
        telemetrySnapshot = Self.loadTelemetrySnapshot(store, telemetryKey)  // read-modify-write (sibling processes)
        if telemetrySnapshot.windowStart == nil { telemetrySnapshot.windowStart = now }
        var t = telemetrySnapshot.perCategory[key] ?? .init()
        mutate(&t)
        telemetrySnapshot.perCategory[key] = t
        if let data = try? JSONEncoder().encode(telemetrySnapshot) { store.set(data, forKey: telemetryKey) }
    }

    private static func loadTelemetrySnapshot(_ store: UserDefaults, _ key: String)
        -> NotificationBroker.TelemetrySnapshot
    {
        guard let data = store.data(forKey: key),
            let decoded = try? JSONDecoder().decode(NotificationBroker.TelemetrySnapshot.self, from: data)
        else { return .init() }
        return decoded
    }

    /// Load the persisted per-category settings blob (keyed by `Category.rawValue`, mirroring
    /// `loadTelemetry`), falling back to `.defaults(for:)` for every category the blob is missing (a
    /// fresh install, or a category added after the blob was first written) — every category is always
    /// present in the returned dictionary.
    private static func loadSettings(_ store: UserDefaults, _ key: String) -> [NotificationBroker.Category:
        NotificationBroker.CategorySettings]
    {
        var merged = Dictionary(
            uniqueKeysWithValues:
                NotificationBroker.Category.allCases.map { ($0, NotificationBroker.CategorySettings.defaults(for: $0)) }
        )
        guard let data = store.data(forKey: key),
            let decoded = try? JSONDecoder().decode([String: NotificationBroker.CategorySettings].self, from: data)
        else { return merged }
        for (raw, cfg) in decoded {
            guard let category = NotificationBroker.Category(rawValue: raw) else { continue }
            merged[category] = cfg
        }
        return merged
    }

    /// Mutate one category's settings and persist immediately (App-Group-backed) so a fresh
    /// `NotificationRuntime(store:)` construction — including a sibling out-of-process poster
    /// (`ModeAutomation`/the widget snooze intent) — honors it on its next `evaluate`. The UI (Plan 02)
    /// writes through this.
    func updateSettings(_ cfg: NotificationBroker.CategorySettings, for category: NotificationBroker.Category) {
        settings[category] = cfg
        persistSettings()
    }

    private func persistSettings() {
        let keyed = Dictionary(uniqueKeysWithValues: settings.map { ($0.key.rawValue, $0.value) })
        if let data = try? JSONEncoder().encode(keyed) { store.set(data, forKey: settingsKey) }
    }

    /// Run the broker on `message` at `now`, persist the advanced state, and return the decision. A
    /// pump-mirror caller supplies its resolved `rules` cascade (and the time-sensitive capability), so
    /// the broker's single governed decision point reads the ONE unified resolver for that message; every
    /// other caller omits them and keeps the pre-existing settings-driven path.
    func evaluate(
        _ message: NotificationBroker.Message, now: Date,
        rules: NotificationRules.Cascade? = nil, timeSensitiveAvailable: Bool = false
    ) -> NotificationBroker.Decision {
        // Re-read the store first: a sibling process (a mode-reminder intent) may have advanced the
        // counters since we loaded. Last-writer-wins is fine for notification governance.
        if let data = store.data(forKey: stateKey),
            let decoded = try? JSONDecoder().decode(NotificationBroker.State.self, from: data)
        {
            state = decoded
        }
        // Re-read settings ONLY when a blob actually exists, so a test (or a caller) that constructed this
        // runtime with an explicit `settings:` on an empty store is never silently clobbered back to
        // defaults — while a genuine cross-process settings edit (the UI, in another process) is honored.
        if store.data(forKey: settingsKey) != nil {
            settings = Self.loadSettings(store, settingsKey)
        }
        let decision = NotificationBroker.decide(
            message, settings: settings, state: state,
            budget: budget, now: now, rules: rules, timeSensitiveAvailable: timeSensitiveAvailable)
        state = decision.nextState
        persist()
        return decision
    }

    /// Forget an episode record so a genuine re-raise of the same key notifies again rather than being
    /// dropped as `episodeAlreadyNotified`. Called when a pump alert clears (active → gone).
    func forgetEpisode(_ episodeKey: String) {
        if state.notifiedEpisodes.remove(episodeKey) != nil { persist() }
    }

    /// Snooze a category until `until`, persisted (App-Group) so the next `evaluate` in any process honors
    /// it. Re-reads first (like `evaluate`) so a concurrent counter advance isn't clobbered.
    ///
    /// Refuses any category that `permitsSilencingAction == false` — every safety-set one, and the two
    /// unresolved-dose categories, so a "Snooze 2h" button on a notification
    /// DELIVERED by an older build (still sitting in Notification Center with the actions it was
    /// delivered with) is inert when tapped. `NotificationBroker.snooze` enforces the same rule, so
    /// nothing is written even if this guard were bypassed.
    func snooze(_ category: NotificationBroker.Category, until: Date) {
        guard category.permitsSilencingAction else { return }
        if let data = store.data(forKey: stateKey),
            let decoded = try? JSONDecoder().decode(NotificationBroker.State.self, from: data)
        {
            state = decoded
        }
        state = NotificationBroker.snooze(state, category: category, until: until)
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(state) { store.set(data, forKey: stateKey) }
    }
}

// MARK: - Poster (the ONLY UNNotificationRequest builder)

@MainActor
enum NotificationPoster {
    /// Decide `message` against `runtime`, and — only if the broker says deliver — build and enqueue the
    /// one request. `add` is injectable so tests observe posted requests without a real notification
    /// center; `now` keeps the clock explicit. Returns the decision so callers can log a suppression.
    ///
    /// `trigger` defaults to `nil` (deliver immediately), so every existing caller is unchanged. The
    /// pump-disconnect escalation ladder passes a `UNTimeIntervalNotificationTrigger` so a step is
    /// delivered by the OS at its elapsed time even while the app is suspended — a user who walked
    /// away still gets the escalation.
    @discardableResult
    static func post(
        _ message: NotificationBroker.Message,
        runtime: NotificationRuntime,
        userInfo: [AnyHashable: Any] = [:],
        categoryId: String = "",
        trigger: UNNotificationTrigger? = nil,
        now: Date = Date(),
        rules: NotificationRules.Cascade? = nil,
        timeSensitiveAvailable: Bool = false,
        add: (UNNotificationRequest) -> Void = { UNUserNotificationCenter.current().add($0) }
    ) -> NotificationBroker.Decision {
        let decision = runtime.evaluate(
            message, now: now, rules: rules, timeSensitiveAvailable: timeSensitiveAvailable)
        guard decision.deliver else { return decision }
        runtime.recordRequested(message.category, now: now)  // telemetry (opt-in; no-op otherwise)
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        // The ladder's top rung is Urgent, which maps to `.timeSensitive` — faBolus holds no Apple
        // Critical Alerts entitlement (`faBolus.entitlements` carries only `application-groups`), so
        // there is no `.critical` interruption level to request anywhere in this function (Decision 4).
        //
        // A pump-mirror message (the caller supplied a resolved `rules` cascade) takes its interruption
        // level from the ONE unified resolver's phone intent — the same decision the delivery gate read —
        // so the "how loud / does it pierce DND" answer cannot disagree with whether it was posted at all:
        //   Urgent ⇒ break through Focus/DND (`.timeSensitive`)
        //   Alert  ⇒ banner + sound, no break-through (the default level)
        //   Quiet  ⇒ passive (no sound)
        //   Off    ⇒ already suppressed by the delivery gate; never reaches here.
        // Every other (app-own) message keeps its existing path: a never-suppressible safety category
        // or a `.critical`-severity message breaks through Focus/DND; ordinary ones stay at the default.
        if let rules {
            let phone = NotificationRules.resolve(rules, timeSensitiveAvailable: timeSensitiveAvailable).phone
            switch phone {
            case .urgent:
                content.interruptionLevel = .timeSensitive
                content.sound = .default
            case .quiet:
                content.interruptionLevel = .passive
                content.sound = nil
            case .alert, .off:
                content.sound = .default
            }
        } else {
            let breakthrough = message.category.isSafetySet || message.severity == .critical
            content.sound = .default
            // Anything requiring breakthrough must break through Focus/DND, or the "time-sensitive
            // delivery" promise is false. `.timeSensitive` does that without the Critical Alerts
            // entitlement; it needs only the lightweight Time-Sensitive Notifications capability (see
            // faBolus.entitlements). Scoped to `breakthrough` so an ordinary governed/suppressible
            // message is never escalated. If the app ever lacked the Time-Sensitive capability, iOS
            // silently downgrades this to `.active` — safe, never a crash.
            if breakthrough {
                content.interruptionLevel = .timeSensitive
            }
        }
        if !categoryId.isEmpty { content.categoryIdentifier = categoryId }
        // Stamp the broker category so the delegate can route a SNOOZE action (and attribute telemetry)
        // back to the right category, for every category — not just pump alerts.
        var info = userInfo
        info["brokerCategory"] = message.category.rawValue
        content.userInfo = info
        add(UNNotificationRequest(identifier: message.dedupeKey, content: content, trigger: trigger))
        return decision
    }
}

// MARK: - Coordinator (delegate + categories + pump-alert fan-in)

@MainActor
final class NotificationCoordinator: NSObject, UNUserNotificationCenterDelegate {
    private weak var model: AppModel?
    private let center = UNUserNotificationCenter.current()
    private let runtime: NotificationRuntime
    /// Durable persist-then-replay log for issued safety alerts.
    private let safetyAlertStore: SafetyAlertStore
    /// Identity keys of pump alerts currently posted, so we don't re-evaluate an already-active alert on
    /// every refresh and can withdraw the ones that clear.
    private var postedPumpAlerts: Set<String> = []
    static let pumpAlertCategory = "PUMP_ALERT"
    /// How long a "Snooze" action suppresses a category. A fixed default (no per-category setting UI yet).
    static let snoozeSeconds: TimeInterval = 2 * 60 * 60

    init(
        model: AppModel, runtime: NotificationRuntime = NotificationRuntime(),
        safetyAlertStore: SafetyAlertStore = SafetyAlertStore()
    ) {
        self.model = model
        self.runtime = runtime
        self.safetyAlertStore = safetyAlertStore
        super.init()
        center.delegate = self
        registerCategories()
        // Also request critical-alert permission. Harmless (a no-op) when the app lacks the
        // critical-alerts entitlement — iOS itself downgrades a `.critical` notification to a normal one
        // when the app isn't entitled, so gating `NotificationPoster.post`'s content on the user's
        // `criticalAlertsEnabled` alone is correct and degrades gracefully at the OS level.
        // `.badge` so `UNUserNotificationCenter.setBadgeCount` is actually honored — without it
        // iOS silently ignores every `setBadgeCount` call, regardless of any future opt-in.
        center.requestAuthorization(options: [.alert, .sound, .criticalAlert, .badge]) { _, _ in }
        // Query the OS grant state for the honest-status UI (AlertRulesView). Uses ONLY the async
        // `notificationSettings()` API — the older completion-handler form runs its block on a background
        // queue, and a `@MainActor`-inferred closure there is the exact SIGTRAP CI's Xcode 16.4 hit at
        // launch (see `registerCategories`'s note on the same hazard). The async form resumes on the
        // calling (main) actor, so there is no background-thread/`@MainActor` mismatch.
        Task { @MainActor [weak self] in await self?.refreshGrantState() }
        NotificationCenter.default.addObserver(
            forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main
        ) { [weak self] _ in Task { @MainActor in await self?.refreshGrantState() } }
        // The broker is now the sink for the two ad-hoc posters, and the sole pump-alert subscriber.
        model.notificationSink = { [weak self] msg, userInfo, categoryId in
            self?.post(msg, userInfo: userInfo, categoryId: categoryId)
        }
        // Flush any safety alert `AppModel.postSafety` buffered before this sink existed —
        // covers both a viewless restoration launch (no `.onAppear` ever ran before now) and the ordinary
        // foreground path alike, since this line runs unconditionally at construction either way.
        model.flushPendingSafety()
        model.notificationWithdrawSink = { [weak self] keys in self?.withdraw(keys) }
        // Withdraw every OS-outstanding request for a whole CATEGORY (used when the user
        // lowers a safety category to Off on the ladder) — distinct from `withdraw(_:)`
        // above, which only knows a fixed list of dedupe keys.
        model.notificationWithdrawCategorySink = { [weak self] category in self?.withdrawAll(for: category) }
        // Schedule the pump-disconnect escalation ladder as OS-delivered notifications.
        model.notificationScheduleSink = { [weak self] steps in self?.scheduleDisconnectEscalation(steps) }
        model.addNotificationsSubscriber { [weak self] alerts in self?.syncPumpAlerts(alerts) }
        // Clean up what earlier builds left behind, BEFORE the replay below reads the store.
        //
        // 1. The one-time purge the owner asked for: the `bolusReconciliation` replay records an older
        //    build could never prune. See `purgeLegacyReconciliationEntriesOnce()` for the exact predicate
        //    and why it cannot discard a record about a genuinely unresolved dose. Idempotent (flag-gated).
        // 2. `.cgmDataLoss` is UI state only now, so nothing of that category may be left outstanding: an
        //    already-delivered banner, a staleness watchdog armed before the update (OS-pending requests
        //    survive an app update), and its durable records all go. Also idempotent — after the first
        //    launch there is nothing to find, because no `.cgmDataLoss` request is ever created again.
        //    Nothing arms a staleness watchdog any more, but `cancelStalenessWatchdog()` still runs here as
        //    legacy cleanup: an earlier build's watchdog carries the fixed watchdog key, so withdraw it by
        //    that key directly rather than relying only on the category-wide sweep.
        safetyAlertStore.purgeLegacyReconciliationEntriesOnce()
        withdrawAll(for: .cgmDataLoss)
        cancelStalenessWatchdog()
        // Replay any still-unresolved safety alert persisted from a prior launch, AFTER the sink is
        // wired + the pending-safety buffer flushed above, so a restoration launch reconstructs and
        // re-submits every not-yet-resolved entry.
        replayPersistedSafetyAlerts()
    }

    /// Query the OS grant state via the modern async API and cache it for the honest-status UI
    /// (`AlertRulesView`). Called from `init` and again on foreground so a user who flips OS notification
    /// permissions in Settings sees the status update without relaunching. `.enabled` means the entitlement
    /// is granted AND the user authorized critical alerts; any other value (`.notSupported`/`.disabled`) is
    /// treated identically by the honest-status logic (`AlertRulesView.shouldShowHonestStatus`).
    ///
    /// UI-only: this cache is NEVER read by any poster or by `NotificationBroker.decide` — it exists
    /// solely to drive `AppSettings.criticalAlertGrantActive` for display.
    private func refreshGrantState() async {
        // Swift 6 strict concurrency (CI's Xcode 16.4): `UNNotificationSettings` is non-Sendable, so
        // awaiting `notificationSettings()` directly here would send it back onto this `@MainActor` type —
        // rejected at build. Read it inside a `nonisolated` helper where the non-Sendable value never leaves
        // its own isolation region; only the `Bool` crosses back to the main actor. Behavior is identical.
        AppSettings.shared.criticalAlertGrantActive = await Self.fetchCriticalAlertGranted()
    }

    /// Read the OS critical-alert grant flag off the main actor (see `refreshGrantState`). `nonisolated` so
    /// the non-Sendable `UNNotificationSettings` stays contained; returns only the Sendable `Bool`.
    private nonisolated static func fetchCriticalAlertGranted() async -> Bool {
        let settings = await UNUserNotificationCenter.current().notificationSettings()
        #if DEBUG
        print(
            "NotificationCoordinator.refreshGrantState: criticalAlertSetting=\(settings.criticalAlertSetting.rawValue)")
        #endif
        return settings.criticalAlertSetting == .enabled
    }

    /// Remove delivered + pending notifications for these dedupe keys — used when a safety condition
    /// resolves (the pump reconnects, the CGM feed resumes), so a stale "disconnected"/"data lost" banner
    /// doesn't linger.
    func withdraw(_ dedupeKeys: [String]) {
        guard !dedupeKeys.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: dedupeKeys)
        center.removePendingNotificationRequests(withIdentifiers: dedupeKeys)
        // Also prune the durable replay log, so a resolved condition can never replay on the next launch.
        safetyAlertStore.remove(dedupeKeys: dedupeKeys)
    }

    /// Withdraw every OS-outstanding (pending OR already-delivered) notification for
    /// `category` — called when the user lowers a safety category to Off on the ladder, so the
    /// "faBolus will be quieter about this" promise is immediately true rather than
    /// only for the NEXT event (a pump-disconnect escalation step scheduled BEFORE the disable would
    /// otherwise still fire after it). Unlike `withdraw(_:)`, this doesn't need a fixed list of dedupe
    /// keys: it queries the OS directly and filters by the `brokerCategory` userInfo every request is
    /// already stamped with (`NotificationPoster.post`) — which is what makes it work uniformly for
    /// `.bolusReconciliation`, whose dedupe keys are dynamic per delivery attempt
    /// (`reconcile-<peerId>-<requestId>`, see `DeliveryLedgerCoordinator`) and have no fixed list to
    /// enumerate ahead of time. Best-effort / fire-and-forget: this is a UI-adjacent cleanup, not part of
    /// the governed decide()/post() path, so a caller never awaits it.
    func withdrawAll(for category: NotificationBroker.Category) {
        // Prune the durable replay log SYNCHRONOUSLY — the category-wide OS-outstanding query below
        // is best-effort/async, but the durable store must never be left holding an entry the caller
        // believes was just fully withdrawn.
        safetyAlertStore.removeAll(for: category)
        Task { @MainActor [center] in
            let pending = await center.pendingNotificationRequests()
            let pendingIds = Self.identifiers(for: category, in: pending)
            if !pendingIds.isEmpty { center.removePendingNotificationRequests(withIdentifiers: pendingIds) }
            let delivered = await center.deliveredNotifications()
            let deliveredIds = Self.identifiers(for: category, inDelivered: delivered)
            if !deliveredIds.isEmpty { center.removeDeliveredNotifications(withIdentifiers: deliveredIds) }
        }
    }

    /// Pure filter used by `withdrawAll(for:)` — the identifiers of `requests` stamped with `category`'s
    /// `brokerCategory` userInfo. Extracted (non-`private`) so the matching contract is directly
    /// unit-testable with plainly-constructed `UNNotificationRequest`s, without a real
    /// `UNUserNotificationCenter`.
    static func identifiers(for category: NotificationBroker.Category, in requests: [UNNotificationRequest]) -> [String]
    {
        requests.filter { ($0.content.userInfo["brokerCategory"] as? String) == category.rawValue }.map(\.identifier)
    }

    /// Same filter, for the delivered-notification shape (`UNNotification.request`) — kept separate from
    /// `identifiers(for:in:)` because `UNNotification` has no public initializer, so this half can't be
    /// driven by a plain unit test the way the pending half can.
    static func identifiers(for category: NotificationBroker.Category, inDelivered delivered: [UNNotification])
        -> [String]
    {
        identifiers(for: category, in: delivered.map(\.request))
    }

    // MARK: Posting

    @discardableResult
    func post(
        _ message: NotificationBroker.Message,
        userInfo: [AnyHashable: Any] = [:], categoryId: String = "",
        trigger: UNNotificationTrigger? = nil, deadline: Date? = nil,
        rules: NotificationRules.Cascade? = nil, timeSensitiveAvailable: Bool = false
    ) -> NotificationBroker.Decision {
        // A category that surfaces as UI state only never becomes a notification. The REFUSAL itself still
        // comes from the broker (`decide()` is the single governed decision point, and it returns
        // `.uiStateOnly` for exactly these categories — this does not re-derive the policy, it only routes
        // around the persist). What this early return buys is the SIDE EFFECT: the safety-set branch below
        // persists a durable replay record BEFORE the broker decides (the persist-before-post guarantee),
        // so reaching it would leave behind a record that nothing ever posts and nothing ever prunes —
        // the exact defect this round is fixing for `bolusReconciliation`.
        guard message.category.deliversAsNotification else {
            return runtime.evaluate(message, now: Date())
        }
        // Default a governed category to its registered id unless the caller already supplied one (pump
        // alerts pass PUMP_ALERT for their CLEAR action). Whether that registered category carries a
        // SNOOZE action is decided by `Category.permitsSilencingAction` in `registerCategories()`.
        let cat = categoryId.isEmpty ? Self.categoryIdentifier(for: message.category) : categoryId
        // Persist-before-post (for launch replay) through SafetyAlertPoster for the safety set AND —
        // PER-POST — for any reconcile/unresolved-dose post (a `reconcile-*` key): the condition-shaped
        // `.bolusIndeterminate` unresolved-dose disclosures must survive a relaunch and resolve loud
        // through the app-own ladder, WITHOUT promoting the whole `.bolusIndeterminate` category (which
        // would persist + replay the four gentle send-time `indeterminate-*` posts forever). Every other
        // category keeps the plain poster unchanged. `deadline` (the absolute fire time for a delayed
        // escalation step) is meaningful only on this branch — ignored otherwise.
        if message.category.isSafetySet || RemoteBolusLedger.isReconciliationDedupeKey(message.dedupeKey) {
            // Every safety-set category resolves its OWN cascade from the persisted app-own rules —
            // never a bare hardcoded default — the same way `syncPumpAlerts` resolves the pump-mirror
            // cascade below. A caller that already supplied `rules` wins; otherwise the app-own cascade
            // is built here, so a ladder Off (aimed or inherited from a source/global rule) suppresses.
            let cascade = rules ?? AppSettings.shared.notificationRules.cascade(for: message.category)
            return SafetyAlertPoster.post(
                message, store: safetyAlertStore, runtime: runtime, userInfo: userInfo,
                categoryId: cat, trigger: trigger, deadline: deadline, rules: cascade,
                timeSensitiveAvailable: NotificationCapability.timeSensitiveAvailable,
                add: { [center] in center.add($0) })
        }
        return NotificationPoster.post(
            message, runtime: runtime, userInfo: userInfo,
            categoryId: cat, trigger: trigger,
            rules: rules, timeSensitiveAvailable: timeSensitiveAvailable,
            add: { [center] in center.add($0) })
    }

    // MARK: Pump-disconnect escalation ladder

    /// Schedule each `DisconnectEscalation` step as an OS-delivered notification that fires at its elapsed
    /// time even while the app is suspended (`UNTimeIntervalNotificationTrigger`), in the never-suppressible
    /// `.pumpDisconnect` family with its own stable identifier. Built through the one poster so it shares
    /// the governed path; distinct ids mean the broker never coalesces steps onto each other or onto the
    /// immediate T0 banner. Cancelled by `withdraw(_:)` on reconnect (the `.clear` edge in `AppModel`).
    private func scheduleDisconnectEscalation(_ steps: [DisconnectEscalation.Step]) {
        let now = Date()
        for step in steps {
            let msg = NotificationBroker.Message(
                category: .pumpDisconnect, severity: .error,
                title: step.title, body: step.body, dedupeKey: step.id)
            // The persisted `deadline` is the absolute fire time (`now + afterSeconds`),
            // so a replay on a later launch re-derives a strictly-positive interval relative to a FRESH
            // `now`, rather than ever reusing this step's original (now stale) `afterSeconds` directly.
            post(
                msg, trigger: UNTimeIntervalNotificationTrigger(timeInterval: step.afterSeconds, repeats: false),
                deadline: now.addingTimeInterval(step.afterSeconds))
        }
    }

    // MARK: Legacy CGM-staleness watchdog cleanup

    /// Clear a pre-armed staleness watchdog left behind by an earlier build. Nothing arms one any more, but
    /// this is still load-bearing as CLEANUP: a `UNTimeIntervalNotificationTrigger` armed by a PREVIOUS
    /// build survives an app update, so without this a watchdog scheduled before the update could still fire
    /// afterwards. Withdrawing by its fixed key removes both the pending OS request and the durable replay
    /// record. Called once at launch.
    private func cancelStalenessWatchdog() {
        withdraw([StalenessWatchdog.dedupeKey])
    }

    // MARK: Persisted safety-alert replay on launch

    /// Pure decision: given a persisted entry's optional `deadline` and the current time, the trigger to
    /// use when replaying it — `nil` (immediate post) for an inherently-immediate entry (`deadline ==
    /// nil`, e.g. `.cgmDataLoss`/`.bolusReconciliation`, which have no escalation step) OR an OVERDUE
    /// delayed entry (`deadline <= now`); a strictly-positive `UNTimeIntervalNotificationTrigger`
    /// re-derived from `deadline - now` for a not-yet-due delayed step. NEVER returns a computed 0s
    /// interval — `UNTimeIntervalNotificationTrigger(timeInterval: 0, …)` is an invalid trigger.
    static func replayTrigger(deadline: Date?, now: Date) -> UNNotificationTrigger? {
        guard let deadline, deadline > now else { return nil }
        return UNTimeIntervalNotificationTrigger(timeInterval: deadline.timeIntervalSince(now), repeats: false)
    }

    /// Persist-then-replay: reconstruct + re-submit every safety-alert entry from `safetyAlertStore` that
    /// still has a job to do, so an alert issued before a cold-restoration relaunch is guaranteed to reach
    /// the user rather than silently vanish. Does NOT re-persist the entry (each is already durable) —
    /// it goes through the plain `NotificationPoster`, so `issuedDate` is never clobbered by a replay.
    ///
    /// "Plain" means it skips the persist-before-post wrapper, NOT that it is silent: a delivered replay
    /// still increments the category's `requested` telemetry counter like any other post, which is why a
    /// forever-replaying entry inflated its own count in the diagnostics export.
    ///
    /// Which entries still have a job is `NotificationBroker.shouldReplayPersistedAlert`'s decision; the
    /// ones that do not are retired here rather than re-evaluated on every future launch.
    private func replayPersistedSafetyAlerts(now: Date = Date()) {
        // `SafetyAlertPoster.post` persists the durable entry BEFORE the broker decides (the
        // persist-before-post guarantee, which must NOT be weakened for the delivered case). The one way a
        // safety-set entry is still suppressed is the user's own ladder Off for that category (aimed or an
        // inherited source rule) — in which case the entry is dead state with no natural pruning path
        // other than a condition-resolve. Opportunistically prune any entry whose replay decision comes
        // back `.ruleResolvedOff`, so a permanently-unresolved, user-lowered entry can't be
        // re-loaded/re-evaluated/re-suppressed on every launch forever. This touches only the replay path
        // — the persist-before-post ordering for the delivered case is unchanged.
        var retiredKeys: [String] = []
        for entry in safetyAlertStore.unresolvedEntries() {
            // Does this record still have a job to do? `shouldReplayPersistedAlert` is the one place that
            // answers it (see its doc comment for what counts as "resolved" and why retiring a record can
            // never lose an unresolved dose). Retired without replaying: a category that no longer
            // notifies at all, and an announcement of an already-settled dose that has already been
            // PRESENTED — which is what stopped `reconcile-<peerId>-<requestId>` re-alarming at every
            // launch forever.
            guard
                NotificationBroker.shouldReplayPersistedAlert(
                    category: entry.category, alreadyPresented: entry.lifecycleState == .presented)
            else {
                retiredKeys.append(entry.dedupeKey)
                continue
            }
            let msg = NotificationBroker.Message(
                category: entry.category, severity: entry.severity,
                title: entry.title, body: entry.body, dedupeKey: entry.dedupeKey)
            let trigger = Self.replayTrigger(deadline: entry.deadline, now: now)
            // Every persisted safety-set entry resolves its cascade here too — a replay must honor the
            // SAME resolved intent the live post used, so a category the user lowered to Off (aimed or an
            // inherited source rule) never replays anyway. The ternary stays defensive: only safety-set
            // entries are ever persisted, but a corrupt store must not build a cascade for anything else.
            let cascade =
                entry.category.isSafetySet
                ? AppSettings.shared.notificationRules.cascade(for: entry.category) : nil
            let decision = NotificationPoster.post(
                msg, runtime: runtime,
                userInfo: entry.userInfo.mapValues { $0 as Any },
                categoryId: entry.categoryIdentifier, trigger: trigger, now: now,
                rules: cascade, timeSensitiveAvailable: NotificationCapability.timeSensitiveAvailable,
                add: { [center] in center.add($0) })
            if decision.deliver, entry.category.announcesSettledResult {
                // The one guaranteed presentation the durable log exists to provide has now happened, so
                // this announcement is finished. Retired in THIS launch rather than marked and retired in
                // the next, so a settled dose is re-announced at most once.
                retiredKeys.append(entry.dedupeKey)
            }
            if !decision.deliver, decision.reason == .ruleResolvedOff || decision.reason == .categoryDisabled {
                // `.ruleResolvedOff` is a safety category the user lowered to Off (aimed or an inherited
                // source rule); `.categoryDisabled` is kept only as a defensive catch for a corrupt
                // non-safety entry. Both are a permanent, deliberate suppression with no natural
                // resolve-path, so both retire the entry rather than re-evaluating it (and never
                // re-delivering it) on every future launch forever.
                retiredKeys.append(entry.dedupeKey)
            }
        }
        safetyAlertStore.remove(dedupeKeys: retiredKeys)
    }

    /// The registered notification-category id for a broker category: `PUMP_ALERT` for pump alerts (CLEAR
    /// + SNOOZE), the raw value for every other category — INCLUDING the safety-set ones, which
    /// `ownedCategories()` now registers too (with an EMPTY action set, so they still can never be
    /// snoozed from a banner). Every category resolves to a registered identifier; none resolves to "".
    static func categoryIdentifier(for c: NotificationBroker.Category) -> String {
        c == .pumpAlert ? pumpAlertCategory : c.rawValue
    }

    // MARK: Pump-alert fan-in

    private func key(_ n: PumpAlert) -> String { "pumpalert-\(n.kind.rawValue)-\(n.id)" }

    /// Post newly-active pump alerts through the broker; withdraw the ones that have cleared. Preserves the
    /// prior identity-keyed dedupe (`postedPumpAlerts`) so re-evaluation only happens on a real transition.
    /// The former per-alarm opt-out (silence mirrored pump alarms) is subsumed by the unified cascade: a
    /// user who wants pump alarms silent on the phone sets the `deliveryStopped` group to `Off` instead.
    private func syncPumpAlerts(_ notifications: [PumpAlert]) {
        let active = Set(notifications.map(key))
        for n in notifications where !postedPumpAlerts.contains(key(n)) {
            let k = key(n)
            postedPumpAlerts.insert(k)
            // Classify this pump alert from its OWN identity (kind + bit id + the malfunction
            // discriminator — a malfunction decodes as `.alarm` with the dismissable flag false) into its
            // pump-mirror group, and resolve its phone/watch intent through the ONE unified resolver. The
            // group's fatigue-averse default sits at the category cascade level; an unnamed alert id hits
            // the resolver's fail-safe cell rather than a routine rung. This single decision drives both
            // whether the alert posts and how loud it is — no separate breakthrough predicate.
            //
            // `AppSettings.notificationRules.cascade(for:)` layers the user's persisted source/category
            // overrides (the settings-screen ladder) UNDER their own default at the cascade's global
            // level — never a bare hardcoded default — so a rung the user actually sets there takes
            // effect here, not merely in the settings screen's own display.
            let isMalfunction = !n.isDismissable
            let group = NotificationRules.pumpMirrorGroup(
                kind: n.kind, id: n.id, isMalfunction: isMalfunction)
            let cascade = AppSettings.shared.notificationRules.cascade(for: group)
            let msg = NotificationBroker.Message(
                category: .pumpAlert,
                severity: n.kind == .alarm ? .critical : .warning,
                title: n.title,
                body: n.detail.isEmpty ? "Active pump alert" : n.detail,
                dedupeKey: k)
            post(
                msg, userInfo: ["id": n.id, "kind": n.kind.rawValue], categoryId: Self.pumpAlertCategory,
                rules: cascade, timeSensitiveAvailable: NotificationCapability.timeSensitiveAvailable)
        }
        let gone = Array(postedPumpAlerts.subtracting(active))
        if !gone.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: gone)
            center.removePendingNotificationRequests(withIdentifiers: gone)
            postedPumpAlerts.subtract(gone)
            for k in gone { runtime.forgetEpisode(k) }  // a genuine re-raise should notify again
        }
    }

    // MARK: Categories

    /// Register the app's notification categories. The coordinator is now the **sole** category
    /// registrar (it folded in `PumpAlertNotifier`, the only one), so setting our complete owned set is
    /// non-destructive by construction — there is no category "added elsewhere" to preserve.
    ///
    /// Done **synchronously on the main actor**, exactly as the previously-green `PumpAlertNotifier` did.
    /// The earlier attempt used `getNotificationCategories`, whose completion runs on a background queue;
    /// capturing `self` (a `@MainActor` class) there made the closure `@MainActor`-inferred, and CI's
    /// Xcode 16.4 runtime traps when it runs off-main (a SIGTRAP at launch — the 26.6 runtime relaxes
    /// this, so it didn't reproduce locally). If a second registrar is ever added, revisit with a
    /// main-actor-hopping merge rather than reintroducing a `self`-capturing background completion.
    private func registerCategories() {
        center.setNotificationCategories(Self.ownedCategories())
    }

    /// The complete set of notification categories this app owns — extracted from `registerCategories()`
    /// as a pure function so the ACTIONS attached to each category are directly unit-testable without a
    /// real `UNUserNotificationCenter` (`UNNotificationCategory` is publicly constructible and its
    /// `actions` are publicly readable). There was previously no coverage of the registration surface at
    /// all, which is how an unresolved-dose alert shipped with a category-silencing snooze as its only
    /// button.
    static func ownedCategories() -> Set<UNNotificationCategory> {
        let clear = UNNotificationAction(
            identifier: "CLEAR", title: "Clear",
            options: [.authenticationRequired])
        let snooze = UNNotificationAction(identifier: "SNOOZE", title: "Snooze 2h", options: [])
        // Pump alerts: dismiss-on-pump (CLEAR) + snooze the category, plus `.customDismissAction` so an
        // explicit swipe-dismiss is reported back as `UNNotificationDismissActionIdentifier` (without it,
        // iOS never delivers that identifier at all, and a dismissal is structurally unrecordable). Every
        // OTHER governed (suppressible) category is registered under its raw value, and whether it
        // carries the snooze action is decided by the ONE predicate
        // `NotificationBroker.Category.permitsSilencingAction` — the same predicate the snooze write side
        // reads, so the affordance and the governance cannot disagree.
        //
        // That makes `.bolusIndeterminate` ("Bolus outcome unknown") and `.bolusDeliveryFailed` ("Bolus
        // not delivered") register with NO actions at all (owner decision 2026-08-30): a snooze was their
        // ONLY button, and neither posts at `.critical`, so the single tap available on an unresolved-dose
        // alert silenced the category for two hours. They keep a category IDENTIFIER (so the notification
        // stays attributable) but no buttons — iOS still provides its own default tap and
        // swipe-to-dismiss, so nothing became harder to act on.
        //
        // Safety-set categories are registered too, under their raw value: an EMPTY action set (no
        // actions ⇒ no visible silencing — a fired safety alert must never be snoozeable from a banner,
        // a mechanism distinct from the settings-level ladder Off) plus `.customDismissAction`, so a
        // swipe-dismiss on one of them is reportable the same way a pump alert's is, and the category
        // becomes attributable instead of resolving to no registered identifier at all.
        var cats: Set<UNNotificationCategory> = [
            UNNotificationCategory(
                identifier: Self.pumpAlertCategory, actions: [clear, snooze],
                intentIdentifiers: [], options: [.customDismissAction])
        ]
        for c in NotificationBroker.Category.allCases where !c.isSafetySet && c != .pumpAlert {
            cats.insert(
                UNNotificationCategory(
                    identifier: c.rawValue, actions: c.permitsSilencingAction ? [snooze] : [],
                    intentIdentifiers: [], options: []))
        }
        for c in NotificationBroker.Category.allCases where c.isSafetySet {
            cats.insert(
                UNNotificationCategory(
                    identifier: c.rawValue, actions: [],
                    intentIdentifiers: [], options: [.customDismissAction]))
        }
        return cats
    }

    // MARK: Delegate

    /// Apple's documented contract: the system calls this ONLY while the app is running in the
    /// foreground. It does NOT fire for a notification delivered while the app is backgrounded or not
    /// running — the majority case for this app's own safety categories, which are built precisely to
    /// reach the wearer while the app is not the thing they're looking at. A "presentation-confirmed"
    /// telemetry counter built on this callback would therefore systematically UNDER-count the
    /// deliveries that matter most, not merely approximate them — which is why `requested` stays a
    /// submission count rather than gaining a `willPresent`-derived sibling.
    nonisolated func userNotificationCenter(
        _ c: UNUserNotificationCenter, willPresent n: UNNotification,
        withCompletionHandler h: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        h([.banner, .sound])
    }

    nonisolated func userNotificationCenter(
        _ c: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
        withCompletionHandler h: @escaping () -> Void
    ) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        if action == "CLEAR", let id = info["id"] as? Int, let kind = info["kind"] as? Int {
            Task { @MainActor in await self.model?.dismissAlert(id: id, kind: kind) }
        } else if action == "SNOOZE", let raw = info["brokerCategory"] as? String,
            let cat = NotificationBroker.Category(rawValue: raw)
        {
            Task { @MainActor in self.runtime.snooze(cat, until: Date().addingTimeInterval(Self.snoozeSeconds)) }
        }
        // Telemetry (opt-in): attribute the user's response to its category — dismiss (swipe) vs acted-upon
        // (opened / CLEAR / SNOOZE). Uses the brokerCategory the poster stamps on every notification.
        if let raw = info["brokerCategory"] as? String {
            Task { @MainActor in self.runtime.recordResponse(categoryRawValue: raw, actionIdentifier: action) }
        }
        h()
    }
}

// MARK: - Safety-notification edge detection

/// Pure transition logic for the two §6 safety notifications that track a *condition* rather than a
/// one-shot event — pump-link loss and CGM-data loss. Keeping it here (not inline in `AppModel.refresh`)
/// makes the semantics — **notify once on the edge, withdraw on recovery, never fire at startup** —
/// unit-testable without driving a full refresh cycle. `.raise` → post; `.clear` → withdraw; `.none`.
enum SafetyEdge: Equatable {
    case none, raise, clear

    /// Pump link: raise when the link enters a genuinely-down / gave-up state; clear when it returns to
    /// connected. A `nil` previous state (the first observation) never raises, so a cold launch that starts
    /// disconnected isn't reported as a "drop".
    ///
    /// The kit recovers an unintended drop silently in the background — a genuine drop goes
    /// `.connected → .connecting` (the kit skips the `.disconnected` flicker; see
    /// `PumpBLEClient.didDisconnectPeripheral`) and reconnects without ever surfacing a down state. So
    /// the raise must NOT fire on the transient `.connecting` reconnect window; it fires only when the
    /// link reaches a TERMINAL down state:
    ///   • `.error` (the reconnect ladder GAVE UP → `.reconnectExhausted`). This is reached from the
    ///     recovering `.connecting`/`.scanning` state, NOT directly from a live one, so it must raise even
    ///     though the immediately-preceding state wasn't live — otherwise the drop→reconnect→exhaust path
    ///     would never alarm. This is the "escalation only at exhaustion" behavior.
    ///   • `.disconnected` reached DIRECTLY from a live link (`.connected`/`.bolusing`) — a hard / radio
    ///     powered-off / user disconnect. A merely-recovering `.connecting`/`.scanning` sliding to
    ///     `.disconnected` is the throttled auto-reconnect ladder and recovers silently (its give-up is the
    ///     `.error` case above), so it does NOT raise — this is what keeps a momentary background drop quiet.
    static func connection(prev: PumpConnectionState?, now: PumpConnectionState) -> SafetyEdge {
        guard let prev else { return .none }  // first observation (cold launch) is never a "drop"
        let prevDown = prev == .disconnected || prev == .error
        // Terminal "gave up" — always alarm unless we were already down (no re-fire on a steady down state).
        if now == .error && !prevDown { return .raise }
        // A live link dropping straight to a plain disconnect (hard / powered-off / user).
        if (prev == .connected || prev == .bolusing) && now == .disconnected { return .raise }
        if prev != .connected, now == .connected { return .clear }
        return .none
    }

    /// CGM feed: raise on fresh → not-fresh (we had readings and lost them); clear on not-fresh → fresh.
    /// Startup (not-fresh → not-fresh) never raises, so "no data yet" isn't reported as "data lost".
    static func freshness(wasFresh: Bool, isFresh: Bool) -> SafetyEdge {
        if wasFresh && !isFresh { return .raise }
        if !wasFresh && isFresh { return .clear }
        return .none
    }

    /// Generic boolean-condition edge-detector, for a safety condition (like the urgent-low
    /// alarm) whose "active" test is a plain `Bool` rather than a typed state transition — raise once on
    /// false→true, clear once on true→false, never re-fire while the condition is steady.
    static func edge(wasActive: Bool, isActive: Bool) -> SafetyEdge {
        if !wasActive && isActive { return .raise }
        if wasActive && !isActive { return .clear }
        return .none
    }
}

/// Flap-rate escalation. The reconnect loop's drops fold to `.connecting` (never `.disconnected`/
/// `.error`), so `SafetyEdge.connection` deliberately returns `.none` through them — by design, so a
/// single silent background reconnect doesn't alarm. The cost is that a STORM of them is also silent.
/// This pure detector counts the live-link → `.connecting` re-pair/re-drop cycles in a rolling window
/// and escalates ONCE (latched) when they cross a threshold, so the app can raise a user-visible,
/// NON-MUTEABLE "can't hold a connection to this pump" state instead of flapping in silence.
///
/// Pure + value-typed (mirrors `SafetyEdge`): the owner
/// (`PumpConnectionLifecycle`, which observes every kit state transition — not the sampled
/// `refresh()` tick, so it never misses a fast ~2 s cycle) feeds each flap and acts on the returned
/// decision. Unit-testable without any BLE/transport.
struct ConnectionFlapDetector: Equatable {
    /// The rolling window over which flap cycles are counted.
    static let window: TimeInterval = 120  // 2 minutes
    /// The number of flap cycles within `window` that escalates to the non-muteable state.
    static let threshold = 5

    private(set) var flapTimes: [Date] = []
    private(set) var escalated = false

    /// Record one live-link (`.connected`/`.bolusing`) → `.connecting` re-pair/re-drop flap cycle observed
    /// at `at`. Prunes the window to `[at - window, at]` FIRST, then returns `true` EXACTLY ONCE (latched
    /// via `escalated`) when the count reaches `threshold` within the window — so a sustained storm raises
    /// the alarm a single time, not on every subsequent cycle.
    ///
    /// The latch is released HERE, by the passage of time, and nowhere else on the live path: when the
    /// prune leaves the window EMPTY the link held a full `window` without a single flap, so the previous
    /// storm is over and this flap opens a fresh one. Releasing by decay rather than on the owner's
    /// reconnect is deliberate and load-bearing — a reconnect is the SECOND HALF of every flap cycle, so an
    /// owner that cleared the window on reconnect (which `markUsableAndStartPolling()` used to do) left
    /// exactly one clear between any two `recordFlap` calls, capped the count at 1 against a `threshold` of
    /// 5, and made escalation unreachable. Nothing the owner does — or forgets to do — can defeat the
    /// arithmetic now.
    mutating func recordFlap(at: Date) -> Bool {
        let cutoff = at.addingTimeInterval(-Self.window)
        flapTimes.removeAll { $0 < cutoff }
        // A full quiet window ⇒ the previous storm has fully decayed: re-arm so it can escalate again.
        if flapTimes.isEmpty { escalated = false }
        flapTimes.append(at)
        guard flapTimes.count >= Self.threshold, !escalated else { return false }
        escalated = true
        return true
    }

    /// Unconditional teardown of the window AND the latch, for an owner abandoning this link's flap history
    /// outright. Returns whether it had been escalated, so such an owner can withdraw the alarm only when
    /// there was one to withdraw. Its ONE production caller is the pump-IDENTITY-change branch of
    /// `PumpConnectionLifecycle.applyDidDiscover` — a newly discovered peripheral must not inherit the
    /// previous pump's flap history, or four stale flaps plus one fresh one would escalate against a
    /// healthy pump.
    ///
    /// **NOT the recovery path, and it must never be called from one.** Every flap cycle ENDS in a
    /// reconnect, so clearing the window there is what shipped this detector inert. A genuine recovery needs
    /// no call at all: the window (and with it the latch) decays by age in `recordFlap`, and the
    /// user-visible alert is withdrawn on the `.clear` connection edge in `RefreshEffectsCoordinator`.
    @discardableResult
    mutating func reset() -> Bool {
        let was = escalated
        flapTimes.removeAll()
        escalated = false
        return was
    }
}
