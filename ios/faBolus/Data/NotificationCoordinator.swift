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
    private(set) var state: NotificationBroker.State
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
    @discardableResult
    static func post(_ message: NotificationBroker.Message,
                     runtime: NotificationRuntime,
                     userInfo: [AnyHashable: Any] = [:],
                     categoryId: String = "",
                     now: Date = Date(),
                     add: (UNNotificationRequest) -> Void = { UNUserNotificationCenter.current().add($0) }
    ) -> NotificationBroker.Decision {
        let decision = runtime.evaluate(message, now: now)
        guard decision.deliver else { return decision }
        let content = UNMutableNotificationContent()
        content.title = message.title
        content.body = message.body
        content.sound = .default
        if !categoryId.isEmpty { content.categoryIdentifier = categoryId }
        if !userInfo.isEmpty { content.userInfo = userInfo }
        add(UNNotificationRequest(identifier: message.dedupeKey, content: content, trigger: nil))
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
        model.addNotificationsSubscriber { [weak self] alerts in self?.syncPumpAlerts(alerts) }
    }

    // MARK: Posting

    @discardableResult
    func post(_ message: NotificationBroker.Message,
              userInfo: [AnyHashable: Any] = [:], categoryId: String = "") -> NotificationBroker.Decision {
        NotificationPoster.post(message, runtime: runtime, userInfo: userInfo,
                                categoryId: categoryId,
                                add: { [center] in center.add($0) })
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
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.pumpAlertCategory, actions: [clear],
                                   intentIdentifiers: [], options: [])
        ])
    }

    // MARK: Delegate

    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                            withCompletionHandler h: @escaping (UNNotificationPresentationOptions) -> Void) {
        h([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler h: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if response.actionIdentifier == "CLEAR", let id = info["id"] as? Int, let kind = info["kind"] as? Int {
            Task { @MainActor in await self.model?.dismissAlert(id: id, kind: kind) }
        }
        h()
    }
}
