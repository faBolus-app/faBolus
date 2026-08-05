import Foundation

/// **P9 — the notification-governance policy core (§6).** One pure decision point that resolves whether a
/// candidate notification should be DELIVERED right now, folding in the per-category enable/style/quiet-
/// hours/rate-limit settings and a global (+ meal sub-) daily budget — with the three safety categories
/// hard-wired so no setting, rule, quiet-hour, or budget can ever suppress them.
///
/// This is the analog of P8's `AccessPolicy`: a **pure function over explicit state** (faBolusCore reads no
/// app globals and calls no clock — `now` is passed in, matching `AlertRuleEngine`). It is INERT until the
/// app-side broker routes its posters through it; this file changes no behavior on its own. It is distinct
/// from, and composes with, `AlertRuleEngine`: that decides whether a user *rule* auto-snoozes/dismisses a
/// pump alert; this decides delivery governance for whatever becomes a notification.
///
/// The rate-limit / quiet-hours logic is reimplemented here (pure, in faBolusCore) rather than depending on
/// the optional `AlertIntelligenceKit` (a `faBolusNudge` product, behind `#if FABOLUS_NUDGE`, whose source
/// is not vendored) — a safety-adjacent governance layer must not be gated on an optional package, and it
/// must apply to every channel, not only the two Nudge banners.
public enum NotificationBroker {

    // MARK: - Categories

    /// The notification categories the broker governs. `neverSuppressible` marks the three §6 safety
    /// categories that must reach the user regardless of settings/quiet-hours/rate-limit/budget.
    public enum Category: String, CaseIterable, Sendable, Codable {
        // The three §6 never-disableable safety categories.
        case pumpDisconnect          // the pump link dropped while it was connected/bolusing
        case bolusReconciliation     // the AUTHORITATIVE result of a bolus, incl. a resolved indeterminate
        case cgmDataLoss             // the app stopped receiving CGM data (distinct from a pump-raised CGM alert)
        // Governed (suppressible) categories.
        case pumpAlert               // a pump-raised alert/alarm/reminder surfaced as a notification
        case remoteBolusRejected     // a remote-initiated bolus was refused (never dosed)
        case modeReminder            // an activity/sleep mode reminder
        case mealReminder            // meal-timing reminders — the tightest defaults + their own sub-budget

        /// A safety category the user cannot turn off and that bypasses quiet-hours / rate-limit / budget.
        public var neverSuppressible: Bool {
            switch self {
            case .pumpDisconnect, .bolusReconciliation, .cgmDataLoss: return true
            default: return false
            }
        }

        /// Whether the category is ON by default. The never-suppressible ones are always on (and can't be
        /// turned off); meal reminders default OFF (tightest defaults, §6); the rest default ON.
        public var defaultEnabled: Bool {
            switch self {
            case .mealReminder: return false
            default: return true
            }
        }

        /// Meal reminders draw from a separate, tighter daily sub-budget (§6's M-series bucket).
        public var usesMealSubBudget: Bool { self == .mealReminder }

        public var label: String {
            switch self {
            case .pumpDisconnect:     return "Pump disconnected"
            case .bolusReconciliation: return "Bolus result"
            case .cgmDataLoss:        return "CGM data loss"
            case .pumpAlert:          return "Pump alerts"
            case .remoteBolusRejected: return "Remote bolus rejected"
            case .modeReminder:       return "Activity / sleep reminders"
            case .mealReminder:       return "Meal reminders"
            }
        }
    }

    /// Severity, for ordering + rendering (today the app renders everything identically red — this gives the
    /// broker model a real axis). Safety categories are `.critical` by construction.
    public enum Severity: Int, Comparable, Sendable, Codable, CaseIterable {
        case info = 0, warning = 1, error = 2, critical = 3
        public static func < (a: Severity, b: Severity) -> Bool { a.rawValue < b.rawValue }
    }

    // MARK: - Message

    /// A candidate notification. `dedupeKey` collapses repeats (a re-raised pump alert, a retried rejection)
    /// onto one slot; `episodeKey` groups a run of related events so the broker can honor one-per-episode.
    public struct Message: Sendable, Equatable {
        public var category: Category
        public var severity: Severity
        public var title: String
        public var body: String
        /// Stable identity for dedupe / targeted withdrawal. Repeats with the same key coalesce.
        public var dedupeKey: String
        /// Groups related events into one episode (one-notification-per-episode, §6). Defaults to `dedupeKey`.
        public var episodeKey: String
        public init(category: Category, severity: Severity, title: String, body: String,
                    dedupeKey: String, episodeKey: String? = nil) {
            self.category = category; self.severity = severity
            self.title = title; self.body = body
            self.dedupeKey = dedupeKey; self.episodeKey = episodeKey ?? dedupeKey
        }
    }

    // MARK: - Per-category settings

    /// User-configurable governance for one category. Quiet-hours use minutes past midnight like `AlertRule`
    /// (`start == end` ⇒ no quiet window). `minIntervalSeconds` rate-limits repeats of the SAME category.
    public struct CategorySettings: Sendable, Equatable, Codable {
        public var enabled: Bool
        public var quietStartMinuteOfDay: Int
        public var quietEndMinuteOfDay: Int
        public var minIntervalSeconds: TimeInterval
        public init(enabled: Bool, quietStartMinuteOfDay: Int = 0, quietEndMinuteOfDay: Int = 0,
                    minIntervalSeconds: TimeInterval = 0) {
            self.enabled = enabled
            self.quietStartMinuteOfDay = quietStartMinuteOfDay
            self.quietEndMinuteOfDay = quietEndMinuteOfDay
            self.minIntervalSeconds = minIntervalSeconds
        }
        /// The default governance for a category (respecting its `defaultEnabled`).
        public static func defaults(for category: Category) -> CategorySettings {
            CategorySettings(enabled: category.defaultEnabled)
        }
        /// True when `minute` (minutes past midnight) is inside the quiet window. Reuses `AlertRule`'s
        /// window semantics (same-day / midnight-wrap / none-when-equal).
        public func inQuietHours(minute: Int) -> Bool {
            guard quietStartMinuteOfDay != quietEndMinuteOfDay else { return false }
            if quietStartMinuteOfDay < quietEndMinuteOfDay {
                return minute >= quietStartMinuteOfDay && minute < quietEndMinuteOfDay
            }
            return minute >= quietStartMinuteOfDay || minute < quietEndMinuteOfDay
        }
    }

    /// Global daily budgets (§6): a total cap with a visible counter, plus a tighter meal sub-budget.
    public struct Budget: Sendable, Equatable, Codable {
        public var dailyTotal: Int
        public var dailyMeal: Int
        public init(dailyTotal: Int = 40, dailyMeal: Int = 6) {
            self.dailyTotal = dailyTotal; self.dailyMeal = dailyMeal
        }
    }

    // MARK: - Broker state (advanced as messages deliver)

    /// The mutable governance state the broker carries between decisions: when each category last delivered
    /// (rate-limit), the day's delivered counts (budget), and the episodes already notified. Pure data —
    /// the app persists it; `NotificationBroker` never mutates it in place, it returns the next state.
    public struct State: Sendable, Equatable, Codable {
        public var lastDeliveredAt: [String: Date]   // keyed by Category.rawValue
        public var dayKey: String                    // the calendar day the counters belong to
        public var deliveredToday: Int
        public var mealDeliveredToday: Int
        public var notifiedEpisodes: Set<String>
        /// User "snooze this category until T", keyed by `Category.rawValue`. **Optional on purpose** so an
        /// already-persisted v1 blob (written before this field existed) still decodes — a missing key →
        /// `nil` → treated as no snooze, rather than failing the whole decode and dropping the day counters.
        public var snoozedUntil: [String: Date]?
        public init(lastDeliveredAt: [String: Date] = [:], dayKey: String = "",
                    deliveredToday: Int = 0, mealDeliveredToday: Int = 0,
                    notifiedEpisodes: Set<String> = [], snoozedUntil: [String: Date]? = nil) {
            self.lastDeliveredAt = lastDeliveredAt; self.dayKey = dayKey
            self.deliveredToday = deliveredToday; self.mealDeliveredToday = mealDeliveredToday
            self.notifiedEpisodes = notifiedEpisodes; self.snoozedUntil = snoozedUntil
        }
    }

    // MARK: - Telemetry (§6 responsibility #7)

    /// Per-category counts used to tune notification defaults: how many were delivered, how many the user
    /// dismissed (swiped away), and how many they acted on (opened / tapped an action). **Kept separate
    /// from `State`** so it never perturbs the decision/equality semantics `decide` round-trips; it is
    /// write-only accounting. Cumulative (lifetime), local-only, and gathered only when the user opts in.
    public struct CategoryTelemetry: Sendable, Equatable, Codable {
        public var delivered: Int
        public var dismissed: Int
        public var actedUpon: Int
        public init(delivered: Int = 0, dismissed: Int = 0, actedUpon: Int = 0) {
            self.delivered = delivered; self.dismissed = dismissed; self.actedUpon = actedUpon
        }
    }

    // MARK: - Decision

    public enum SuppressionReason: String, Sendable, Equatable {
        case categoryDisabled, snoozed, quietHours, rateLimited, dailyBudgetReached, mealBudgetReached, episodeAlreadyNotified
    }

    public struct Decision: Sendable, Equatable {
        public let deliver: Bool
        public let reason: SuppressionReason?   // nil ⇔ deliver
        /// The state to persist AFTER acting on this decision (counters/timestamps advanced iff delivered).
        public let nextState: State
    }

    /// Decide whether `message` should be delivered now, and return the state to persist. **Fail-safe on
    /// the safety side**: a `neverSuppressible` category is ALWAYS delivered (and still recorded, so its
    /// dedupe/episode tracking works) — no setting, quiet-hour, rate-limit, or budget can drop it. Ordering
    /// for governed categories: category enabled → episode-not-already-notified → quiet-hours → rate-limit →
    /// budget. `settings` is looked up per category (falling back to that category's defaults).
    public static func decide(_ message: Message,
                              settings: [Category: CategorySettings],
                              state: State,
                              budget: Budget = Budget(),
                              now: Date,
                              calendar: Calendar = .current) -> Decision {
        var s = state
        // Roll the daily counters over at a day boundary.
        let today = Self.dayKey(now, calendar: calendar)
        if s.dayKey != today {
            s.dayKey = today; s.deliveredToday = 0; s.mealDeliveredToday = 0
        }

        func record() -> State {
            var out = s
            out.lastDeliveredAt[message.category.rawValue] = now
            out.deliveredToday += 1
            if message.category.usesMealSubBudget { out.mealDeliveredToday += 1 }
            out.notifiedEpisodes.insert(message.episodeKey)
            return out
        }
        func deliver() -> Decision { Decision(deliver: true, reason: nil, nextState: record()) }
        func suppress(_ r: SuppressionReason) -> Decision { Decision(deliver: false, reason: r, nextState: s) }

        // Safety categories bypass EVERYTHING (still recorded so dedupe/episode/counters stay coherent).
        if message.category.neverSuppressible { return deliver() }

        let cfg = settings[message.category] ?? .defaults(for: message.category)
        if !cfg.enabled { return suppress(.categoryDisabled) }

        // User snooze: suppress this category until its deadline. Placed BELOW the `neverSuppressible`
        // return above, so a snooze can never silence pumpDisconnect / bolusReconciliation / cgmDataLoss.
        if let until = s.snoozedUntil?[message.category.rawValue], now < until { return suppress(.snoozed) }

        // One-notification-per-episode: a governed repeat of an already-notified episode is dropped.
        if s.notifiedEpisodes.contains(message.episodeKey) { return suppress(.episodeAlreadyNotified) }

        let comps = calendar.dateComponents([.hour, .minute], from: now)
        let minute = (comps.hour ?? 0) * 60 + (comps.minute ?? 0)
        if cfg.inQuietHours(minute: minute) { return suppress(.quietHours) }

        if cfg.minIntervalSeconds > 0, let last = s.lastDeliveredAt[message.category.rawValue],
           now.timeIntervalSince(last) < cfg.minIntervalSeconds {
            return suppress(.rateLimited)
        }

        if s.deliveredToday >= budget.dailyTotal { return suppress(.dailyBudgetReached) }
        if message.category.usesMealSubBudget, s.mealDeliveredToday >= budget.dailyMeal {
            return suppress(.mealBudgetReached)
        }
        return deliver()
    }

    /// The calendar-day key used for the daily budget rollover. Stable and calendar-explicit (no `Date()`).
    public static func dayKey(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return "\(c.year ?? 0)-\(c.month ?? 0)-\(c.day ?? 0)"
    }

    /// Record a "snooze this category until `until`" into `state`, returning the next state. **Refuses a
    /// `neverSuppressible` category** — the write side guards the safety invariant in addition to `decide`
    /// bypassing it on the read side, so no code path (or corrupt input) can ever snooze a safety alert.
    public static func snooze(_ state: State, category: Category, until: Date) -> State {
        guard !category.neverSuppressible else { return state }
        var out = state
        var m = out.snoozedUntil ?? [:]
        m[category.rawValue] = until
        out.snoozedUntil = m
        return out
    }

    // MARK: - Force-protection (§6: safety alerts a user auto-rule must never suppress)

    /// Safety classification of a pump alert, for force-protection against user auto-rules. Computed by the
    /// backend from the pump's OWN alert identity — the PumpX2 notification-bit → semantics mapping lives at
    /// the decode boundary (`TandemBackend`), NOT here, so faBolusCore never hard-codes PumpX2 bit values.
    /// `.other` alerts follow the user's `AlertRule`s normally; every protected class is NEVER auto-snoozed
    /// or auto-dismissed by a rule.
    public enum AlertSafetyClass: String, Sendable, Codable, CaseIterable {
        case occlusion        // occlusion / pump malfunction (already an alarm, protected here independently)
        case cgmDataLoss      // CGM unavailable / sensor failed / out-of-range / failed connection
        case lowInsulin       // low insulin / empty reservoir
        case other
        public var isForceProtected: Bool { self != .other }
    }

    /// The auto-rule action for `alert`, with safety force-protection applied ON TOP of `AlertRuleEngine`.
    /// Returns `nil` (never auto-act) for any force-protected class REGARDLESS of a matching user rule —
    /// closing the shipped hole (verified 2026-08-05) where only alarms were protected, so a user rule
    /// could auto-snooze/dismiss a CGM-loss or low-insulin alert (kinds 1/3). For `.other`, delegates to
    /// the pure, tested `AlertRuleEngine.action`. The backend calls THIS instead of `AlertRuleEngine`
    /// directly at its notification-merge chokepoint.
    public static func autoSuppression(for alert: PumpAlert, safetyClass: AlertSafetyClass,
                                       rules: [AlertRule], now: Date, calendar: Calendar = .current,
                                       glucose: Int?) -> AlertAction? {
        if safetyClass.isForceProtected { return nil }
        return AlertRuleEngine.action(for: alert, rules: rules, now: now, calendar: calendar, glucose: glucose)
    }
}
