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

    @Test func exactlyTheNeverSuppressibleSafetyCategories() {
        // tslim-reconnect-loop Phase B (item 5) added `pumpConnectionUnstable` as a fourth never-suppressible
        // category (the non-muteable flap alert). The original trio stays user-configurable; the flap one is
        // NOT (see `nonConfigurableSafetyCategoryIsTrulyNonMuteable`).
        let safety = Set(C.allCases.filter { $0.neverSuppressible }.map(\.rawValue))
        #expect(safety == ["pumpDisconnect", "bolusReconciliation", "cgmDataLoss", "pumpConnectionUnstable"])
        let configurableTrio = Set(C.allCases.filter { $0.neverSuppressible && $0.isUserConfigurable }.map(\.rawValue))
        #expect(configurableTrio == ["pumpDisconnect", "bolusReconciliation", "cgmDataLoss"],
               "only the original trio is user-configurable; the flap alert has no disable path")
    }

    @Test func isPumpSourcedClassifiesOnlyThePumpAlertCategory() {
        // D-02: a pure display axis — pumpAlert is the sole pump-sourced category; every other category
        // (incl. all four never-suppressible safety categories) is app-generated.
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

    /// REMED-17: `bolusIndeterminate` is the owner's Gentle disposition — GOVERNED (suppressible), NOT
    /// in the never-suppressible trio, and ON by default. The trio-set assertion above (still exactly
    /// THREE members) is unaffected — this is a positive companion proving the new case is governed.
    @Test func bolusIndeterminateIsGovernedNotNeverSuppressibleAndDefaultEnabled() {
        #expect(!C.bolusIndeterminate.neverSuppressible)
        #expect(C.bolusIndeterminate.defaultEnabled)
        #expect(!C.bolusIndeterminate.isPumpSourced)
        // Disabled → suppressed (proving it honors normal governance, unlike the trio).
        let off = B.decide(msg(.bolusIndeterminate),
                           settings: [.bolusIndeterminate: B.CategorySettings(enabled: false)],
                           state: B.State(), now: at(9, 0), calendar: cal)
        #expect(!off.deliver && off.reason == .categoryDisabled)
    }

    @Test func safetyCategoriesAlwaysDeliverEvenFullyLocked() {
        // 09.25-01 (D-07): re-specified — "a trio delivers UNLESS the user acknowledged the
        // safety-disable warning." Maximally hostile config for EVERY category: disabled, all-day
        // quiet, huge rate-limit, AND break-through OFF — proving the config alone (without the
        // paired acknowledgment) has zero effect on the never-suppressible trio (D-05).
        let settings = Dictionary(uniqueKeysWithValues: C.allCases.map {
            ($0, B.CategorySettings(enabled: false, quietStartMinuteOfDay: 0, quietEndMinuteOfDay: 1,
                                    minIntervalSeconds: 99_999, allowCriticalBreakthrough: false))
        })
        // Day already blown past a zero budget.
        let state = B.State(dayKey: B.dayKey(at(3, 0), calendar: cal), deliveredToday: 999, mealDeliveredToday: 999)
        for c in C.allCases where c.neverSuppressible {
            let d = B.decide(msg(c), settings: settings, state: state,
                             budget: B.Budget(dailyTotal: 0, dailyMeal: 0), now: at(3, 0), calendar: cal)
            #expect(d.deliver, "\(c.rawValue) must always deliver when the ack flag is unset")
            // C6-01 (T-13-14): a never-suppressible delivery is budget-EXEMPT — "still recorded" now means
            // `lastDeliveredAt`/`notifiedEpisodes` advance, NOT the budget counter (which must stay
            // untouched so a flapping safety category can never exhaust the budget that gates a genuine
            // `bolusDeliveryFailed`).
            #expect(d.nextState.deliveredToday == 999, "\(c.rawValue) is budget-exempt (C6-01) — the daily counter must not move")
            #expect(d.nextState.lastDeliveredAt[c.rawValue] == at(3, 0), "\(c.rawValue) must still be recorded via lastDeliveredAt")
        }
        // A governed category in the SAME config is suppressed (proves the config really is hostile).
        let g = B.decide(msg(.pumpAlert), settings: settings, state: state,
                         budget: B.Budget(dailyTotal: 0), now: at(3, 0), calendar: cal)
        #expect(!g.deliver)
        // NEW arm (D-07): the SAME maximally hostile config, but with the paired acknowledgment
        // ALSO set — this is the one and only condition under which a trio member suppresses.
        let acknowledged = Dictionary(uniqueKeysWithValues: C.allCases.map {
            ($0, B.CategorySettings(enabled: false, quietStartMinuteOfDay: 0, quietEndMinuteOfDay: 1,
                                    minIntervalSeconds: 99_999, allowCriticalBreakthrough: false,
                                    userAcknowledgedSafetyDisable: true))
        })
        for c in C.allCases where c.neverSuppressible && c.isUserConfigurable {
            let d = B.decide(msg(c), settings: acknowledged, state: state,
                             budget: B.Budget(dailyTotal: 0, dailyMeal: 0), now: at(3, 0), calendar: cal)
            #expect(!d.deliver && d.reason == .categoryDisabled,
                    "\(c.rawValue) must suppress once the user acknowledged disabling it")
        }
        // tslim-reconnect-loop Phase B (item 5): the NON-configurable never-suppressible category
        // (`pumpConnectionUnstable`) has no acknowledged-disable path — even the paired ack cannot suppress
        // it (see `nonConfigurableSafetyCategoryIsTrulyNonMuteable`).
        for c in C.allCases where c.neverSuppressible && !c.isUserConfigurable {
            let d = B.decide(msg(c), settings: acknowledged, state: state,
                             budget: B.Budget(dailyTotal: 0, dailyMeal: 0), now: at(3, 0), calendar: cal)
            #expect(d.deliver, "\(c.rawValue) is non-configurable — a forged acknowledged-disable must NOT suppress it")
        }
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
        // 09.25-01 (D-07): re-specified — distinguishes a TRANSIENT snooze (never silences a trio,
        // no matter how it's forced) from the DELIBERATE acknowledged disable (the one path that does).
        // Snooze pumpAlert until 10:00: suppressed before, delivers after.
        let s = B.snooze(B.State(), category: .pumpAlert, until: at(10, 0))
        #expect(B.decide(msg(.pumpAlert), settings: enabled(.pumpAlert), state: s, now: at(9, 0), calendar: cal).reason == .snoozed)
        #expect(B.decide(msg(.pumpAlert), settings: enabled(.pumpAlert), state: s, now: at(10, 1), calendar: cal).deliver)
        // The write side refuses to record a snooze for a safety category…
        #expect(B.snooze(B.State(), category: .cgmDataLoss, until: at(10, 0)).snoozedUntil?["cgmDataLoss"] == nil)
        // …and even a hand-forged snooze map can't silence one (the read side bypasses it above the check).
        let forged = B.State(snoozedUntil: ["pumpDisconnect": at(10, 0), "cgmDataLoss": at(10, 0), "bolusReconciliation": at(10, 0)])
        for c in C.allCases where c.neverSuppressible {
            #expect(B.decide(msg(c), settings: [:], state: forged, now: at(9, 0), calendar: cal).deliver,
                   "a transient snooze — even hand-forged — can never silence a trio")
        }
        // NEW arm: the SAME forged-snooze state, but now with the deliberate acknowledged disable ALSO
        // set — THIS is the one path that suppresses, proving snooze and acknowledged-disable are
        // distinct mechanisms (a transient snooze is refused; a deliberate acknowledgment is honored).
        let ackedWhileForged = Dictionary(uniqueKeysWithValues: C.allCases.map {
            ($0, B.CategorySettings(enabled: false, userAcknowledgedSafetyDisable: true))
        })
        for c in C.allCases where c.neverSuppressible && c.isUserConfigurable {
            let d = B.decide(msg(c), settings: ackedWhileForged, state: forged, now: at(9, 0), calendar: cal)
            #expect(!d.deliver && d.reason == .categoryDisabled,
                   "\(c.rawValue): the acknowledged disable — not the forged snooze — is what suppresses")
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
        // 09.25-01 (D-07): userAcknowledgedSafetyDisable round-trips when set…
        let cfg3 = B.CategorySettings(enabled: false, userAcknowledgedSafetyDisable: true)
        #expect((try JSONDecoder().decode(B.CategorySettings.self, from: JSONEncoder().encode(cfg3))) == cfg3)
        #expect((try JSONDecoder().decode(B.CategorySettings.self, from: JSONEncoder().encode(cfg3))).userAcknowledgedSafetyDisable == true)
        // …AND a pre-this-field blob (the shape persisted since Phase 8.1, missing the new key
        // entirely) decodes with the ack field defaulting to nil — back-compat, per the Future-field
        // warning: a missing key must never fail the whole decode.
        let preFieldJSON = """
        {"enabled":true,"quietStartMinuteOfDay":0,"quietEndMinuteOfDay":0,"minIntervalSeconds":0,"allowCriticalBreakthrough":true}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(B.CategorySettings.self, from: preFieldJSON)
        #expect(decoded.userAcknowledgedSafetyDisable == nil, "a pre-field blob must decode with the ack flag nil, not fail")
        #expect(decoded.enabled == true)
    }

    // MARK: - 13-06 Task 1 (C6-01 / CC-12 / CX-F-08): budget exemption + typed urgency (RED->GREEN)

    /// Behavior Test 1 (exempt): recording a never-suppressible OR `.error`-severity delivery does NOT
    /// increment `deliveredToday` — a flapping disconnect posting repeated `.error` escalation steps must
    /// never be able to exhaust the budget that gates a genuine `bolusDeliveryFailed`.
    @Test func neverSuppressibleOrErrorSeverityDeliveryIsBudgetExempt() {
        let state = B.State(dayKey: B.dayKey(at(9, 0), calendar: cal))
        // A never-suppressible trio category, plain severity.
        let trio = B.decide(msg(.pumpDisconnect), settings: [:], state: state, now: at(9, 0), calendar: cal)
        #expect(trio.deliver && trio.nextState.deliveredToday == 0,
               "a never-suppressible delivery must not increment deliveredToday")
        // A GOVERNED category at `.error` severity (mirrors a disconnect-escalation-style message that
        // happened to be governed) is ALSO exempt — the exemption keys on severity, not only category.
        let errGoverned = B.Message(category: .pumpAlert, severity: .error, title: "t", body: "b", dedupeKey: "e1")
        let errDecision = B.decide(errGoverned, settings: enabled(.pumpAlert), state: trio.nextState, now: at(9, 1), calendar: cal)
        #expect(errDecision.deliver && errDecision.nextState.deliveredToday == 0,
               "an `.error`-severity delivery must not increment deliveredToday even on a governed category")
    }

    /// Behavior Test 2 (no undercount, codex MEDIUM): interleaving several budget-exempt safety deliveries
    /// with ONE genuinely-counted ordinary delivery never lets the exempt deliveries perturb the counter —
    /// proving there is no generic per-dedupeKey "withdraw refund" that could undercount (no such refund
    /// exists in `NotificationBroker` at all: since safety/`.error` deliveries never consumed a slot in the
    /// first place, `withdraw`-ing one — an app-layer, OS-request-removal operation with no counterpart
    /// here — has nothing to refund).
    @Test func budgetExemptDeliveriesNeverUndercountGenuinelyCountedOrdinaryOnes() {
        var state = B.State(dayKey: B.dayKey(at(9, 0), calendar: cal))
        for i in 0..<5 {
            let d = B.decide(B.Message(category: .pumpDisconnect, severity: .error, title: "t", body: "b",
                                       dedupeKey: "esc-\(i)"),
                             settings: [:], state: state, now: at(9, 0), calendar: cal)
            #expect(d.deliver)
            state = d.nextState
        }
        #expect(state.deliveredToday == 0, "five budget-exempt safety deliveries must not touch deliveredToday")
        let ordinary = B.decide(msg(.pumpAlert), settings: enabled(.pumpAlert), state: state, now: at(9, 1), calendar: cal)
        #expect(ordinary.deliver)
        #expect(ordinary.nextState.deliveredToday == 1,
               "exactly the one genuinely-counted ordinary delivery — the exempt deliveries neither consumed nor refunded a slot")
    }

    /// Behavior Test 3 (budget still applies to non-safety): an ordinary suppressible delivery still
    /// increments the counter and can still be budget-limited — the exemption above must not have
    /// accidentally widened to cover governed, non-`.error`, non-safety messages.
    @Test func ordinarySuppressibleDeliveryStillIncrementsAndIsBudgetLimited() {
        let budget = B.Budget(dailyTotal: 1)
        let state = B.State(dayKey: B.dayKey(at(9, 0), calendar: cal))
        let first = B.decide(msg(.pumpAlert, key: "a"), settings: enabled(.pumpAlert), state: state,
                             budget: budget, now: at(9, 0), calendar: cal)
        #expect(first.deliver && first.nextState.deliveredToday == 1)
        let second = B.decide(msg(.pumpAlert, key: "b"), settings: enabled(.pumpAlert), state: first.nextState,
                              budget: budget, now: at(9, 1), calendar: cal)
        #expect(!second.deliver && second.reason == .dailyBudgetReached)
    }

    /// Behavior Test 4 (severity→urgency, typed, codex MEDIUM): `requiresBreakthrough` reads a TYPED
    /// `safetyClass` field on `Message` — never untyped `userInfo` (the Message doesn't carry one, so this
    /// is asserted simply by constructing every `Message` below without any userInfo-shaped parameter). A
    /// pump ALARM (`.critical` severity) and a protected alert ID (a force-protected `safetyClass`, even at
    /// plain `.warning` severity — CX-F-08's "urgent fixed-low") both require breakthrough regardless of
    /// `.pumpAlert.neverSuppressible == false`; an ordinary warning does not.
    @Test func requiresBreakthroughReadsTypedSafetyFieldNotUserInfo() {
        let alarm = B.Message(category: .pumpAlert, severity: .critical, title: "Occlusion", body: "b", dedupeKey: "a")
        #expect(B.requiresBreakthrough(alarm), "a pump ALARM (.critical severity) must require breakthrough")

        let protectedWarning = B.Message(category: .pumpAlert, severity: .warning, title: "Fixed low", body: "b",
                                         dedupeKey: "b", safetyClass: .cgmDataLoss)
        #expect(B.requiresBreakthrough(protectedWarning),
               "a protected alert ID (typed safetyClass), even at plain .warning severity, must require breakthrough")

        let ordinary = B.Message(category: .pumpAlert, severity: .warning, title: "t", body: "b", dedupeKey: "c")
        #expect(!B.requiresBreakthrough(ordinary), "an ordinary warning with no safety marker must not require breakthrough")

        let trio = B.Message(category: .pumpDisconnect, severity: .warning, title: "t", body: "b", dedupeKey: "d")
        #expect(B.requiresBreakthrough(trio), "the never-suppressible trio always requires breakthrough")
    }

    /// 09.25-01 (D-03/D-07): focused decide() coverage — for every trio category, suppression requires
    /// BOTH `enabled == false` AND `userAcknowledgedSafetyDisable == true`; either alone still delivers.
    @Test func trioSuppressedOnlyByAcknowledgedDisable() {
        for c in C.allCases where c.neverSuppressible && c.isUserConfigurable {
            // enabled:false, ack:nil → delivers (the mandatory gate is unmet).
            let notAcked = B.decide(msg(c), settings: [c: B.CategorySettings(enabled: false)],
                                    state: B.State(), now: at(9, 0), calendar: cal)
            #expect(notAcked.deliver, "\(c.rawValue): enabled==false alone (ack nil) must still deliver")
            // enabled:true, ack:true → delivers (enabled must ALSO be false).
            let enabledButAcked = B.decide(msg(c),
                                           settings: [c: B.CategorySettings(enabled: true, userAcknowledgedSafetyDisable: true)],
                                           state: B.State(), now: at(9, 0), calendar: cal)
            #expect(enabledButAcked.deliver, "\(c.rawValue): enabled==true must still deliver even if ack is set")
            // enabled:false, ack:true → suppressed (the AND-gate is satisfied).
            let suppressed = B.decide(msg(c),
                                      settings: [c: B.CategorySettings(enabled: false, userAcknowledgedSafetyDisable: true)],
                                      state: B.State(), now: at(9, 0), calendar: cal)
            #expect(!suppressed.deliver && suppressed.reason == .categoryDisabled,
                   "\(c.rawValue): enabled==false AND ack==true must suppress")
        }
    }

    /// tslim-reconnect-loop Phase B (item 5): the flap alert (`pumpConnectionUnstable`) is TRULY
    /// non-muteable. (1) It survives the user having muted `pumpDisconnect` — it is a SEPARATE category, so
    /// disabling pump-disconnect alerts does not touch it. (2) It has no acknowledged-disable path, so even
    /// a forged/corrupt settings blob that sets `enabled:false, ack:true` for it can NOT suppress it —
    /// `decide()` delivers it unconditionally because `isUserConfigurable == false`.
    @Test func nonConfigurableSafetyCategoryIsTrulyNonMuteable() {
        #expect(C.pumpConnectionUnstable.neverSuppressible)
        #expect(!C.pumpConnectionUnstable.isUserConfigurable, "the flap alert must never be user-configurable")

        // (1) The user muted pump-disconnect (acknowledged-disable). The flap alert still delivers.
        let mutedPumpDisconnect: [C: B.CategorySettings] = [
            .pumpDisconnect: B.CategorySettings(enabled: false, userAcknowledgedSafetyDisable: true)
        ]
        let survives = B.decide(msg(.pumpConnectionUnstable), settings: mutedPumpDisconnect,
                                state: B.State(), now: at(9, 0), calendar: cal)
        #expect(survives.deliver, "the flap alert must fire even when the user has muted pumpDisconnect")

        // (2) Even a forged disable of the flap category itself cannot suppress it.
        let forgedDisable: [C: B.CategorySettings] = [
            .pumpConnectionUnstable: B.CategorySettings(enabled: false, userAcknowledgedSafetyDisable: true)
        ]
        let stillDelivers = B.decide(msg(.pumpConnectionUnstable), settings: forgedDisable,
                                     state: B.State(), now: at(9, 0), calendar: cal)
        #expect(stillDelivers.deliver, "a forged disable of the non-configurable flap category must NOT suppress it")

        // Contrast: the ORIGINAL trio IS suppressible via the same acknowledged-disable blob.
        let trioSuppressed = B.decide(msg(.pumpDisconnect), settings: mutedPumpDisconnect,
                                      state: B.State(), now: at(9, 0), calendar: cal)
        #expect(!trioSuppressed.deliver, "the user-configurable pumpDisconnect IS suppressed by its acknowledged-disable")
    }
}
