import Foundation
import faBolusCore

/// What iOS lets the app do with notifications, read from `UNNotificationSettings`.
public struct NotificationPermission: Sendable, Hashable {
    public enum Authorization: Sendable, Hashable {
        case notDetermined, denied, authorized, provisional, ephemeral
    }
    /// One of iOS's per-app notification settings.
    public enum Setting: Sendable, Hashable {
        /// The app doesn't support it (time-sensitive without the entitlement reads this way).
        case notSupported
        case disabled
        case enabled
    }

    public var authorization: Authorization
    /// Banners, Lock Screen and Notification Center as a whole (`alertSetting`).
    public var alerts: Setting
    public var timeSensitive: Setting

    public init(authorization: Authorization, alerts: Setting, timeSensitive: Setting) {
        self.authorization = authorization
        self.alerts = alerts
        self.timeSensitive = timeSensitive
    }

    /// Not asked yet. Treated as allowed: the app asks at launch, and nothing in Settings can be turned on
    /// before it has.
    public static let notDetermined = NotificationPermission(
        authorization: .notDetermined, alerts: .notSupported, timeSensitive: .notSupported)

    /// The app's alerts can't reach the user: denied, quiet-only (provisional or ephemeral delivers to
    /// Notification Center without a banner or sound), alerts turned off, or time-sensitive turned off
    /// (which lets Focus hold the safety alerts). Without the Critical Alerts entitlement, these iOS
    /// settings can silence any alert, which is why the app also shows open bolus results in the app.
    public var isOff: Bool {
        switch authorization {
        case .notDetermined: return false
        case .denied, .provisional, .ephemeral: return true
        case .authorized: return alerts == .disabled || timeSensitive == .disabled
        }
    }
}

/// A persistent banner in the app. It stays while its condition holds and can't be dismissed.
public enum InAppBanner: Sendable, Hashable, CaseIterable {
    /// A bolus outcome is unknown and nobody has confirmed it on the pump. Shown whether or not
    /// notifications are allowed, because iOS settings can silence the notification.
    case unknownBolusOutcome
    /// The bolus ledger can't be read, so it may be hiding an unknown outcome. Shown whatever the
    /// notification settings, like an unknown outcome.
    case bolusRecordUnreadable
    /// The app's notifications can't reach the user.
    case notificationsOff

    public var title: String {
        switch self {
        case .unknownBolusOutcome, .bolusRecordUnreadable: return AlertEngine.unknownOutcomeTitle
        case .notificationsOff: return "Notifications are off"
        }
    }

    public var body: String {
        switch self {
        case .unknownBolusOutcome:
            return BolusBlock.unknownOutcome(since: .distantPast).userMessage
        case .bolusRecordUnreadable:
            return BolusBlock.ledgerUnreadable.userMessage
        case .notificationsOff:
            // Owner-approved copy, 2026-11-01.
            return "faBolus can't alert you to bolus results, pump disconnects or urgent lows. Turn on "
                + "notifications for faBolus in Settings."
        }
    }

    /// Whether the banner offers a button that opens the app's page in iOS Settings.
    public var opensSettings: Bool { self == .notificationsOff }

    /// The banners to show, most important first.
    public static func current(
        openBolusResult: Bool, ledgerUnreadable: Bool, permission: NotificationPermission
    ) -> [InAppBanner] {
        var out: [InAppBanner] = []
        if openBolusResult { out.append(.unknownBolusOutcome) }
        if ledgerUnreadable { out.append(.bolusRecordUnreadable) }
        if permission.isOff { out.append(.notificationsOff) }
        return out
    }
}
