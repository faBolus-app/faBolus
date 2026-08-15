import Testing
import Foundation
@testable import faBolusCore

/// P9: the pure notification-governance core. Pins the §6 guarantees: the three safety categories are
/// never suppressible (no setting / quiet-hour / rate-limit / budget can drop them), and every governed
/// gate (disabled, one-per-episode, quiet-hours, rate-limit, daily + meal budget) suppresses exactly when
/// it should. Deterministic: a fixed UTC calendar so minute-of-day and the day rollover are stable.
@Suite struct NotificationBrokerTests {
    typealias B = NotificationBroker
    typealias C = NotificationBroker.Category

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "UTC")!; return c
    }()
    private func at(_ h: Int, _ m: Int, day: Int = 1) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 1, day: day, hour: h, minute: m))!
    }
    private func msg(_ c: C, key: String = "k", episode: String? = nil) -> B.Message {
        B.Message(category: c, severity: .warning, title: "t", body: "b", dedupeKey: key, episodeKey: episode)
    }
    /// One enabled, unconstrained setting for a governed category (isolate the gate under test).
    private func enabled(_ c: C, quiet: (Int, Int) = (0, 0), minInterval: TimeInterval = 0) -> [C: B.CategorySettings] {
        [c: B.CategorySettings(enabled: true, quietStartMinuteOfDay: quiet.0, quietEndMinuteOfDay: quiet.1,
                               minIntervalSeconds: minInterval)]
    }
    /// A CRITICAL-severity alarm on the GOVERNED `.pumpAlert` category — exactly what the coordinator
    /// builds for a pump `kind == .alarm` (occlusion / empty-cartridge / pump-error).
    private func criticalAlarm(episode: String? = nil) -> B.Message {
        B.Message(category: .pumpAlert, severity: .critical, title: "Occlusion", body: "b", dedupeKey: "occ", episodeKey: episode)
    }

    @Test func exactlyTheThreeSafetyCategoriesAreNeverSuppressible() {
        let safety = Set(C.allCases.filter { $0.neverSuppressible }.map(\.rawValue))
        #expect(safety == ["pumpDisconnect", "bolusReconciliation", "cgmDataLoss"])
    }

    @Test func isPumpSourcedClassifiesOnlyThePumpAlertCategory() {
        // D-02: a pure display axis — pumpAlert is the sole pump-sourced category; the other 7
        // (incl. all three trio categories) are app-generated.
        #expect(Set(C.allCases.filter { $0.isPumpSourced }.map(\.rawValue)) == ["pumpAlert"])
    }

    @Test func bolusDeliveryFailedIsGovernedNotASafetyCategory() {
        // §6 `lastError` Tier-2: a FAILED / BLOCKED delivery notification. The owner decided it is
        // SUPPRESSIBLE (unlike the three safety categories) — it defaults ON, can be disabled, and can be
        // snoozed. (The INDETERMINATE outcome it is deliberately NOT posted for stays a
        // `bolusReconciliation` concern, and that category IS never-suppressible.)
        #expect(!C.bolusDeliveryFailed.neverSuppressible)
        #expect(C.bolusDeliveryFailed.defaultEnabled)
        // Disabled → suppressed.
        let off = B.decide(msg(.bolusDeliveryFailed),
                           settings: [.bolusDeliveryFailed: B.CategorySettings(enabled: false)],
                           state: B.State(), now: at(9, 0), calendar: cal)
        #expect(!off.deliver && off.reason == .categoryDisabled)
        // Snoozed → suppressed until the deadline (a governed category honors snooze; a safety one can't).
        let snoozed = B.snooze(B.State(), category: .bolusDeliveryFailed, until: at(10, 0))
        let d = B.decide(msg(.bolusDeliveryFailed), settings: enabled(.bolusDeliveryFailed),
                         state: snoozed, now: at(9, 0), calendar: cal)
        #expect(!d.deliver && d.reason == .snoozed)
    }

    @Test func safetyCategoriesAlwaysDeliverEvenFullyLocked() {
        // Maximally hostile config for EVERY category: disabled, all-day quiet, huge rate-limit, AND
        // break-through OFF — proving the new toggle has zero effect on the never-suppressible trio (D-05).
        let settings = Dictionary(uniqueKeysWithValues: C.allCases.map {
            ($0, B.CategorySettings(enabled: false, quietStartMinuteOfDay: 0, quietEndMinuteOfDay: 1,
                                    minIntervalSeconds: 99_999, allowCriticalBreakthrough: false))
        })
        // Day already blown past a zero budget.
        let state = B.State(dayKey: B.dayKey(at(3, 0), calendar: cal), deliveredToday: 999, mealDeliveredToday: 999)
        for c in C.allCases where c.neverSuppressible {
            let d = B.decide(msg(c), settings: settings, state: state,
                             budget: B.Budget(dailyTotal: 0, dailyMeal: 0), now: at(3, 0), calendar: cal)
            #expect(d.deliver, "\(c.rawValue) must always deliver")
            #expect(d.nextState.deliveredToday == 1000, "\(c.rawValue) must still be recorded")
        }
        // A governed category in the SAME config is suppressed (proves the config really is hostile).
        let g = B.decide(msg(.pumpAlert), settings: settings, state: state,
                         budget: B.Budget(dailyTotal: 0), now: at(3, 0), calendar: cal)
        #expect(!g.deliver)
    }

    @Test func disabledGovernedCategoryIsSuppressed() {
        let d = B.decide(msg(.pumpAlert), settings: [.pumpAlert: .init(enabled: false)],
                         state: B.State(), now: at(12, 0), calendar: cal)
        #expect(d.reason == .categoryDisabled)
    }

    @Test func quietHoursSuppressInsideTheWindowOnly() {
        let s = enabled(.pumpAlert, quiet: (22 * 60, 7 * 60))   // 22:00–07:00, wraps midnight
        #expect(B.decide(msg(.pumpAlert), settings: s, state: B.State(), now: at(23, 0), calendar: cal).reason == .quietHours)
        #expect(B.decide(msg(.pumpAlert), settings: s, state: B.State(), now: at(3, 0), calendar: cal).reason == .quietHours)
        #expect(B.decide(msg(.pumpAlert), settings: s, state: B.State(), now: at(12, 0), calendar: cal).deliver)
    }

    @Test func rateLimitSuppressesRepeatsWithinTheInterval() {
        let s = enabled(.pumpAlert, minInterval: 300)
        let state = B.State(lastDeliveredAt: ["pumpAlert": at(10, 0)], dayKey: B.dayKey(at(10, 0), calendar: cal))
        #expect(B.decide(msg(.pumpAlert), settings: s, state: state, now: at(10, 2), calendar: cal).reason == .rateLimited)
        #expect(B.decide(msg(.pumpAlert), settings: s, state: state, now: at(10, 6), calendar: cal).deliver)
    }

    @Test func dailyBudgetCapsGovernedButNotSafety() {
        let state = B.State(dayKey: B.dayKey(at(9, 0), calendar: cal), deliveredToday: 2)
        let budget = B.Budget(dailyTotal: 2)
        #expect(B.decide(msg(.pumpAlert), settings: enabled(.pumpAlert), state: state, budget: budget,
                         now: at(9, 0), calendar: cal).reason == .dailyBudgetReached)
        // A safety category is delivered past the same exhausted budget.
        #expect(B.decide(msg(.pumpDisconnect), settings: [:], state: state, budget: budget,
                         now: at(9, 0), calendar: cal).deliver)
    }

    @Test func mealSubBudgetCapsMealRemindersBeforeTheTotal() {
        let state = B.State(dayKey: B.dayKey(at(9, 0), calendar: cal), deliveredToday: 3, mealDeliveredToday: 2)
        let budget = B.Budget(dailyTotal: 40, dailyMeal: 2)   // total has room; meal is spent
        let d = B.decide(msg(.mealReminder), settings: enabled(.mealReminder), state: state, budget: budget,
                         now: at(9, 0), calendar: cal)
        #expect(d.reason == .mealBudgetReached)
    }

    @Test func oneNotificationPerEpisodeForGovernedButSafetyStillRepeats() {
        let s = enabled(.pumpAlert)
        let first = B.decide(msg(.pumpAlert, episode: "ep1"), settings: s, state: B.State(), now: at(9, 0), calendar: cal)
        #expect(first.deliver)
        // A governed repeat of the same episode is dropped…
        let second = B.decide(msg(.pumpAlert, episode: "ep1"), settings: s, state: first.nextState, now: at(9, 5), calendar: cal)
        #expect(second.reason == .episodeAlreadyNotified)
        // …but a safety category is NOT episode-gated.
        let safety1 = B.decide(msg(.pumpDisconnect, episode: "epX"), settings: [:], state: B.State(), now: at(9, 0), calendar: cal)
        let safety2 = B.decide(msg(.pumpDisconnect, episode: "epX"), settings: [:], state: safety1.nextState, now: at(9, 5), calendar: cal)
        #expect(safety1.deliver && safety2.deliver)
    }

    @Test func dailyCountersRollOverAtADayBoundary() {
        let state = B.State(dayKey: B.dayKey(at(23, 0, day: 1), calendar: cal), deliveredToday: 39)
        // Next day, same message: the day key differs, so the counter resets before this delivery.
        let d = B.decide(msg(.pumpAlert), settings: enabled(.pumpAlert), state: state,
                         budget: B.Budget(dailyTotal: 40), now: at(0, 5, day: 2), calendar: cal)
        #expect(d.deliver)
        #expect(d.nextState.deliveredToday == 1)
    }

    @Test func forceProtectedSafetyClassesAreNeverAutoSuppressed() {
        let rule = AlertRule(name: "snooze all", kinds: [], startMinuteOfDay: 0, endMinuteOfDay: 0, action: .autoSnooze)
        let now = at(12, 0)
        // A CGM-loss alert (kind cgmAlert): the rule WOULD match — AlertRuleEngine returns .autoSnooze…
        let cgm = PumpAlert(id: 27, kind: .cgmAlert, title: "Failed connection")
        #expect(AlertRuleEngine.action(for: cgm, rules: [rule], now: now, calendar: cal, glucose: nil) == .autoSnooze)
        // …but force-protection overrides it to nil (the closed hole).
        #expect(B.autoSuppression(for: cgm, safetyClass: .cgmDataLoss, rules: [rule], now: now, calendar: cal, glucose: nil) == nil)
        // Low-insulin (kind .alert) and occlusion are force-protected too.
        let low = PumpAlert(id: 0, kind: .alert, title: "Low insulin")
        #expect(B.autoSuppression(for: low, safetyClass: .lowInsulin, rules: [rule], now: now, calendar: cal, glucose: nil) == nil)
        let occ = PumpAlert(id: 2, kind: .alarm, title: "Occlusion")
        #expect(B.autoSuppression(for: occ, safetyClass: .occlusion, rules: [rule], now: now, calendar: cal, glucose: nil) == nil)
        // A generic .other alert with the SAME rule still auto-snoozes (protection is by class, not blanket).
        let other = PumpAlert(id: 99, kind: .alert, title: "Some reminder")
        #expect(B.autoSuppression(for: other, safetyClass: .other, rules: [rule], now: now, calendar: cal, glucose: nil) == .autoSnooze)
    }

    @Test func semanticClassNotPumpKindDrivesProtection() {
        // Two kind-.alert alerts + the same matching rule: the low-insulin one is protected, the plain one
        // is not — proving the SEMANTIC class (from the backend), not the pump kind, drives force-protection.
        let rule = AlertRule(action: .autoSnooze)   // default: full-day, any eligible kind
        let now = at(9, 0)
        let low = PumpAlert(id: 0, kind: .alert, title: "Low insulin")
        let plain = PumpAlert(id: 99, kind: .alert, title: "Other")
        #expect(B.autoSuppression(for: low, safetyClass: .lowInsulin, rules: [rule], now: now, calendar: cal, glucose: nil) == nil)
        #expect(B.autoSuppression(for: plain, safetyClass: .other, rules: [rule], now: now, calendar: cal, glucose: nil) == .autoSnooze)
        #expect(B.AlertSafetyClass.allCases.filter { $0.isForceProtected }.count == 3)
    }

    @Test func snoozeSuppressesGovernedUntilTheDeadlineButNeverSafety() {
        // Snooze pumpAlert until 10:00: suppressed before, delivers after.
        let s = B.snooze(B.State(), category: .pumpAlert, until: at(10, 0))
        #expect(B.decide(msg(.pumpAlert), settings: enabled(.pumpAlert), state: s, now: at(9, 0), calendar: cal).reason == .snoozed)
        #expect(B.decide(msg(.pumpAlert), settings: enabled(.pumpAlert), state: s, now: at(10, 1), calendar: cal).deliver)
        // The write side refuses to record a snooze for a safety category…
        #expect(B.snooze(B.State(), category: .cgmDataLoss, until: at(10, 0)).snoozedUntil?["cgmDataLoss"] == nil)
        // …and even a hand-forged snooze map can't silence one (the read side bypasses it above the check).
        let forged = B.State(snoozedUntil: ["pumpDisconnect": at(10, 0), "cgmDataLoss": at(10, 0), "bolusReconciliation": at(10, 0)])
        for c in C.allCases where c.neverSuppressible {
            #expect(B.decide(msg(c), settings: [:], state: forged, now: at(9, 0), calendar: cal).deliver)
        }
    }

    @Test func criticalGovernedAlarmBypassesEveryUserAndBudgetSuppression() {
        // S8 / §6 #6: an occlusion / empty-cartridge / pump-error alarm is surfaced as the GOVERNED
        // `.pumpAlert` category but with `Severity.critical`. It must survive a maximally hostile config —
        // category disabled, all-day quiet-hours, huge rate-limit, a snooze in force, and a day past a zero
        // budget — because critical alarms bypass the budget/quiet-hours. A `.warning` in the SAME config
        // is suppressed (proving the config is genuinely hostile).
        let settings: [C: B.CategorySettings] = [.pumpAlert: B.CategorySettings(
            enabled: false, quietStartMinuteOfDay: 0, quietEndMinuteOfDay: 1, minIntervalSeconds: 99_999)]
        var state = B.State(lastDeliveredAt: ["pumpAlert": at(3, 0)],
                            dayKey: B.dayKey(at(3, 0), calendar: cal), deliveredToday: 999)
        state = B.snooze(state, category: .pumpAlert, until: at(23, 59))
        let budget = B.Budget(dailyTotal: 0)
        let crit = B.decide(criticalAlarm(), settings: settings, state: state, budget: budget, now: at(3, 30), calendar: cal)
        #expect(crit.deliver, "a CRITICAL pump alarm must not be droppable by disable/snooze/quiet-hours/rate/budget")
        #expect(crit.nextState.deliveredToday == 1000, "still recorded")
        let warn = B.Message(category: .pumpAlert, severity: .warning, title: "t", body: "b", dedupeKey: "occ")
        #expect(!B.decide(warn, settings: settings, state: state, budget: budget, now: at(3, 30), calendar: cal).deliver)
    }

    @Test func breakThroughToggleGatesTheCriticalBypassBothDirections() {
        // D-04: with break-through OFF, a CRITICAL `.pumpAlert` in a hostile (disabled) config honors
        // normal governance instead of bypassing it — it is suppressed exactly like a non-critical message.
        let hostileState = B.State(lastDeliveredAt: ["pumpAlert": at(3, 0)],
                                   dayKey: B.dayKey(at(3, 0), calendar: cal), deliveredToday: 999)
        let budget = B.Budget(dailyTotal: 0)
        let settingsOff: [C: B.CategorySettings] = [.pumpAlert: B.CategorySettings(
            enabled: false, quietStartMinuteOfDay: 0, quietEndMinuteOfDay: 1, minIntervalSeconds: 99_999,
            allowCriticalBreakthrough: false)]
        let off = B.decide(criticalAlarm(), settings: settingsOff, state: hostileState, budget: budget,
                           now: at(3, 30), calendar: cal)
        #expect(!off.deliver, "break-through OFF must make a critical pumpAlert honor normal governance")
        #expect(off.reason == .categoryDisabled)
        // Same hostile config but break-through ON preserves today's bypass behavior unchanged.
        let settingsOn: [C: B.CategorySettings] = [.pumpAlert: B.CategorySettings(
            enabled: false, quietStartMinuteOfDay: 0, quietEndMinuteOfDay: 1, minIntervalSeconds: 99_999,
            allowCriticalBreakthrough: true)]
        let on = B.decide(criticalAlarm(), settings: settingsOn, state: hostileState, budget: budget,
                          now: at(3, 30), calendar: cal)
        #expect(on.deliver, "break-through ON must preserve today's critical-bypass behavior")
    }

    @Test func criticalAlarmStillHonorsOneNotificationPerEpisode() {
        // The nuance vs a neverSuppressible category: a critical governed alarm is NOT re-delivered every
        // poll. The pump re-raises an ACTIVE alarm each cycle; re-notification is driven by forgetEpisode
        // (dropping the episode from state), NOT by ignoring the dedup here — else an active occlusion
        // would spam a notification every few seconds.
        let s = enabled(.pumpAlert)
        let first = B.decide(criticalAlarm(episode: "occ-1"), settings: s, state: B.State(), now: at(9, 0), calendar: cal)
        #expect(first.deliver)
        let again = B.decide(criticalAlarm(episode: "occ-1"), settings: s, state: first.nextState, now: at(9, 1), calendar: cal)
        #expect(again.reason == .episodeAlreadyNotified, "an active critical alarm dedupes per episode (no spam)")
    }

    @Test func stateAndSettingsRoundTripCodable() throws {
        let state = B.State(lastDeliveredAt: ["pumpAlert": at(9, 0)], dayKey: "2026-1-1",
                            deliveredToday: 3, mealDeliveredToday: 1, notifiedEpisodes: ["ep1"],
                            snoozedUntil: ["pumpAlert": at(9, 0)])
        let s2 = try JSONDecoder().decode(B.State.self, from: JSONEncoder().encode(state))
        #expect(s2 == state)
        let cfg = B.CategorySettings(enabled: true, quietStartMinuteOfDay: 1320, quietEndMinuteOfDay: 420, minIntervalSeconds: 300)
        #expect((try JSONDecoder().decode(B.CategorySettings.self, from: JSONEncoder().encode(cfg))) == cfg)
        // Non-default allowCriticalBreakthrough round-trips too (D-04 field).
        let cfg2 = B.CategorySettings(enabled: true, quietStartMinuteOfDay: 1320, quietEndMinuteOfDay: 420,
                                      minIntervalSeconds: 300, allowCriticalBreakthrough: false)
        #expect((try JSONDecoder().decode(B.CategorySettings.self, from: JSONEncoder().encode(cfg2))) == cfg2)
        let budget = B.Budget(dailyTotal: 40, dailyMeal: 6)
        #expect((try JSONDecoder().decode(B.Budget.self, from: JSONEncoder().encode(budget))) == budget)
    }
}
