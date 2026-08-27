import Foundation
import faBolusCore
import TandemMessages
import UserNotifications
import UIKit

/// P9 §6 — the single owner of the local-notification path.
///
/// Before this, three independent posters built `UNNotificationRequest`s directly (`PumpAlertNotifier`,
/// `AppModel.notifyRemoteBolusRejected`, `ModeAutomation.remind`), only one handled authorization or a
/// notification category, and none shared any governance. Now **every** notification — pump alerts, the
/// three never-suppressible safety categories, remote-bolus rejections and mode reminders — is decided by
/// `NotificationBroker` and built in exactly one place (`NotificationPoster.post`), so per-category
/// enable / quiet-hours / rate-limit, the daily & meal budgets, one-per-episode, and the safety
/// guarantee (disconnect / bolus-reconciliation / CGM-loss can never be dropped) apply uniformly.
///
/// Three collaborators:
/// - `NotificationRuntime` holds and persists the broker's mutable `State` (+ the per-category settings
///   and budget). Backed by the **App Group** so the main app and an out-of-process App Intent share one
///   governed state. Pure enough to unit-test without a notification center.
/// - `NotificationPoster` is the one function that turns a governed `Message` into a real request — usable
///   both in-process (the coordinator) and out-of-process (a mode-reminder intent when the app isn't live).
/// - `NotificationCoordinator` owns the `UNUserNotificationCenter` plumbing: the sole delegate,
///   non-destructive category registration, the pump-alert fan-in, and the "Clear" action.

// MARK: - Runtime (persisted broker state)

@MainActor
final class NotificationRuntime {
    private let store: UserDefaults
    // D4-06: key strings moved to the central `AppGroupKeys` registry — values unchanged.
    static let stateKey = AppGroupKeys.notificationBrokerState
    static let telemetryKey = AppGroupKeys.notificationBrokerTelemetry
    /// Per-category `NotificationBroker.CategorySettings` (Phase 8.1) — previously in-memory-only (see
    /// RESEARCH.md Critical Correction); now App-Group-persisted like `state`/`telemetry` so a preference the
    /// user sets survives a relaunch and is honored by every out-of-process poster.
    static let settingsKey = AppGroupKeys.notificationBrokerSettings
    private let stateKey = NotificationRuntime.stateKey
    private let telemetryKey = NotificationRuntime.telemetryKey
    private let settingsKey = NotificationRuntime.settingsKey
    /// App-Group flag (default false, opt-in per N21) gating telemetry accrual — App-Group-backed so the
    /// out-of-process mode-reminder intent honors the same choice the main app made.
    static let telemetryEnabledKey = AppGroupKeys.notificationTelemetryEnabled
    private(set) var state: NotificationBroker.State
    /// Per-category delivered/dismissed/acted-upon counts (§6 #7). A separate blob from `state` so it never
    /// affects the decision round-trip; cumulative + local-only; accrued only when opted in.
    private(set) var telemetry: [String: NotificationBroker.CategoryTelemetry]
    var settings: [NotificationBroker.Category: NotificationBroker.CategorySettings]
    var budget: NotificationBroker.Budget

    /// App-Group-backed by default so every process that posts shares one governed state.
    init(store: UserDefaults? = UserDefaults(suiteName: WidgetStore.appGroup),
         settings: [NotificationBroker.Category: NotificationBroker.CategorySettings]? = nil,
         budget: NotificationBroker.Budget = .init()) {
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
           let decoded = try? JSONDecoder().decode(NotificationBroker.State.self, from: data) {
            self.state = decoded
        } else {
            self.state = .init()
        }
        self.telemetry = Self.loadTelemetry(store, telemetryKey)
    }

    /// True when the user has opted into local notification telemetry (default false).
    var telemetryEnabled: Bool { store.bool(forKey: Self.telemetryEnabledKey) }

    /// F1 (§13) — erase the persisted broker runtime state + per-category telemetry BLOBS from the App
    /// Group (for "Delete all on-device data"). Leaves the opt-in flag and per-category SETTINGS alone —
    /// those are preferences, not accumulated data.
    static func eraseStoredBlobs(store: UserDefaults? = UserDefaults(suiteName: WidgetStore.appGroup)) {
        guard let store else { return }
        store.removeObject(forKey: stateKey)
        store.removeObject(forKey: telemetryKey)
    }

    /// Record a delivered notification for `category` (opt-in only). Called from the poster's deliver path.
    func recordDelivered(_ category: NotificationBroker.Category) {
        bumpTelemetry(category.rawValue) { $0.delivered += 1 }
    }

    /// Record the user's response to a notification (opt-in only): a system dismiss (swipe) → `dismissed`;
    /// opening it or tapping an action (CLEAR / SNOOZE / default) → `actedUpon`.
    func recordResponse(categoryRawValue raw: String, actionIdentifier: String) {
        bumpTelemetry(raw) {
            if actionIdentifier == UNNotificationDismissActionIdentifier { $0.dismissed += 1 }
            else { $0.actedUpon += 1 }
        }
    }

    private func bumpTelemetry(_ key: String, _ mutate: (inout NotificationBroker.CategoryTelemetry) -> Void) {
        guard telemetryEnabled else { return }
        telemetry = Self.loadTelemetry(store, telemetryKey)   // read-modify-write (sibling processes)
        var t = telemetry[key] ?? .init()
        mutate(&t)
        telemetry[key] = t
        if let data = try? JSONEncoder().encode(telemetry) { store.set(data, forKey: telemetryKey) }
    }

    private static func loadTelemetry(_ store: UserDefaults, _ key: String) -> [String: NotificationBroker.CategoryTelemetry] {
        guard let data = store.data(forKey: key),
              let decoded = try? JSONDecoder().decode([String: NotificationBroker.CategoryTelemetry].self, from: data)
        else { return [:] }
        return decoded
    }

    /// Load the persisted per-category settings blob (keyed by `Category.rawValue`, mirroring
    /// `loadTelemetry`), falling back to `.defaults(for:)` for every category the blob is missing (a
    /// fresh install, or a category added after the blob was first written) — every category is always
    /// present in the returned dictionary.
    private static func loadSettings(_ store: UserDefaults, _ key: String) -> [NotificationBroker.Category: NotificationBroker.CategorySettings] {
        var merged = Dictionary(uniqueKeysWithValues:
            NotificationBroker.Category.allCases.map { ($0, NotificationBroker.CategorySettings.defaults(for: $0)) })
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

    /// Run the broker on `message` at `now`, persist the advanced state, and return the decision.
    func evaluate(_ message: NotificationBroker.Message, now: Date) -> NotificationBroker.Decision {
        // Re-read the store first: a sibling process (a mode-reminder intent) may have advanced the
        // counters since we loaded. Last-writer-wins is fine for notification governance.
        if let data = store.data(forKey: stateKey),
           let decoded = try? JSONDecoder().decode(NotificationBroker.State.self, from: data) {
            state = decoded
        }
        // Re-read settings ONLY when a blob actually exists, so a test (or a caller) that constructed this
        // runtime with an explicit `settings:` on an empty store is never silently clobbered back to
        // defaults — while a genuine cross-process settings edit (the UI, in another process) is honored.
        if store.data(forKey: settingsKey) != nil {
            settings = Self.loadSettings(store, settingsKey)
        }
        let decision = NotificationBroker.decide(message, settings: settings, state: state,
                                                 budget: budget, now: now)
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
    /// it. Re-reads first (like `evaluate`) so a concurrent counter advance isn't clobbered; `snooze(_:)`
    /// refuses `neverSuppressible` categories, so a safety alert can never be silenced.
    func snooze(_ category: NotificationBroker.Category, until: Date) {
        guard !category.neverSuppressible else { return }
        if let data = store.data(forKey: stateKey),
           let decoded = try? JSONDecoder().decode(NotificationBroker.State.self, from: data) {
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
    /// `trigger` defaults to `nil` (deliver immediately), so every existing caller is unchanged. S7 passes
    /// a `UNTimeIntervalNotificationTrigger` so a pump-disconnect escalation step is delivered by the OS at
    /// its elapsed time even while the app is suspended — a user who walked away still gets the escalation.
    @discardableResult
    static func post(_ message: NotificationBroker.Message,
                     runtime: NotificationRuntime,
                     userInfo: [AnyHashable: Any] = [:],
                     categoryId: String = "",
                     trigger: UNNotificationTrigger? = nil,
                     allowCritical: Bool = false,
                     now: Date = Date(),
                     add: (UNNotificationRequest) -> Void = { UNUserNotificationCenter.current().add($0) }
    ) -> NotificationBroker.Decision {
        let decision = runtime.evaluate(message, now: now)
        guard decision.deliver else { return decision }
        runtime.recordDelivered(message.category)   // telemetry (opt-in; no-op otherwise)
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        // §6/S8 B6: iOS Critical Alerts (alert even under Do Not Disturb / the ringer switch) for the
        // never-suppressible SAFETY categories only, and only when the caller says the entitlement is
        // granted + the user has it on (`allowCritical`). Everything else keeps the normal sound/level, so
        // this can never over-escalate a routine or governed notification.
        // CC-12/CX-F-08 (T-13-15): breakthrough is driven by `NotificationBroker.requiresBreakthrough` —
        // the never-suppressible trio (unchanged), OR a `.critical`-severity message (a pump ALARM
        // surfaced as the GOVERNED `.pumpAlert` category), OR a message carrying a force-protected typed
        // `safetyClass` (an urgent fixed-low/occlusion/low-insulin/CGM-loss alert at plain `.warning`
        // severity). Decoupled from `category.neverSuppressible` alone, so a governed pump alarm breaks
        // through Focus/DND exactly like the safety trio — closing the gap where alarms couldn't break
        // through DND and a fixed-low ALERT posted `.warning` (CC-12/CX-F-08).
        let breakthrough = NotificationBroker.requiresBreakthrough(message)
        if allowCritical && breakthrough {
            content.interruptionLevel = .critical
            content.sound = .defaultCritical
        } else {
            content.sound = .default
            // CR-01: graceful degradation while the Critical-Alerts entitlement is pending (or the user
            // hasn't opted in) — anything requiring breakthrough still must break through Focus/DND, or the
            // "time-sensitive delivery" promise is false. `.timeSensitive` does that without requiring the
            // special-request Critical Alerts entitlement; it only needs the lightweight Time-Sensitive
            // Notifications capability (see faBolus.entitlements). Scoped to `breakthrough` so an ordinary
            // governed/suppressible message is never escalated. If the app ever lacked the Time-Sensitive
            // capability, iOS silently downgrades this to `.active` — safe by default, never a crash.
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
    /// Phase 13-01 Task 2 (CX-F-03 depth): the durable persist-then-replay log for issued safety alerts.
    private let safetyAlertStore: SafetyAlertStore
    /// Identity keys of pump alerts currently posted, so we don't re-evaluate an already-active alert on
    /// every refresh and can withdraw the ones that clear.
    private var postedPumpAlerts: Set<String> = []
    static let pumpAlertCategory = "PUMP_ALERT"
    /// How long a "Snooze" action suppresses a category. A fixed default (no per-category setting UI yet).
    static let snoozeSeconds: TimeInterval = 2 * 60 * 60

    init(model: AppModel, runtime: NotificationRuntime = NotificationRuntime(),
         safetyAlertStore: SafetyAlertStore = SafetyAlertStore()) {
        self.model = model
        self.runtime = runtime
        self.safetyAlertStore = safetyAlertStore
        super.init()
        center.delegate = self
        registerCategories()
        // B6: also request critical-alert permission. Harmless (a no-op) when the app lacks the
        // critical-alerts entitlement — iOS itself downgrades a `.critical` notification to a normal one
        // when the app isn't entitled, so gating `NotificationPoster.post`'s content on the user's
        // `criticalAlertsEnabled` alone (D-05) is correct and degrades gracefully at the OS level.
        // Phase 5 (D-14, 05-03): `.badge` so `UNUserNotificationCenter.setBadgeCount` (the app-icon
        // glucose badge, `GlucoseBadge.apply`) is actually honored — without it iOS silently ignores
        // every `setBadgeCount` call regardless of the user's opt-in.
        center.requestAuthorization(options: [.alert, .sound, .criticalAlert, .badge]) { _, _ in }
        // D-03: query the OS grant state for the honest-status UI (AlertRulesView). Uses ONLY the async
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
        // CX-F-03: flush any safety alert `AppModel.postSafety` buffered before this sink existed —
        // covers both a viewless restoration launch (no `.onAppear` ever ran before now) and the ordinary
        // foreground path alike, since this line runs unconditionally at construction either way.
        model.flushPendingSafety()
        model.notificationWithdrawSink = { [weak self] keys in self?.withdraw(keys) }
        // 09.25 WR-01: withdraw every OS-outstanding request for a whole CATEGORY (used when the user
        // disables a safety-trio category via the confirm-on-disable dialog) — distinct from `withdraw(_:)`
        // above, which only knows a fixed list of dedupe keys.
        model.notificationWithdrawCategorySink = { [weak self] category in self?.withdrawAll(for: category) }
        // S7: schedule the pump-disconnect escalation ladder as OS-delivered notifications.
        model.notificationScheduleSink = { [weak self] steps in self?.scheduleDisconnectEscalation(steps) }
        // CX-F-02: arm/cancel the pre-armed background staleness watchdog.
        model.notificationStalenessSink = { [weak self] date in self?.scheduleStalenessWatchdog(from: date) }
        model.notificationStalenessCancelSink = { [weak self] in self?.cancelStalenessWatchdog() }
        model.addNotificationsSubscriber { [weak self] alerts in self?.syncPumpAlerts(alerts) }
        // CX-F-03 depth (T3-01/02): replay any still-unresolved safety alert persisted from a prior
        // launch, AFTER the sink is wired + the pending-safety buffer flushed above, so a restoration
        // launch reconstructs and re-submits every not-yet-resolved entry.
        replayPersistedSafetyAlerts()
    }

    /// D-03: query the OS grant state via the modern async API and cache it for the honest-status UI
    /// (`AlertRulesView`). Called from `init` and again on foreground so a user who flips OS notification
    /// permissions in Settings sees the status update without relaunching. `.enabled` means the entitlement
    /// is granted AND the user authorized critical alerts; any other value (`.notSupported`/`.disabled`) is
    /// treated identically by the honest-status logic (`AlertRulesView.shouldShowHonestStatus`) — see
    /// 08-RESEARCH.md Open Question #1 on which exact value iOS reports pre-entitlement.
    ///
    /// UI-only: this cache is NEVER read by `post`'s `allowCritical` gate or by `NotificationBroker.decide`
    /// (D-05) — it exists solely to drive `AppSettings.criticalAlertGrantActive` for display.
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
        print("NotificationCoordinator.refreshGrantState: criticalAlertSetting=\(settings.criticalAlertSetting.rawValue)")
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
        // CX-F-03 depth (codex MEDIUM): also prune the durable replay log, so a resolved condition can
        // never replay on the next launch.
        safetyAlertStore.remove(dedupeKeys: dedupeKeys)
    }

    /// 09.25 WR-01: withdraw every OS-outstanding (pending OR already-delivered) notification for
    /// `category` — called when the user disables a safety-trio category via the confirm-on-disable
    /// dialog, so the dialog's "faBolus will no longer alert you" promise is immediately true rather than
    /// only for the NEXT event (a pump-disconnect escalation step scheduled BEFORE the disable would
    /// otherwise still fire after it). Unlike `withdraw(_:)`, this doesn't need a fixed list of dedupe
    /// keys: it queries the OS directly and filters by the `brokerCategory` userInfo every request is
    /// already stamped with (`NotificationPoster.post`) — which is what makes it work uniformly for
    /// `.bolusReconciliation`, whose dedupe keys are dynamic per delivery attempt
    /// (`reconcile-<peerId>-<requestId>`, see `DeliveryLedgerCoordinator`) and have no fixed list to
    /// enumerate ahead of time. Best-effort / fire-and-forget: this is a UI-adjacent cleanup, not part of
    /// the governed decide()/post() path, so a caller never awaits it.
    func withdrawAll(for category: NotificationBroker.Category) {
        // CX-F-03 depth (codex MEDIUM): prune the durable replay log SYNCHRONOUSLY — the category-wide
        // OS-outstanding query below is best-effort/async, but the durable store must never be left
        // holding an entry the caller believes was just fully withdrawn.
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
    static func identifiers(for category: NotificationBroker.Category, in requests: [UNNotificationRequest]) -> [String] {
        requests.filter { ($0.content.userInfo["brokerCategory"] as? String) == category.rawValue }.map(\.identifier)
    }

    /// Same filter, for the delivered-notification shape (`UNNotification.request`) — kept separate from
    /// `identifiers(for:in:)` because `UNNotification` has no public initializer, so this half can't be
    /// driven by a plain unit test the way the pending half can.
    static func identifiers(for category: NotificationBroker.Category, inDelivered delivered: [UNNotification]) -> [String] {
        identifiers(for: category, in: delivered.map(\.request))
    }

    // MARK: Posting

    @discardableResult
    func post(_ message: NotificationBroker.Message,
              userInfo: [AnyHashable: Any] = [:], categoryId: String = "",
              trigger: UNNotificationTrigger? = nil, deadline: Date? = nil) -> NotificationBroker.Decision {
        // Default a governed category to its registered id (which carries the SNOOZE action) unless the
        // caller already supplied one (pump alerts pass PUMP_ALERT for their CLEAR action).
        let cat = categoryId.isEmpty ? Self.categoryIdentifier(for: message.category) : categoryId
        // B6: request the OS Critical Alert level when the user opted in; the poster restricts it to the
        // never-suppressible safety categories, and iOS ignores it unless the app holds the entitlement
        // (graceful degradation at the OS level — see the note in `init`).
        let allowCritical = AppSettings.shared.criticalAlertsEnabled
        // CX-F-03 depth: a never-suppressible safety category is persisted (atomic-persist-before-post)
        // through SafetyAlertPoster so it can be replayed on the next launch; every other category keeps
        // using the plain poster unchanged. `deadline` (the absolute fire time for a delayed escalation
        // step) is meaningful only on this branch — ignored otherwise.
        if message.category.neverSuppressible {
            return SafetyAlertPoster.post(message, store: safetyAlertStore, runtime: runtime, userInfo: userInfo,
                                          categoryId: cat, trigger: trigger, deadline: deadline,
                                          allowCritical: allowCritical, add: { [center] in center.add($0) })
        }
        return NotificationPoster.post(message, runtime: runtime, userInfo: userInfo,
                                       categoryId: cat, trigger: trigger, allowCritical: allowCritical,
                                       add: { [center] in center.add($0) })
    }

    // MARK: S7 — pump-disconnect escalation ladder

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
            // CX-F-03 depth: the persisted `deadline` is the absolute fire time (`now + afterSeconds`),
            // so a replay on a later launch re-derives a strictly-positive interval relative to a FRESH
            // `now`, rather than ever reusing this step's original (now stale) `afterSeconds` directly.
            post(msg, trigger: UNTimeIntervalNotificationTrigger(timeInterval: step.afterSeconds, repeats: false),
                 deadline: now.addingTimeInterval(step.afterSeconds))
        }
    }

    // MARK: CX-F-02 — pre-armed background CGM-staleness watchdog

    /// Pre-arm (or re-arm) `StalenessWatchdog`'s single delayed notification to fire
    /// `GlucoseFreshness.staleAfter` seconds past `date` (the fresh datum that just triggered the
    /// re-arm), using the SAME `UNTimeIntervalNotificationTrigger` + persist-then-replay `deadline` path
    /// `scheduleDisconnectEscalation` uses — a fixed identifier (`StalenessWatchdog.dedupeKey`) means
    /// each re-arm REPLACES the previous pending request rather than stacking. If `date` is somehow
    /// already at/past the staleness window (shouldn't happen — `refresh()` only calls this while
    /// `cgmFresh` is true, which itself requires the reading to be within the window), `replayTrigger`
    /// returns nil and nothing is scheduled — never a crash on an invalid 0/negative-interval trigger.
    private func scheduleStalenessWatchdog(from date: Date, now: Date = Date()) {
        let deadline = date.addingTimeInterval(GlucoseFreshness.staleAfter)
        guard let trigger = Self.replayTrigger(deadline: deadline, now: now) else { return }
        let msg = NotificationBroker.Message(
            category: .cgmDataLoss, severity: .warning,
            title: StalenessWatchdog.title, body: StalenessWatchdog.body,
            dedupeKey: StalenessWatchdog.dedupeKey)
        post(msg, trigger: trigger, deadline: deadline)
    }

    /// Cancel a pre-armed staleness watchdog — the feed is no longer fresh (the real `.cgmDataLoss` edge
    /// already alarmed for real by then), so a stale/redundant watchdog notification must not also fire.
    private func cancelStalenessWatchdog() {
        withdraw([StalenessWatchdog.dedupeKey])
    }

    // MARK: CX-F-03 depth — persisted safety-alert replay on launch

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

    /// AlertStore-style persist-then-replay (CX-F-03 depth, T3-01/02): reconstruct + re-submit every
    /// still-unresolved safety-alert entry from `safetyAlertStore` at launch, so an alert issued before a
    /// cold-restoration relaunch is guaranteed to reach the user rather than silently vanish. Loop
    /// `playbackAlertsFromPersistence` / Trio `replayUnacknowledgedAlerts` pattern (reproduced, not
    /// copied). Does NOT re-persist (each entry is already durable) — only reconstructs + re-submits the
    /// OS request through the plain (non-recording) poster, so `issuedDate` is never clobbered by a replay.
    private func replayPersistedSafetyAlerts(now: Date = Date()) {
        let allowCritical = AppSettings.shared.criticalAlertsEnabled
        for entry in safetyAlertStore.unresolvedEntries() {
            let msg = NotificationBroker.Message(category: entry.category, severity: entry.severity,
                                                 title: entry.title, body: entry.body, dedupeKey: entry.dedupeKey)
            let trigger = Self.replayTrigger(deadline: entry.deadline, now: now)
            NotificationPoster.post(msg, runtime: runtime,
                                    userInfo: entry.userInfo.mapValues { $0 as Any },
                                    categoryId: entry.categoryIdentifier, trigger: trigger,
                                    allowCritical: allowCritical, now: now, add: { [center] in center.add($0) })
        }
    }

    /// The registered notification-category id for a broker category: `PUMP_ALERT` for pump alerts (CLEAR
    /// + SNOOZE), the raw value for other governed categories (SNOOZE), and "" for the never-suppressible
    /// safety categories (no snooze action — they must never be snoozeable).
    static func categoryIdentifier(for c: NotificationBroker.Category) -> String {
        if c == .pumpAlert { return pumpAlertCategory }
        return c.neverSuppressible ? "" : c.rawValue
    }

    // MARK: Pump-alert fan-in

    private func key(_ n: PumpAlert) -> String { "pumpalert-\(n.kind.rawValue)-\(n.id)" }

    /// §6/S8 B6 — whether a pump notification is a user-opted-out MIRRORED ALARM and should NOT be
    /// re-notified by the app. True ONLY for a pump ALARM (`.alarm`, which the pump annunciates itself)
    /// when the user opted out. Lower-priority pump ALERTS still surface, and this can never match the
    /// app-only never-suppressible safety trio (they aren't `PumpAlert`s and post on other paths). Pure.
    static func suppressesMirroredAlarm(kind: PumpAlertKind, optedOut: Bool) -> Bool {
        kind == .alarm && optedOut
    }

    /// Post newly-active pump alerts through the broker; withdraw the ones that have cleared. Preserves the
    /// prior identity-keyed dedupe (`postedPumpAlerts`) so re-evaluation only happens on a real transition.
    private func syncPumpAlerts(_ notifications: [PumpAlert]) {
        let active = Set(notifications.map(key))
        for n in notifications where !postedPumpAlerts.contains(key(n)) {
            // §6/S8 B6: the user can opt out of the app RE-notifying pump ALARMS (kind `.alarm`) — the pump
            // itself already annunciates them audibly, so mirroring them can be notification fatigue (esp.
            // on a t:slim). Lower-priority pump ALERTS still surface. We skip WITHOUT recording it as posted,
            // so turning the opt-out back off re-surfaces a still-active alarm on the next sync. This gates
            // ONLY the pump-mirrored `.pumpAlert` path; the never-suppressible safety trio posts elsewhere.
            if Self.suppressesMirroredAlarm(kind: n.kind, optedOut: AppSettings.shared.suppressMirroredPumpAlarms) { continue }
            let k = key(n)
            postedPumpAlerts.insert(k)
            // CC-12/CX-F-08: populate the TYPED safety marker from the pump's OWN alert identity
            // (`TandemBackend.safetyClass`, the same classification `applyAutoRules` force-protects on) so
            // `requiresBreakthrough` can decide interruption level from it — never from untyped userInfo.
            // `.other` maps to `nil` (no marker) so an un-classified alert is unaffected.
            let klass = TandemBackend.safetyClass(kind: NotificationKind(rawValue: n.kind.rawValue) ?? .alert, id: n.id)
            let msg = NotificationBroker.Message(
                category: .pumpAlert,
                severity: n.kind == .alarm ? .critical : .warning,
                title: n.title,
                body: n.detail.isEmpty ? "Active pump alert" : n.detail,
                dedupeKey: k,
                safetyClass: klass.isForceProtected ? klass : nil)
            post(msg, userInfo: ["id": n.id, "kind": n.kind.rawValue], categoryId: Self.pumpAlertCategory)
        }
        let gone = Array(postedPumpAlerts.subtracting(active))
        if !gone.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: gone)
            center.removePendingNotificationRequests(withIdentifiers: gone)
            postedPumpAlerts.subtract(gone)
            for k in gone { runtime.forgetEpisode(k) }   // a genuine re-raise should notify again
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
        let clear = UNNotificationAction(identifier: "CLEAR", title: "Clear",
                                         options: [.authenticationRequired])
        let snooze = UNNotificationAction(identifier: "SNOOZE", title: "Snooze 2h", options: [])
        // Pump alerts: dismiss-on-pump (CLEAR) + snooze the category. Every OTHER governed (suppressible)
        // category gets a snooze action, keyed by its raw value. Safety categories are never registered
        // with a snooze action, so they cannot be snoozed from a notification.
        var cats: Set<UNNotificationCategory> = [
            UNNotificationCategory(identifier: Self.pumpAlertCategory, actions: [clear, snooze],
                                   intentIdentifiers: [], options: [])
        ]
        for c in NotificationBroker.Category.allCases where !c.neverSuppressible && c != .pumpAlert {
            cats.insert(UNNotificationCategory(identifier: c.rawValue, actions: [snooze],
                                               intentIdentifiers: [], options: []))
        }
        center.setNotificationCategories(cats)
    }

    // MARK: Delegate

    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                            withCompletionHandler h: @escaping (UNNotificationPresentationOptions) -> Void) {
        h([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler h: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        let action = response.actionIdentifier
        if action == "CLEAR", let id = info["id"] as? Int, let kind = info["kind"] as? Int {
            Task { @MainActor in await self.model?.dismissAlert(id: id, kind: kind) }
        } else if action == "SNOOZE", let raw = info["brokerCategory"] as? String,
                  let cat = NotificationBroker.Category(rawValue: raw) {
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
    /// debug pump-background-disconnect (CRITERION 1, 2026-08-20): the kit now recovers an unintended drop
    /// silently in the background — a genuine drop goes `.connected → .connecting` (the kit skips the
    /// `.disconnected` flicker; see `PumpBLEClient.didDisconnectPeripheral`) and reconnects without ever
    /// surfacing a down state. So the raise must NOT fire on the transient `.connecting` reconnect window;
    /// it fires only when the link reaches a TERMINAL down state:
    ///   • `.error` (the reconnect ladder GAVE UP → `.reconnectExhausted`). This is reached from the
    ///     recovering `.connecting`/`.scanning` state, NOT directly from a live one, so it must raise even
    ///     though the immediately-preceding state wasn't live — otherwise the drop→reconnect→exhaust path
    ///     would never alarm. This is the "escalation only at exhaustion" behavior.
    ///   • `.disconnected` reached DIRECTLY from a live link (`.connected`/`.bolusing`) — a hard / radio
    ///     powered-off / user disconnect. A merely-recovering `.connecting`/`.scanning` sliding to
    ///     `.disconnected` is the throttled auto-reconnect ladder and recovers silently (its give-up is the
    ///     `.error` case above), so it does NOT raise — this is what keeps a momentary background drop quiet.
    static func connection(prev: PumpConnectionState?, now: PumpConnectionState) -> SafetyEdge {
        guard let prev else { return .none }   // first observation (cold launch) is never a "drop"
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

    /// C2-01: a generic boolean-condition edge-detector, for a safety condition (like the urgent-low
    /// alarm) whose "active" test is a plain `Bool` rather than a typed state transition — raise once on
    /// false→true, clear once on true→false, never re-fire while the condition is steady.
    static func edge(wasActive: Bool, isActive: Bool) -> SafetyEdge {
        if !wasActive && isActive { return .raise }
        if wasActive && !isActive { return .clear }
        return .none
    }
}

/// tslim-reconnect-loop (Phase B, item 5): flap-rate escalation. The reconnect loop's drops fold to
/// `.connecting` (never `.disconnected`/`.error`), so `SafetyEdge.connection` deliberately returns `.none`
/// through them — by design, so a single silent background reconnect doesn't alarm. The cost is that a
/// STORM of them (the on-device evidence: 18 pair→drop cycles over ~11.5 min) is also silent. This pure
/// detector counts the live-link → `.connecting` re-pair/re-drop cycles in a rolling window and escalates
/// ONCE (latched) when they cross a threshold, so the app can raise a user-visible, NON-MUTEABLE
/// "can't hold a connection to this pump" state instead of flapping in silence.
///
/// Pure + value-typed (mirrors `SafetyEdge`/`StalenessWatchdogEdge`): the owner (`PumpConnectionLifecycle`,
/// which observes every kit state transition — not the sampled `refresh()` tick, so it never misses a fast
/// ~2 s cycle) feeds each flap and acts on the returned decision. Unit-testable without any BLE/transport.
struct ConnectionFlapDetector: Equatable {
    /// The rolling window over which flap cycles are counted.
    static let window: TimeInterval = 120   // 2 minutes
    /// The number of flap cycles within `window` that escalates to the non-muteable state.
    static let threshold = 5

    private(set) var flapTimes: [Date] = []
    private(set) var escalated = false

    /// Record one live-link (`.connected`/`.bolusing`) → `.connecting` re-pair/re-drop flap cycle observed
    /// at `at`. Prunes the window to `[at - window, at]` and returns `true` EXACTLY ONCE (latched via
    /// `escalated`) when the count reaches `threshold` within the window — so a sustained storm raises the
    /// alarm a single time, not on every subsequent cycle.
    mutating func recordFlap(at: Date) -> Bool {
        flapTimes.append(at)
        let cutoff = at.addingTimeInterval(-Self.window)
        flapTimes.removeAll { $0 < cutoff }
        guard flapTimes.count >= Self.threshold, !escalated else { return false }
        escalated = true
        return true
    }

    /// The link genuinely recovered (reached a stable `.connected`) or reached a terminal state — clear the
    /// window AND the latch so a FRESH storm can escalate again. Returns whether it had been escalated, so
    /// the caller can withdraw the alarm only when there was one to withdraw.
    @discardableResult
    mutating func reset() -> Bool {
        let was = escalated
        flapTimes.removeAll()
        escalated = false
        return was
    }
}

/// CX-F-02: pure decision for the pre-armed background staleness watchdog (`StalenessWatchdog`,
/// faBolusCore) — arm/re-arm on an ADVANCED fresh glucose datum, cancel once the feed is no longer
/// fresh (the real `SafetyEdge.freshness` → `.cgmDataLoss` edge has already alarmed for real by then).
/// Kept beside `SafetyEdge` for the same reason: unit-testable without driving a full `refresh()` cycle.
/// Distinct from `SafetyEdge` (whose cases are about POSTING/WITHDRAWING an immediate alert): this is
/// about a DELAYED, pre-armed OS notification that may fire later even if this process never runs again.
enum StalenessWatchdogEdge: Equatable {
    case none, arm(Date), cancel

    /// `lastArmedDate` is the fresh-datum date the watchdog is CURRENTLY armed against (nil while
    /// cancelled). Re-arms only when `glucoseDate` genuinely ADVANCES (not on every heartbeat
    /// re-affirming the same already-armed reading); cancels exactly once when `cgmFresh` goes false.
    static func decide(cgmFresh: Bool, glucoseDate: Date?, lastArmedDate: Date?) -> StalenessWatchdogEdge {
        if cgmFresh, let date = glucoseDate, date != lastArmedDate { return .arm(date) }
        if !cgmFresh, lastArmedDate != nil { return .cancel }
        return .none
    }
}
