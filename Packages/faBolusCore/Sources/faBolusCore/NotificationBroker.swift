// `AlertInterruptionLevel` is adapted from LoopKit's Alert.InterruptionLevel (LoopKit/LoopKit `a5beee96`,
// LoopKit/Alert.swift), Copyright © 2020 LoopKit Authors, MIT License.

import Foundation

/// How hard a notification interrupts. The cases and their meanings are iOS's own
/// `UNNotificationInterruptionLevel`; the type is the app's so nothing above the notification layer imports
/// UserNotifications. The interruption level is in the alert model, as LoopKit's `Alert.InterruptionLevel` is.
public enum AlertInterruptionLevel: Int, Sendable, Hashable, Codable, CaseIterable, Comparable {
    /// Added to Notification Center without lighting the screen or playing a sound.
    case passive = 0
    /// Shown at once, lights the screen, may play a sound. Focus and Do Not Disturb can hold it.
    case active = 1
    /// Shown at once, and may be shown during Focus and Do Not Disturb.
    case timeSensitive = 2
    /// Always shown and sounds through the mute switch. Needs Apple's Critical Alerts entitlement.
    case critical = 3

    public static func < (a: AlertInterruptionLevel, b: AlertInterruptionLevel) -> Bool { a.rawValue < b.rawValue }

    /// The loudest level this release posts. The Critical Alerts entitlement isn't requested, so
    /// nothing goes above time-sensitive; the critical level exists for a pump without its own screen.
    public static let releaseCeiling: AlertInterruptionLevel = .timeSensitive
}

/// The alert policy core: which categories exist, how loud each one is (fixed per category), and
/// whether a candidate notification is posted. Pure: no clock, no I/O, no settings read from anywhere
/// but the `AlertPolicy` passed in.
public enum NotificationBroker {

    /// The categories the user sees in settings, each on or off. Urgency is fixed per category.
    public enum Category: String, CaseIterable, Sendable, Codable {
        /// A bolus whose outcome the app lost track of, and later how it settled. Never off: the user is
        /// always told right away when an outcome is unknown, and again when pump history settles it.
        case bolusReconciliation
        /// The pump hasn't been reachable for the delay the user chose.
        case pumpDisconnect
        /// The link keeps dropping before it holds.
        case pumpConnectionUnstable
        /// The backup CGM reads urgently low while the pump's own CGM feed is unavailable.
        case urgentLowGlucose
        /// No fresh glucose from any source. Shown in the app only; never a notification this release.
        case cgmDataLoss
        /// A pump alert, alarm, malfunction or reminder, mirrored from the pump.
        case pumpAlert
        /// A CGM alert or error, mirrored from the pump.
        case pumpCgmAlert
        /// A bolus the pump refused, or that the app knows didn't deliver.
        case bolusDeliveryFailed
        /// A remote's bolus request that the phone refused before it reached the pump.
        case remoteBolusRejected

        /// The fixed interruption level. The app's own safety alerts are time-sensitive: the pump knows
        /// nothing about the phone's link, the backup CGM or the app's dose ledger, so the app is their
        /// only annunciator. What the pump already annunciates itself is posted at the standard level.
        public var level: AlertInterruptionLevel {
            switch self {
            case .bolusReconciliation, .pumpDisconnect, .pumpConnectionUnstable, .urgentLowGlucose, .cgmDataLoss:
                return .timeSensitive
            case .pumpAlert, .pumpCgmAlert, .bolusDeliveryFailed, .remoteBolusRejected:
                return .active
            }
        }

        /// How hard the app pushes past the first notification. Nothing repeats this release; a pump
        /// without its own screen needs alarms that repeat until acknowledged, and a category gets that by
        /// changing this alone.
        public var escalation: AlertEscalation { .none }

        /// The app's own safety categories, posted time-sensitive.
        public var isSafetySet: Bool { level >= .timeSensitive }

        /// Every category but the bolus result can be turned off.
        public var canBeTurnedOff: Bool { self != .bolusReconciliation }

        /// Whether the category ever becomes a notification. CGM loss is shown in the app only (owner
        /// decisions 2026-08-30 and 2026-11-01): the old app notified once per advanced reading. It keeps
        /// a category and a level so a pump without its own screen can make it an alert later.
        public var deliversAsNotification: Bool { self != .cgmDataLoss }

        /// The settings label.
        public var label: String {
            switch self {
            case .bolusReconciliation: return "Bolus result"
            case .pumpDisconnect: return "Pump disconnected"
            case .pumpConnectionUnstable: return "Connection unstable"
            case .urgentLowGlucose: return "Urgent low (backup CGM)"
            case .cgmDataLoss: return "CGM loss"
            case .pumpAlert: return "Pump alerts & alarms"
            case .pumpCgmAlert: return "CGM alerts & errors"
            case .bolusDeliveryFailed: return "Bolus not delivered"
            case .remoteBolusRejected: return "Remote bolus refused"
            }
        }
    }

    // MARK: - Message

    /// A candidate notification. `identifier` is the notification's own identity: posting again under the
    /// same identifier replaces it, and withdrawing it removes it.
    public struct Message: Sendable, Hashable, Codable {
        public var category: Category
        public var severity: AlertSeverity
        public var title: String
        public var body: String
        public var identifier: String
        public init(category: Category, severity: AlertSeverity, title: String, body: String, identifier: String) {
            self.category = category
            self.severity = severity
            self.title = title
            self.body = body
            self.identifier = identifier
        }
    }

    // MARK: - Decision

    public enum SuppressionReason: String, Sendable, Hashable {
        /// The user turned the category off.
        case categoryOff
        /// The category is shown in the app only and never notifies.
        case uiStateOnly
    }

    public struct Decision: Sendable, Hashable {
        /// The level to post at, or `nil` when the message isn't posted.
        public let level: AlertInterruptionLevel?
        /// How hard to push past the first notification, when posted.
        public let escalation: AlertEscalation?
        public let reason: SuppressionReason?
        public var deliver: Bool { level != nil }
    }

    /// Whether `message` is posted, and how. Only its category counts: see `decide(_:policy:)` for a
    /// category.
    public static func decide(_ message: Message, policy: AlertPolicy) -> Decision {
        decide(message.category, policy: policy)
    }

    /// Whether a notification in `category` is posted, and how. A category that notifies and is on is
    /// posted at its fixed level and escalation, capped at this release's ceilings. Nothing else
    /// suppresses it: no count, snooze or rate limit. The bolus result is always on, whatever the policy
    /// says.
    public static func decide(_ category: Category, policy: AlertPolicy) -> Decision {
        if !category.deliversAsNotification { return Decision(level: nil, escalation: nil, reason: .uiStateOnly) }
        if !policy.isOn(category) { return Decision(level: nil, escalation: nil, reason: .categoryOff) }
        return Decision(
            level: Swift.min(category.level, AlertInterruptionLevel.releaseCeiling),
            escalation: Swift.min(category.escalation, AlertEscalation.releaseCeiling), reason: nil)
    }
}

extension NotificationBroker.Category {
    /// Whether the category mirrors the pump's own annunciation or is generated by the app.
    public var notificationSource: NotificationRules.Source {
        switch self {
        case .pumpAlert, .pumpCgmAlert: return .pumpMirror
        default: return .appOwn
        }
    }
}
