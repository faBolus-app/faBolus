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
