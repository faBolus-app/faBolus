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

    /// The most this release does: one notification. No repeat, and no Critical Alerts entitlement.
    public static let releaseCeiling: AlertEscalation = .none
}

/// Whether an alert can be cleared from the phone or a remote (DismissNotification). The pump session decides
/// it once per alert, and the phone and the remotes only read it.
public enum RemoteClear: String, Sendable, Hashable, Codable {
    /// It can be cleared remotely.
    case available
    /// Not yet known for this pump: the phone may try clearing it once to find out. A remote never does.
    case tryable
    /// Clear it on the pump.
    case unavailable
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
    /// The pump's identifier for the malfunction, when this is a malfunction. Tandem's pump reports a
    /// malfunction only as a bit in its malfunction status, so this is that bit. A malfunction stops delivery and
    /// decodes as an alarm that can't be dismissed, so `kind` alone can't tell it from an ordinary alarm.
    public let malfunctionCode: Int?
    /// How hard the app pushes this alert. Set by the alert policy, not by the pump.
    public var escalation: AlertEscalation
    /// Whether it can be cleared from the phone or a remote. Set by the pump session, from this alert and
    /// what's known about the pump; nothing else decides it.
    public var remoteClear: RemoteClear

    public init(
        id: Int, kind: PumpAlertKind, title: String, detail: String = "", isDismissable: Bool = true,
        malfunctionCode: Int? = nil, escalation: AlertEscalation = .none, remoteClear: RemoteClear = .unavailable
    ) {
        self.id = id
        self.kind = kind
        self.title = title
        self.detail = detail
        self.isDismissable = isDismissable
        self.malfunctionCode = malfunctionCode
        self.escalation = escalation
        self.remoteClear = remoteClear
    }

    private enum CodingKeys: String, CodingKey {
        case id, kind, title, detail, isDismissable, malfunctionCode, escalation, remoteClear
    }

    /// An alert saved before `remoteClear` existed reads as not clearable remotely until the session sets it.
    public init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        kind = try c.decode(PumpAlertKind.self, forKey: .kind)
        title = try c.decode(String.self, forKey: .title)
        detail = try c.decode(String.self, forKey: .detail)
        isDismissable = try c.decode(Bool.self, forKey: .isDismissable)
        malfunctionCode = try c.decodeIfPresent(Int.self, forKey: .malfunctionCode)
        escalation = try c.decode(AlertEscalation.self, forKey: .escalation)
        remoteClear = try c.decodeIfPresent(RemoteClear.self, forKey: .remoteClear) ?? .unavailable
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
    /// The pump answered that it cleared the alert, but the alert was still there on the next read: this
    /// pump doesn't act on a remote clear. The user is told to clear it on the pump.
    case notCleared
}
