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

    public init(
        id: UUID = UUID(), enabled: Bool = true, name: String = "New rule",
        kinds: Set<PumpAlertKind> = [], alertIds: [Int] = [],
        startMinuteOfDay: Int = 0, endMinuteOfDay: Int = 24 * 60,
        glucoseBelow: Int? = nil, glucoseAbove: Int? = nil,
        action: AlertAction = .autoSnooze
    ) {
        self.id = id
        self.enabled = enabled
        self.name = name
        self.kinds = kinds
        self.alertIds = alertIds
        self.startMinuteOfDay = startMinuteOfDay
        self.endMinuteOfDay = endMinuteOfDay
        self.glucoseBelow = glucoseBelow
        self.glucoseAbove = glucoseAbove
        self.action = action
    }

    /// Whether `minute` (minutes past midnight) is inside this rule's window. A full-day window
    /// (start == end) always matches.
    public func windowContains(_ minute: Int) -> Bool {
        if startMinuteOfDay == endMinuteOfDay { return true }  // full day
        if startMinuteOfDay < endMinuteOfDay {
            return minute >= startMinuteOfDay && minute < endMinuteOfDay  // same-day [start, end)
        }
        return minute >= startMinuteOfDay || minute < endMinuteOfDay  // wraps midnight
    }

    /// Whether this rule matches the given alert at the given time-of-day + current glucose.
    public func matches(alert: PumpAlert, minute: Int, glucose: Int?) -> Bool {
        guard enabled else { return false }
        guard alert.kind.isAutoRuleEligible else { return false }  // never match alarms
        if !kinds.isEmpty && !kinds.contains(alert.kind) { return false }
        if !alertIds.isEmpty && !alertIds.contains(alert.id) { return false }
        guard windowContains(minute) else { return false }
        if let below = glucoseBelow {
            guard let g = glucose, g < below else { return false }  // need a reading to gate on
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
    public static func action(
        for alert: PumpAlert, rules: [AlertRule], now: Date,
        calendar: Calendar = .current, glucose: Int?
    ) -> AlertAction? {
        guard alert.kind.isAutoRuleEligible else { return nil }
        let comps = calendar.dateComponents([.hour, .minute], from: now)
        let minute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        for rule in rules where rule.matches(alert: alert, minute: minute, glucose: glucose) {
            return rule.action
        }
        return nil
    }
}

// MARK: - Pump-alert copy overlay

/// The existing pump-alert mirror (`TandemBackend.activeNotifications` → `AlertsView`) already
/// surfaces Control-IQ's own alerts — no new faBolus advisory is added. This is a client-side copy
/// overlay for specific pump alert ids whose decoded name the protocol layer doesn't yet carry, so
/// the mirror still surfaces them with clean, neutral, Tandem-sourced copy instead of a generic
/// `"Alert N"` fallback.
///
/// **Control-IQ High Alert (#50)** — Tandem's own "CIQ increased delivery but glucose is still high"
/// alert: "test your blood glucose and treat as necessary, and check your infusion site." Never
/// upgraded to "give a bolus" (neutral, non-directive copy). Compare **Control-IQ Low Alert (#51)**,
/// which the decode layer already names cleanly — this overlay leaves that one untouched (`resolve`
/// never overrides a real decoded name).
public enum PumpAlertCopyOverlay {
    /// id → (title, detail) for alerts this overlay improves. Pure data; applied only when the caller's
    /// own decoded copy looks like a generic placeholder (see `resolve`).
    static let overlays: [Int: (title: String, detail: String)] = [
        50: (
            "Control-IQ high",
            "Control-IQ increased insulin delivery, but glucose has stayed above 200 mg/dL for 30 "
                + "minutes. Test your blood glucose and treat as necessary, and check your infusion site."
        )
    ]

    /// Resolves the copy to show for a decoded pump alert: the overlay's clean copy when one is defined
    /// for `id` AND `decodedDetail == nil` (the pump-protocol layer's own signal for "this id has no
    /// named entry, rendered as a generic fallback" — see TandemKit's `NotificationBitmap.decode`, which
    /// leaves `detail` `nil` on an unnamed bit); otherwise the decoded copy passes through UNCHANGED, so
    /// a real Tandem-sourced name the decode layer already supplies (e.g. id 51 "Control-IQ low") is
    /// never overridden.
    public static func resolve(id: Int, decodedTitle: String, decodedDetail: String?) -> (title: String, detail: String)
    {
        if decodedDetail == nil, let overlay = overlays[id] {
            return overlay
        }
        return (decodedTitle, decodedDetail ?? "")
    }

    /// Namespace-guarded entry point: the overlay's id-keyed name table is scoped to alerts only, so a
    /// reminder, alarm, malfunction or CGM alert whose id happens to collide with an alert-overlay entry
    /// (e.g. a hardware malfunction at bit 50, the same id as "Control-IQ high") passes straight through
    /// on its own decoded copy instead of borrowing the alert's. `.alert`-kind notifications defer to the
    /// unguarded `resolve` above unchanged.
    public static func resolve(kind: PumpAlertKind, id: Int, decodedTitle: String, decodedDetail: String?)
        -> (title: String, detail: String)
    {
        guard kind == .alert else { return (decodedTitle, decodedDetail ?? "") }
        return resolve(id: id, decodedTitle: decodedTitle, decodedDetail: decodedDetail)
    }
}

/// Neutral, non-directive copy: true when `text` contains an imperative dosing verb that would
/// upgrade a Tandem-sourced alert into directive dosing advice (e.g. "give a bolus").
/// Case-insensitive substring check.
public enum AlertCopyAudit {
    public static let imperativeDosingVerbs = ["bolus", "give insulin", "deliver insulin", "inject", "dose now"]

    /// True when `text` contains any imperative dosing verb/phrase (case-insensitive).
    public static func hasImperativeDosingVerb(_ text: String) -> Bool {
        let lower = text.lowercased()
        return imperativeDosingVerbs.contains { lower.contains($0) }
    }
}
