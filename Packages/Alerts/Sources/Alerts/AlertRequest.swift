import Foundation
import faBolusCore

/// One notification the app wants the OS to hold: its identity, category, fixed level and copy, and
/// when it fires. Posting a request under an identifier the OS already holds replaces it.
public struct AlertRequest: Sendable, Hashable, Codable {
    public var identifier: String
    public var category: NotificationBroker.Category
    public var severity: AlertSeverity
    public var level: AlertInterruptionLevel
    /// How hard to push past the first notification. `.none` for everything this release.
    public var escalation: AlertEscalation
    public var title: String
    public var body: String
    /// When it fires; `nil` at once. Absolute, so a request re-sent after a relaunch fires when it
    /// would have, not its delay again from the relaunch.
    public var fireDate: Date?
    /// The pump notification this mirrors, so its "Clear" action can dismiss it on the pump.
    public var pumpAlert: PumpAlert?

    public init(
        identifier: String, category: NotificationBroker.Category, severity: AlertSeverity,
        level: AlertInterruptionLevel, escalation: AlertEscalation = .none, title: String, body: String,
        fireDate: Date? = nil, pumpAlert: PumpAlert? = nil
    ) {
        self.identifier = identifier
        self.category = category
        self.severity = severity
        self.level = level
        self.escalation = escalation
        self.title = title
        self.body = body
        self.fireDate = fireDate
        self.pumpAlert = pumpAlert
    }

    // Tolerant of a later build's additions: the fields that may be absent decode to their defaults.
    private enum CodingKeys: String, CodingKey {
        case identifier, category, severity, level, escalation, title, body, fireDate, pumpAlert
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try c.decode(String.self, forKey: .identifier)
        category = try c.decode(NotificationBroker.Category.self, forKey: .category)
        severity = (try? c.decodeIfPresent(AlertSeverity.self, forKey: .severity)) ?? .warning
        level = try c.decode(AlertInterruptionLevel.self, forKey: .level)
        escalation = (try? c.decodeIfPresent(AlertEscalation.self, forKey: .escalation)) ?? .none
        title = try c.decode(String.self, forKey: .title)
        body = try c.decode(String.self, forKey: .body)
        fireDate = try c.decodeIfPresent(Date.self, forKey: .fireDate)
        pumpAlert = try c.decodeIfPresent(PumpAlert.self, forKey: .pumpAlert)
    }

    /// Whether posting `self` where `other` is held would change what the OS shows. A change to the pump
    /// notification's `remoteClear` alone doesn't: posting again would alert again for nothing new, so a
    /// notification already showing keeps its actions, and a Clear it can no longer do is answered "clear it
    /// on the pump".
    func presentsLike(_ other: AlertRequest?) -> Bool {
        guard var other else { return false }
        if let alert = pumpAlert, other.pumpAlert != nil { other.pumpAlert?.remoteClear = alert.remoteClear }
        return self == other
    }

    /// Whether it has fired (or fires at once) by `now`.
    public func hasFired(by now: Date) -> Bool { fireDate.map { $0 <= now } ?? true }
}

/// What the engine asks the OS to do.
public enum AlertEffect: Sendable, Hashable, Codable {
    /// Hold this request: add it, or replace the one with its identifier.
    case post(AlertRequest)
    /// Remove these identifiers, pending and delivered.
    case withdraw([String])
}
