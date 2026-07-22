import Foundation
import faBolusCore
import UserNotifications

/// Posts an iOS local notification for each active pump alert, with a **Clear** action that
/// dismisses it on the pump — so the user can act on alerts without opening the app. Notifications
/// are removed when the alert clears.
@MainActor
final class PumpAlertNotifier: NSObject, UNUserNotificationCenterDelegate {
    private weak var model: AppModel?
    private let center = UNUserNotificationCenter.current()
    private var posted: Set<String> = []
    static let category = "PUMP_ALERT"

    init(model: AppModel) {
        self.model = model
        super.init()
        center.delegate = self
        let clear = UNNotificationAction(identifier: "CLEAR", title: "Clear",
                                         options: [.authenticationRequired])
        center.setNotificationCategories([
            UNNotificationCategory(identifier: Self.category, actions: [clear],
                                   intentIdentifiers: [], options: [])
        ])
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        model.onNotificationsChange = { [weak self] ns in self?.sync(ns) }
    }

    private func key(_ n: PumpAlert) -> String { "pumpalert-\(n.kind.rawValue)-\(n.id)" }

    private func sync(_ notifications: [PumpAlert]) {
        let active = Set(notifications.map(key))
        // Post newly-active alerts.
        for n in notifications where !posted.contains(key(n)) {
            posted.insert(key(n))
            let content = UNMutableNotificationContent()
            content.title = n.title
            content.body = n.detail.isEmpty ? "Active pump alert" : n.detail
            content.categoryIdentifier = Self.category
            content.userInfo = ["id": n.id, "kind": n.kind.rawValue]
            content.sound = .default
            center.add(UNNotificationRequest(identifier: key(n), content: content, trigger: nil))
        }
        // Withdraw alerts that are no longer active (e.g. cleared elsewhere).
        let gone = Array(posted.subtracting(active))
        if !gone.isEmpty {
            center.removeDeliveredNotifications(withIdentifiers: gone)
            center.removePendingNotificationRequests(withIdentifiers: gone)
            posted.subtract(gone)
        }
    }

    // Show alerts even when the app is foreground.
    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, willPresent n: UNNotification,
                                            withCompletionHandler h: @escaping (UNNotificationPresentationOptions) -> Void) {
        h([.banner, .sound])
    }

    // Handle the Clear action → signed dismiss on the pump.
    nonisolated func userNotificationCenter(_ c: UNUserNotificationCenter, didReceive response: UNNotificationResponse,
                                            withCompletionHandler h: @escaping () -> Void) {
        let info = response.notification.request.content.userInfo
        if response.actionIdentifier == "CLEAR", let id = info["id"] as? Int, let kind = info["kind"] as? Int {
            Task { @MainActor in await self.model?.dismissAlert(id: id, kind: kind) }
        }
        h()
    }
}
