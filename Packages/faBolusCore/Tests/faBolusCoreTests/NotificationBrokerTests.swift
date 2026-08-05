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

    @Test func exactlyTheThreeSafetyCategoriesAreNeverSuppressible() {
        let safety = Set(C.allCases.filter { $0.neverSuppressible }.map(\.rawValue))
        #expect(safety == ["pumpDisconnect", "bolusReconciliation", "cgmDataLoss"])
    }

    @Test func safetyCategoriesAlwaysDeliverEvenFullyLocked() {
        // Maximally hostile config for EVERY category: disabled, all-day quiet, huge rate-limit.
        let settings = Dictionary(uniqueKeysWithValues: C.allCases.map {
            ($0, B.CategorySettings(enabled: false, quietStartMinuteOfDay: 0, quietEndMinuteOfDay: 1,
                                    minIntervalSeconds: 99_999))
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

    @Test func stateAndSettingsRoundTripCodable() throws {
        let state = B.State(lastDeliveredAt: ["pumpAlert": at(9, 0)], dayKey: "2026-1-1",
                            deliveredToday: 3, mealDeliveredToday: 1, notifiedEpisodes: ["ep1"])
        let s2 = try JSONDecoder().decode(B.State.self, from: JSONEncoder().encode(state))
        #expect(s2 == state)
        let cfg = B.CategorySettings(enabled: true, quietStartMinuteOfDay: 1320, quietEndMinuteOfDay: 420, minIntervalSeconds: 300)
        #expect((try JSONDecoder().decode(B.CategorySettings.self, from: JSONEncoder().encode(cfg))) == cfg)
        let budget = B.Budget(dailyTotal: 40, dailyMeal: 6)
        #expect((try JSONDecoder().decode(B.Budget.self, from: JSONEncoder().encode(budget))) == budget)
    }
}
