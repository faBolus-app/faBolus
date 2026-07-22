import Foundation
import faBolusCore
import UserNotifications

/// Activity / Sleep mode automation (F1/F2).
///
/// Apple Shortcuts *automations* — "When any Workout starts / ends" and "When Sleep Focus turns on /
/// off" — are the supported native triggers on iPhone + Apple Watch (Garmin can't drive this: a
/// backgrounded Connect IQ glance gets no activity-start event, and Garmin doesn't integrate with
/// Apple Shortcuts). Those automations run `SetExerciseModeIntent` / `SetSleepModeIntent`, which call
/// `ModeAutomation.request(_:enabled:)`.
///
/// Switching the pump's Control-IQ mode is **Mobi-only** and gated behind the per-feature settings
/// toggle (`autoExerciseMode` / `autoSleepMode`, both default off) + Advanced control. When it can't
/// be applied automatically — a t:slim, or the pump isn't connected right now — we optionally post a
/// reminder (`modeReminders`) and queue the request so a Mobi that reconnects shortly still catches it.
@MainActor
enum ModeAutomation {
    enum Mode: String { case exercise, sleep }

    /// Pending requests older than this are ignored on drain (a workout/sleep window that's already
    /// well underway shouldn't retro-apply a switch).
    private static let pendingTTL: TimeInterval = 15 * 60
    private static var store: UserDefaults? { UserDefaults(suiteName: WidgetStore.appGroup) }
    private static func key(_ m: Mode) -> String { "pendingMode.\(m.rawValue)" }
    private static func tsKey(_ m: Mode) -> String { "pendingMode.\(m.rawValue).ts" }

    private static func settingOn(_ m: Mode) -> Bool {
        m == .exercise ? AppSettings.shared.autoExerciseMode : AppSettings.shared.autoSleepMode
    }
    private static func label(_ m: Mode, _ enabled: Bool) -> String {
        "\(m == .exercise ? "Exercise" : "Sleep") mode \(enabled ? "on" : "off")"
    }

    /// Entry point for the intents. Applies immediately when a Mobi is connected + mode-capable;
    /// otherwise queues the request and (if reminders are on) notifies the user. Returns a
    /// human-readable result string for the intent's spoken/te​xt dialog.
    static func request(_ mode: Mode, enabled: Bool) async -> String {
        guard settingOn(mode) else {
            return "Auto \(mode == .exercise ? "Exercise" : "Sleep") mode is turned off in faBolus."
        }
        let label = label(mode, enabled)
        if let model = AppModel.shared, model.snapshot.isMobi,
           model.advancedControlAllowed, model.capabilities.supportsModes {
            if model.pumpReady {
                await model.applyMode(mode, on: enabled)
                clear(mode)
                if let err = model.lastError { return "Couldn't set \(label.lowercased()): \(err)" }
                return "\(label) set on your pump."
            }
            // Mobi app is alive but the pump link is down — queue it for the reconnect drain.
            queue(mode, enabled: enabled)
            remind(title: "faBolus", body: "Will set \(label.lowercased()) when your pump reconnects.")
            return "faBolus will set \(label.lowercased()) once the pump reconnects."
        }
        // No live Mobi model (t:slim, non-Mobi, or the app isn't running): queue in case a Mobi
        // opens shortly, and remind the user to switch on the pump themselves.
        queue(mode, enabled: enabled)
        remind(title: "Set \(label) on your pump",
               body: "faBolus can't switch this pump's mode automatically — change it on the pump.")
        return "Reminder posted to set \(label.lowercased()) on your pump."
    }

    // MARK: Pending queue (App Group, shared with the intent's process)

    private static func queue(_ mode: Mode, enabled: Bool) {
        guard let store else { return }
        store.set(enabled, forKey: key(mode))
        store.set(Date().timeIntervalSince1970, forKey: tsKey(mode))
    }
    private static func clear(_ mode: Mode) {
        store?.removeObject(forKey: key(mode)); store?.removeObject(forKey: tsKey(mode))
    }

    /// Apply any fresh queued requests — called from `AppModel.refresh()` once a mode-capable Mobi is
    /// connected, so a switch requested while offline still lands (within the TTL).
    static func applyPendingIfDue(using model: AppModel) {
        guard let store, model.snapshot.isMobi, model.canControlModes else { return }
        for mode in [Mode.exercise, .sleep] {
            guard store.object(forKey: key(mode)) != nil, settingOn(mode) else { continue }
            let ts = store.double(forKey: tsKey(mode))
            guard ts > 0, Date().timeIntervalSince1970 - ts <= pendingTTL else { clear(mode); continue }
            let enabled = store.bool(forKey: key(mode))
            clear(mode)
            Task { await model.applyMode(mode, on: enabled) }
        }
    }

    // MARK: Reminder

    private static func remind(title: String, body: String) {
        guard AppSettings.shared.modeReminders else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: "modeReminder-\(title)", content: content, trigger: nil))
    }
}
