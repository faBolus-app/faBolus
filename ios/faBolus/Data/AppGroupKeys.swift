import Foundation

/// Central registry of the App-Group-scoped (`WidgetStore.appGroup`) `UserDefaults` KEY STRINGS used
/// by `AppSettings` and the App-Group-backed coordinators (D4-06) — consolidates keys that were
/// previously each declared once, in the ONE file that owns them, with no shared table tying them
/// together, so a future rename in one place could silently drift from a reader in another.
///
/// **Scope note (found live during this plan, not assumed up front):** a grep of every
/// `UserDefaults(suiteName: WidgetStore.appGroup)` call site under `ios/faBolus` + `Shared` surfaced
/// eight files. Two are deliberately EXCLUDED here:
/// - `AppModel.swift`/`TandemBackend.swift` — byte-guarded dose-path units (D-01 constraint). Neither
///   hardcodes an App-Group KEY string of its own; `AppModel.swift` only references the App-Group ID
///   itself (`WidgetStore.appGroup`) via `StoredSettingChangeStore.defaultURL(appGroupID:)`, so there is
///   nothing here for either file to read, and neither is touched by this registry.
/// - `Shared/WidgetShared.swift` — compiled into BOTH the `faBolus` app target AND the `faBolusWidgets`
///   extension target (see `project.yml`), whereas this file (`ios/faBolus/Data/AppGroupKeys.swift`)
///   compiles ONLY into the app target. Repointing `WidgetShared.swift`'s own `widgetSnapshot` key at
///   this registry would break the widget extension's build (undefined symbol). Its key stays
///   hand-rolled in place — a real cross-target boundary, not an oversight.
/// - `Shared/DisplaySettings.swift` — ALSO excluded, for a different reason: a grep for any caller of
///   `DisplaySettings.<anything>` across `ios/` + `Shared/` returns zero hits outside the file's own
///   declaration. It is dead code (a remnant of the Mac menu-bar remote removed in Phase 3, 03-02,
///   REMOTE-02) with no live reader/writer anywhere — consolidating its ~16 keys would serve no drift-
///   prevention purpose (nothing can drift when nothing calls it) and risks scope creep beyond D4-06's
///   stated goal. Flagged in this plan's SUMMARY for a future cleanup pass to delete the orphaned file
///   outright (consistent with the project's narrow-main "remove dead code" direction), rather than
///   keeping it alive by wiring it into a registry it doesn't need.
///
/// The four files this registry DOES consolidate are all main-app-target-only, confirmed by
/// `project.yml`'s `faBolus` target source list (the unconditional `ios/faBolus` include).
public enum AppGroupKeys {
    // MARK: - Notification broker (`NotificationCoordinator.swift`, `NotificationRuntime`)
    public static let notificationBrokerState = "notificationBroker.state.v1"
    public static let notificationBrokerTelemetry = "notificationBroker.telemetry.v1"
    public static let notificationBrokerSettings = "notificationBroker.settings.v1"
    /// Shared opt-in — also read directly by `BLESessionLog`/`ConnectionTelemetryStore` (one
    /// "share local diagnostics" switch governs all three; App-Group-backed so the out-of-process
    /// mode-reminder intent honors the same choice the main app made).
    public static let notificationTelemetryEnabled = "notificationBroker.telemetryEnabled"

    // MARK: - Safety-alert replay persistence (`SafetyAlertStore.swift`)
    public static let safetyAlerts = "notificationBroker.safetyAlerts.v1"

    // MARK: - Connection telemetry (`ConnectionTelemetryStore.swift`)
    public static let connectionTelemetry = "connectionTelemetry.v1"

    // MARK: - Mode automation pending-request markers (`ModeAutomation.swift`)
    /// Per-`Mode` (`"exercise"`/`"sleep"`) pending-request flag, set while a switch is queued waiting
    /// for a Mobi to (re)connect.
    public static func pendingMode(_ mode: String) -> String { "pendingMode.\(mode)" }
    /// The matching queued-at timestamp, used to expire a stale pending request on drain.
    public static func pendingModeTimestamp(_ mode: String) -> String { "pendingMode.\(mode).ts" }
}
