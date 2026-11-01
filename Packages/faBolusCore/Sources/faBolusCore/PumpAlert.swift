import Foundation

/// The pump's own category for a notification. Raw values match the v1 remote protocol's alert kinds
/// (reminder 0 / alert 1 / alarm 2 / cgmAlert 3), so the v1 `RemoteAlert` mapping is a passthrough.
public enum PumpAlertKind: Int, Sendable, Equatable, Hashable, Codable, CaseIterable {
    case reminder = 0, alert = 1, alarm = 2, cgmAlert = 3

    /// The tier this kind maps to on the v1 Garmin alert wire (`RemoteAlert.severity`). The watch fails
    /// an absent or unknown tier closed to "critical", so a kind not mapped here is never under-alerted.
    public var wireSeverityTier: String {
        switch self {
        case .alarm: return "critical"
        case .alert: return "high"
        case .cgmAlert: return "high"
        case .reminder: return "info"
        }
    }
}

/// How serious an alert is. Ordered, so the most serious open alert can be picked.
public enum AlertSeverity: Int, Sendable, Hashable, Codable, CaseIterable, Comparable {
    case info = 0, warning = 1, critical = 2

    public static func < (a: AlertSeverity, b: AlertSeverity) -> Bool { a.rawValue < b.rawValue }
}

/// How hard the app pushes an alert past the first notification. A pump without its own screen needs
/// alarms that repeat until acknowledged and, with Apple's entitlement, Critical Alerts; this release
/// asks for neither, so everything is `.none`. The level exists so that can be added without a redesign.
public enum AlertEscalation: Int, Sendable, Hashable, Codable, CaseIterable, Comparable {
    /// One notification.
    case none = 0
    /// Repeats until acknowledged.
    case `repeat` = 1
    /// Repeats and breaks through silent mode and Focus (Critical Alerts).
    case critical = 2

    public static func < (a: AlertEscalation, b: AlertEscalation) -> Bool { a.rawValue < b.rawValue }
}

/// A notification the pump is showing, mapped from the pump library's own type so nothing above the
/// pump layer depends on that library.
public struct PumpAlert: Identifiable, Sendable, Hashable, Codable {
    /// The pump's id for this notification (its bit index within `kind`). Unique only together with
    /// `kind` and `malfunctionCode`.
    public let id: Int
    public let kind: PumpAlertKind
    public let title: String
    public let detail: String
    public let isDismissable: Bool
    /// The pump's malfunction code, when this is a malfunction. A malfunction stops delivery and
    /// decodes as an alarm that can't be dismissed, so `kind` alone can't tell it from an ordinary alarm.
    public let malfunctionCode: Int?
    /// How hard the app pushes this alert. Set by the alert policy, not by the pump.
    public var escalation: AlertEscalation

    public init(
        id: Int, kind: PumpAlertKind, title: String, detail: String = "", isDismissable: Bool = true,
        malfunctionCode: Int? = nil, escalation: AlertEscalation = .none
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.isDismissable = isDismissable
        self.malfunctionCode = malfunctionCode
        self.escalation = escalation
    }

    public var isMalfunction: Bool { malfunctionCode != nil }

    /// Severity follows the pump's own classification: alarms and malfunctions stop or threaten
    /// delivery, so they are critical; reminders are informational.
    public var severity: AlertSeverity {
        if isMalfunction { return .critical }
        switch kind {
        case .alarm: return .critical
        case .alert, .cgmAlert: return .warning
        case .reminder: return .info
        }
    }
}

/// The result of asking the pump to dismiss one of its notifications.
public enum DismissOutcome: Sendable, Hashable, Codable {
    /// The pump confirmed the dismissal in an authenticated reply. The only outcome that lets a remote
    /// stop showing the alert.
    case cleared
    /// The pump refused, in an authenticated reply.
    case refused
    /// No authenticated reply arrived (timeout, drop, or an unverified error). The alert stays shown.
    case unconfirmed
    /// This pump doesn't support remote dismissal, so nothing was sent. The app says so instead of
    /// failing silently.
    case unsupported
}
