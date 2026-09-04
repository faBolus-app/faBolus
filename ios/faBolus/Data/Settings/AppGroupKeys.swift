import Foundation

/// App-Group `UserDefaults` key strings used by `AppSettings` and App-Group-backed coordinators.
/// `Shared/WidgetShared.swift` keeps its own `widgetSnapshot` key — it compiles into the widget
/// extension, which cannot see this app-target registry.
public enum AppGroupKeys {
    // MARK: - Notification broker (`NotificationCoordinator.swift`, `NotificationRuntime`)
    public static let notificationBrokerState = "notificationBroker.state.v1"
    /// v2, not a migration of v1: the pre-fix cohort could never report a dismissal (no category ever
    /// registered a dismiss action), so those accrued counts cannot answer the question the counters
    /// exist to answer. The loader reads only this key; a v1 blob is left in place and ignored.
    public static let notificationBrokerTelemetry = "notificationBroker.telemetry.v2"
    public static let notificationBrokerSettings = "notificationBroker.settings.v1"
    /// Shared opt-in — also read directly by `BLESessionLog`/`ConnectionTelemetryStore` (one
    /// "share local diagnostics" switch governs all three; App-Group-backed so the out-of-process
    /// mode-reminder intent honors the same choice the main app made).
    public static let notificationTelemetryEnabled = "notificationBroker.telemetryEnabled"

    // MARK: - Safety-alert replay persistence (`SafetyAlertStore.swift`)
    public static let safetyAlerts = "notificationBroker.safetyAlerts.v1"
    /// Set once, after the one-time purge of the `bolusReconciliation` replay records an older build
    /// left behind (those records had no pruning path, so the launch replay re-announced a long-settled
    /// dose forever). Presence of this key means the purge has run on this install and must not run
    /// again — see `SafetyAlertStore.purgeLegacyReconciliationEntriesOnce()` for the predicate and why
    /// it cannot discard a genuinely unresolved dose.
    public static let safetyAlertsReconciliationPurged = "notificationBroker.safetyAlerts.reconciliationPurged.v1"

    // MARK: - Connection telemetry (`ConnectionTelemetryStore.swift`)
    public static let connectionTelemetry = "connectionTelemetry.v1"

    // MARK: - Mode automation pending-request markers (`ModeAutomation.swift`)
    /// Per-`Mode` (`"exercise"`/`"sleep"`) pending-request flag, set while a switch is queued waiting
    /// for a Mobi to (re)connect.
    public static func pendingMode(_ mode: String) -> String { "pendingMode.\(mode)" }
    /// The matching queued-at timestamp, used to expire a stale pending request on drain.
    public static func pendingModeTimestamp(_ mode: String) -> String { "pendingMode.\(mode).ts" }
}
