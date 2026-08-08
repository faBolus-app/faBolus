import Foundation
import faBolusCore
import UserNotifications

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
    private let stateKey = "notificationBroker.state.v1"
    private let telemetryKey = "notificationBroker.telemetry.v1"
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
        self.settings = settings ?? Dictionary(uniqueKeysWithValues:
            NotificationBroker.Category.allCases.map { ($0, .defaults(for: $0)) })
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

    /// Run the broker on `message` at `now`, persist the advanced state, and return the decision.
    func evaluate(_ message: NotificationBroker.Message, now: Date) -> NotificationBroker.Decision {
        // Re-read the store first: a sibling process (a mode-reminder intent) may have advanced the
        // counters since we loaded. Last-writer-wins is fine for notification governance.
        if let data = store.data(forKey: stateKey),
           let decoded = try? JSONDecoder().decode(NotificationBroker.State.self, from: data) {
            state = decoded
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
                     now: Date = Date(),
                     add: (UNNotificationRequest) -> Void = { UNUserNotificationCenter.current().add($0) }
    ) -> NotificationBroker.Decision {
        let decision = runtime.evaluate(message, now: now)
        guard decision.deliver else { return decision }
        runtime.recordDelivered(message.category)   // telemetry (opt-in; no-op otherwise)
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        content.sound = .default
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
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        // The broker is now the sink for the two ad-hoc posters, and the sole pump-alert subscriber.
        model.notificationSink = { [weak self] msg, userInfo, categoryId in
            self?.post(msg, userInfo: userInfo, categoryId: categoryId)
        }
        model.notificationWithdrawSink = { [weak self] keys in self?.withdraw(keys) }
        // S7: schedule the pump-disconnect escalation ladder as OS-delivered notifications.
        model.notificationScheduleSink = { [weak self] steps in self?.scheduleDisconnectEscalation(steps) }
        model.addNotificationsSubscriber { [weak self] alerts in self?.syncPumpAlerts(alerts) }
    }

    /// Remove delivered + pending notifications for these dedupe keys — used when a safety condition
    /// resolves (the pump reconnects, the CGM feed resumes), so a stale "disconnected"/"data lost" banner
    /// doesn't linger.
    func withdraw(_ dedupeKeys: [String]) {
        guard !dedupeKeys.isEmpty else { return }
        center.removeDeliveredNotifications(withIdentifiers: dedupeKeys)
        center.removePendingNotificationRequests(withIdentifiers: dedupeKeys)
    }

    // MARK: Posting

    @discardableResult
    func post(_ message: NotificationBroker.Message,
              userInfo: [AnyHashable: Any] = [:], categoryId: String = "",
              trigger: UNNotificationTrigger? = nil) -> NotificationBroker.Decision {
        // Default a governed category to its registered id (which carries the SNOOZE action) unless the
        // caller already supplied one (pump alerts pass PUMP_ALERT for their CLEAR action).
        let cat = categoryId.isEmpty ? Self.categoryIdentifier(for: message.category) : categoryId
        return NotificationPoster.post(message, runtime: runtime, userInfo: userInfo,
                                       categoryId: cat, trigger: trigger,
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

    /// Post newly-active pump alerts through the broker; withdraw the ones that have cleared. Preserves the
    /// prior identity-keyed dedupe (`postedPumpAlerts`) so re-evaluation only happens on a real transition.
    private func syncPumpAlerts(_ notifications: [PumpAlert]) {
        let active = Set(notifications.map(key))
        for n in notifications where !postedPumpAlerts.contains(key(n)) {
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

    /// Pump link: raise when a *live* link (connected / bolusing) drops to disconnected / error; clear
    /// when it returns to connected. A `nil` previous state (the first observation) never raises, so a
    /// cold launch that starts disconnected isn't reported as a "drop".
    static func connection(prev: PumpConnectionState?, now: PumpConnectionState) -> SafetyEdge {
        let wasLive = prev == .connected || prev == .bolusing
        if wasLive && (now == .disconnected || now == .error) { return .raise }
        if let prev, prev != .connected, now == .connected { return .clear }
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
