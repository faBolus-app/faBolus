import Foundation
import faBolusCore
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
    static let stateKey = "notificationBroker.state.v1"
    static let telemetryKey = "notificationBroker.telemetry.v1"
    /// Per-category `NotificationBroker.CategorySettings` (Phase 8.1) — previously in-memory-only (see
    /// RESEARCH.md Critical Correction); now App-Group-persisted like `state`/`telemetry` so a preference the
    /// user sets survives a relaunch and is honored by every out-of-process poster.
    static let settingsKey = "notificationBroker.settings.v1"
    private let stateKey = NotificationRuntime.stateKey
    private let telemetryKey = NotificationRuntime.telemetryKey
    private let settingsKey = NotificationRuntime.settingsKey
    /// App-Group flag (default false, opt-in per N21) gating telemetry accrual — App-Group-backed so the
    /// out-of-process mode-reminder intent honors the same choice the main app made.
    static let telemetryEnabledKey = "notificationBroker.telemetryEnabled"
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
        if allowCritical && message.category.neverSuppressible {
            content.interruptionLevel = .critical
            content.sound = .defaultCritical
        } else {
            content.sound = .default
            // CR-01: graceful degradation while the Critical-Alerts entitlement is pending (or the user
            // hasn't opted in) — the safety trio still must break through Focus/DND, or the "time-sensitive
            // delivery" promise in AlertRulesView is false. `.timeSensitive` does that without requiring the
            // special-request Critical Alerts entitlement; it only needs the lightweight Time-Sensitive
            // Notifications capability (see faBolus.entitlements). Scoped to `neverSuppressible` so a
            // governed/suppressible category is never escalated. If the app ever lacked the Time-Sensitive
            // capability, iOS silently downgrades this to `.active` — safe by default, never a crash.
            if message.category.neverSuppressible {
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
    /// Identity keys of pump alerts currently posted, so we don't re-evaluate an already-active alert on
    /// every refresh and can withdraw the ones that clear.
    private var postedPumpAlerts: Set<String> = []
    static let pumpAlertCategory = "PUMP_ALERT"
    /// How long a "Snooze" action suppresses a category. A fixed default (no per-category setting UI yet).
    static let snoozeSeconds: TimeInterval = 2 * 60 * 60

    init(model: AppModel, runtime: NotificationRuntime = NotificationRuntime()) {
        self.model = model
        self.runtime = runtime
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
        model.notificationWithdrawSink = { [weak self] keys in self?.withdraw(keys) }
        // 09.25 WR-01: withdraw every OS-outstanding request for a whole CATEGORY (used when the user
        // disables a safety-trio category via the confirm-on-disable dialog) — distinct from `withdraw(_:)`
        // above, which only knows a fixed list of dedupe keys.
        model.notificationWithdrawCategorySink = { [weak self] category in self?.withdrawAll(for: category) }
        // S7: schedule the pump-disconnect escalation ladder as OS-delivered notifications.
        model.notificationScheduleSink = { [weak self] steps in self?.scheduleDisconnectEscalation(steps) }
        model.addNotificationsSubscriber { [weak self] alerts in self?.syncPumpAlerts(alerts) }
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
              trigger: UNNotificationTrigger? = nil) -> NotificationBroker.Decision {
        // Default a governed category to its registered id (which carries the SNOOZE action) unless the
        // caller already supplied one (pump alerts pass PUMP_ALERT for their CLEAR action).
        let cat = categoryId.isEmpty ? Self.categoryIdentifier(for: message.category) : categoryId
        // B6: request the OS Critical Alert level when the user opted in; the poster restricts it to the
        // never-suppressible safety categories, and iOS ignores it unless the app holds the entitlement
        // (graceful degradation at the OS level — see the note in `init`).
        let allowCritical = AppSettings.shared.criticalAlertsEnabled
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
        for step in steps {
            let msg = NotificationBroker.Message(
                category: .pumpDisconnect, severity: .error,
                title: step.title, body: step.body, dedupeKey: step.id)
            post(msg, trigger: UNTimeIntervalNotificationTrigger(timeInterval: step.afterSeconds, repeats: false))
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
            let msg = NotificationBroker.Message(
                category: .pumpAlert,
                severity: n.kind == .alarm ? .critical : .warning,
                title: n.title,
                body: n.detail.isEmpty ? "Active pump alert" : n.detail,
                dedupeKey: k)
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
}
