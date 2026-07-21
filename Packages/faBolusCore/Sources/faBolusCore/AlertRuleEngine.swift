import Foundation

/// What an auto-rule does to a matching alert.
public enum AlertAction: String, Codable, Sendable, Equatable, CaseIterable {
    /// Hide it locally and stop re-notifying (re-nags after the snooze window if still present) —
    /// like tapping Clear. Never touches the pump.
    case autoSnooze
    /// Same local hide, plus (on pumps that support remote dismiss) a signed dismiss to clear it on
    /// the pump. On other pumps this behaves like `autoSnooze`.
    case autoDismiss

    public var label: String { self == .autoSnooze ? "Auto-snooze" : "Auto-dismiss" }
}

/// A user-defined rule that auto-snoozes/auto-dismisses matching pump alerts by **time of day**,
/// **alert kind**, specific **alert ids**, and/or a **glucose condition**. Stored in `AppSettings`.
public struct AlertRule: Codable, Equatable, Identifiable, Sendable {
    public var id: UUID
    public var enabled: Bool
    public var name: String
    /// Kinds this matches; empty = any eligible kind. Alarms are always excluded by the engine.
    public var kinds: Set<PumpAlertKind>
    /// Specific alert ids this matches; empty = any id.
    public var alertIds: [Int]
    /// Active time-of-day window, in minutes past midnight. If `start <= end` it's a same-day window
    /// `[start, end)`; if `start > end` it wraps midnight (e.g. 22:00–07:00).
    public var startMinuteOfDay: Int
    public var endMinuteOfDay: Int
    /// Optional glucose gate: only act when the current glucose is below / above these (mg/dL).
    public var glucoseBelow: Int?
    public var glucoseAbove: Int?
    public var action: AlertAction

    public init(id: UUID = UUID(), enabled: Bool = true, name: String = "New rule",
                kinds: Set<PumpAlertKind> = [], alertIds: [Int] = [],
                startMinuteOfDay: Int = 0, endMinuteOfDay: Int = 24 * 60,
                glucoseBelow: Int? = nil, glucoseAbove: Int? = nil,
                action: AlertAction = .autoSnooze) {
        self.id = id; self.enabled = enabled; self.name = name
        self.kinds = kinds; self.alertIds = alertIds
        self.startMinuteOfDay = startMinuteOfDay; self.endMinuteOfDay = endMinuteOfDay
        self.glucoseBelow = glucoseBelow; self.glucoseAbove = glucoseAbove; self.action = action
    }

    /// Whether `minute` (minutes past midnight) is inside this rule's window. A full-day window
    /// (start == end) always matches.
    public func windowContains(_ minute: Int) -> Bool {
        if startMinuteOfDay == endMinuteOfDay { return true }              // full day
        if startMinuteOfDay < endMinuteOfDay {
            return minute >= startMinuteOfDay && minute < endMinuteOfDay   // same-day [start, end)
        }
        return minute >= startMinuteOfDay || minute < endMinuteOfDay        // wraps midnight
    }

    /// Whether this rule matches the given alert at the given time-of-day + current glucose.
    public func matches(alert: PumpAlert, minute: Int, glucose: Int?) -> Bool {
        guard enabled else { return false }
        guard alert.kind.isAutoRuleEligible else { return false }          // never match alarms
        if !kinds.isEmpty && !kinds.contains(alert.kind) { return false }
        if !alertIds.isEmpty && !alertIds.contains(alert.id) { return false }
        guard windowContains(minute) else { return false }
        if let below = glucoseBelow {
            guard let g = glucose, g < below else { return false }         // need a reading to gate on
        }
        if let above = glucoseAbove {
            guard let g = glucose, g > above else { return false }
        }
        return true
    }
}

/// Evaluates a set of `AlertRule`s against a single alert. Pure + testable; the backend calls this
/// from its notification-merge chokepoint.
public enum AlertRuleEngine {
    /// The action (if any) the first matching enabled rule prescribes for `alert`. Returns `nil`
    /// when nothing matches — or **always** for alarms/alarm-kind alerts, which are never auto-acted.
    public static func action(for alert: PumpAlert, rules: [AlertRule], now: Date,
                              calendar: Calendar = .current, glucose: Int?) -> AlertAction? {
        guard alert.kind.isAutoRuleEligible else { return nil }
        let comps = calendar.dateComponents([.hour, .minute], from: now)
        let minute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        for rule in rules where rule.matches(alert: alert, minute: minute, glucose: glucose) {
            return rule.action
        }
        return nil
    }
}
