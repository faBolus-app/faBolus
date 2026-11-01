// The notification-center protocol, the request built from an alert and the paired pending/delivered removal
// are adapted from Loop's UserNotificationAlertScheduler (LoopKit/Loop `5465bcd`,
// Loop/Managers/Alerts/UserNotificationAlertScheduler.swift), Copyright © 2020 LoopKit Authors, MIT License.

import Foundation
import faBolusCore

#if canImport(UserNotifications)
import UserNotifications
#endif

/// The OS side of the alert pipeline, as narrow as the coordinator needs, so tests run without a
/// notification center (LoopKit's `UserNotificationCenter` protocol has the same shape).
public protocol NotificationScheduling: Sendable {
    /// Add `request`, replacing any request with its identifier. A request whose fire date has passed
    /// fires at once.
    func add(_ request: AlertRequest, now: Date) async throws
    /// Remove these identifiers, pending and delivered.
    func remove(identifiers: [String]) async
    /// Remove every notification the app has, pending and delivered.
    func removeAll() async
    /// The current notification settings.
    func permission() async -> NotificationPermission
}

/// The notification categories and actions, by name, shared by the registration and the response handler.
public enum AlertNotificationCategories {
    /// A dismissable pump notification: it carries "Clear", which dismisses it on the pump.
    public static let dismissablePumpAlert = "PUMP_ALERT"
    public static let clearAction = "CLEAR"
    /// The userInfo keys every request carries.
    public static let categoryKey = "alertCategory"
    public static let pumpAlertKey = "pumpAlert"

    /// The notification category identifier for `request`. Only a dismissable pump notification has an
    /// action; nothing has a snooze, and the bolus result has no action at all, so nothing silences it.
    public static func identifier(for request: AlertRequest) -> String {
        if let alert = request.pumpAlert, alert.isDismissable, !alert.isMalfunction { return dismissablePumpAlert }
        return request.category.rawValue
    }

    /// The pump notification to dismiss for a notification response, when the user tapped "Clear".
    public static func pumpAlertToClear(actionIdentifier: String, userInfo: [AnyHashable: Any]) -> PumpAlert? {
        guard actionIdentifier == clearAction, let json = userInfo[pumpAlertKey] as? String,
            let data = json.data(using: .utf8)
        else { return nil }
        return try? JSONDecoder().decode(PumpAlert.self, from: data)
    }

    /// The userInfo for `request`: its category, and the pump notification it mirrors as JSON.
    public static func userInfo(for request: AlertRequest) -> [String: String] {
        var info = [categoryKey: request.category.rawValue]
        if let alert = request.pumpAlert, let data = try? JSONEncoder().encode(alert),
            let json = String(data: data, encoding: .utf8)
        {
            info[pumpAlertKey] = json
        }
        return info
    }
}

#if canImport(UserNotifications)
extension AlertInterruptionLevel {
    /// iOS's level for this one.
    public var userNotificationLevel: UNNotificationInterruptionLevel {
        switch self {
        case .passive: return .passive
        case .active: return .active
        case .timeSensitive: return .timeSensitive
        case .critical: return .critical
        }
    }
}

extension AlertNotificationCategories {
    /// Every category the app posts under, for `setNotificationCategories` at launch. Each reports a
    /// swipe-away (`customDismissAction`) so a dismissal can be counted.
    public static func registered() -> Set<UNNotificationCategory> {
        let clear = UNNotificationAction(
            identifier: clearAction, title: "Clear", options: [.authenticationRequired])
        var categories: Set<UNNotificationCategory> = [
            UNNotificationCategory(
                identifier: dismissablePumpAlert, actions: [clear], intentIdentifiers: [],
                options: [.customDismissAction])
        ]
        for category in NotificationBroker.Category.allCases {
            categories.insert(
                UNNotificationCategory(
                    identifier: category.rawValue, actions: [], intentIdentifiers: [],
                    options: [.customDismissAction]))
        }
        return categories
    }

    /// The content for `request`, at its level, with its category and userInfo.
    public static func content(for request: AlertRequest) -> UNMutableNotificationContent {
        let content = UNMutableNotificationContent()
        content.title = request.title
        content.body = request.body
        content.interruptionLevel = request.level.userNotificationLevel
        content.sound = request.level == .passive ? nil : .default
        content.categoryIdentifier = identifier(for: request)
        content.threadIdentifier = request.category.rawValue
        content.userInfo = userInfo(for: request)
        return content
    }

    /// The trigger for a request fired at `fireDate`: none (at once) when it has passed or is under a
    /// second away, since a time-interval trigger needs a positive interval.
    public static func trigger(fireDate: Date?, now: Date) -> UNTimeIntervalNotificationTrigger? {
        guard let fireDate else { return nil }
        let interval = fireDate.timeIntervalSince(now)
        return interval >= 1 ? UNTimeIntervalNotificationTrigger(timeInterval: interval, repeats: false) : nil
    }
}

/// `NotificationScheduling` on the real notification center.
public struct UserNotificationScheduler: NotificationScheduling {
    public init() {}

    private var center: UNUserNotificationCenter { .current() }

    public func add(_ request: AlertRequest, now: Date) async throws {
        try await center.add(
            UNNotificationRequest(
                identifier: request.identifier, content: AlertNotificationCategories.content(for: request),
                trigger: AlertNotificationCategories.trigger(fireDate: request.fireDate, now: now)))
    }

    public func remove(identifiers: [String]) async {
        center.removePendingNotificationRequests(withIdentifiers: identifiers)
        center.removeDeliveredNotifications(withIdentifiers: identifiers)
    }

    public func removeAll() async {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }

    public func permission() async -> NotificationPermission {
        let settings = await center.notificationSettings()
        return NotificationPermission(
            authorization: Self.authorization(settings.authorizationStatus),
            alerts: Self.setting(settings.alertSetting), timeSensitive: Self.setting(settings.timeSensitiveSetting))
    }

    static func authorization(_ status: UNAuthorizationStatus) -> NotificationPermission.Authorization {
        switch status {
        case .notDetermined: return .notDetermined
        case .denied: return .denied
        case .authorized: return .authorized
        case .provisional: return .provisional
        #if os(iOS)
        case .ephemeral: return .ephemeral
        #endif
        // An unknown status can't be trusted to show anything, so it counts as off.
        @unknown default: return .denied
        }
    }

    static func setting(_ setting: UNNotificationSetting) -> NotificationPermission.Setting {
        switch setting {
        case .notSupported: return .notSupported
        case .disabled: return .disabled
        case .enabled: return .enabled
        @unknown default: return .disabled
        }
    }
}
#endif
