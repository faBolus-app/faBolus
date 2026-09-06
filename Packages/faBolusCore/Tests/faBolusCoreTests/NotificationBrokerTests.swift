import Testing
import Foundation
@testable import faBolusCore

/// Pins that never-suppressible safety categories cannot be dropped by settings or
/// budget, and that governed gates suppress only when they should.
@Suite struct NotificationBrokerTests {
    typealias B = NotificationBroker
    typealias C = NotificationBroker.Category

    private let cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private func at(_ h: Int, _ m: Int, day: Int = 1) -> Date {
        cal.date(from: DateComponents(year: 2026, month: 1, day: day, hour: h, minute: m))!
    }
    private func msg(_ c: C, key: String = "k", episode: String? = nil) -> B.Message {
        B.Message(category: c, severity: .warning, title: "t", body: "b", dedupeKey: key, episodeKey: episode)
    }
    /// One enabled, unconstrained setting for a governed category (isolate the gate under test).
    private func enabled(_ c: C) -> [C: B.CategorySettings] {
        [c: B.CategorySettings(enabled: true)]
    }
    /// A CRITICAL-severity alarm on the GOVERNED `.pumpAlert` category — exactly what the coordinator
    /// builds for a pump `kind == .alarm` (occlusion / empty-cartridge / pump-error).
    private func criticalAlarm(episode: String? = nil) -> B.Message {
        B.Message(
            category: .pumpAlert, severity: .critical, title: "Occlusion", body: "b", dedupeKey: "occ",
            episodeKey: episode)
    }

    @Test func exactlyTheNeverSuppressibleSafetyCategories() {
        // `pumpConnectionUnstable` is a fourth never-suppressible category (the non-muteable flap alert).
        // The original trio stays user-configurable; the flap one is NOT.
        // `urgentLowGlucose` is a fifth never-suppressible category — the app-owned urgent-low backstop,
        // decoupled from `.cgmDataLoss` so disabling the "CGM data lost" banner can never silence it.
        let safety = Set(C.allCases.filter { $0.neverSuppressible }.map(\.rawValue))
        #expect(
            safety == [
                "pumpDisconnect", "bolusReconciliation", "cgmDataLoss", "pumpConnectionUnstable", "urgentLowGlucose"
            ])
        let configurableTrio = Set(C.allCases.filter { $0.neverSuppressible && $0.isUserConfigurable }.map(\.rawValue))
        #expect(
            configurableTrio == ["pumpDisconnect", "bolusReconciliation", "cgmDataLoss", "urgentLowGlucose"],
            "the original trio plus the app-owned urgent-low alarm are user-configurable; only the flap alert has no disable path"
        )
    }

    @Test func isPumpSourcedClassifiesOnlyThePumpAlertCategory() {
        // pumpAlert is the sole pump-sourced category; every other category (incl. all five
        // never-suppressible safety categories) is app-generated.
        #expect(Set(C.allCases.filter { $0.isPumpSourced }.map(\.rawValue)) == ["pumpAlert"])
    }

    @Test func bolusDeliveryFailedIsGovernedNotASafetyCategory() {
        // A FAILED / BLOCKED delivery notification. The owner decided it is
        // SUPPRESSIBLE (unlike the three safety categories) — it defaults ON and can be disabled. It can
        // NO LONGER be snoozed (owner decision 2026-08-30 — an unresolved-dose alert must not be
        // one-tap silenceable; see `Category.permitsSilencingAction`), which is what the last arm pins.
        // (The INDETERMINATE outcome it is deliberately NOT posted for stays a `bolusReconciliation`
        // concern, and that category IS never-suppressible.)
        #expect(!C.bolusDeliveryFailed.neverSuppressible)
        #expect(C.bolusDeliveryFailed.defaultEnabled)
        // Disabled → suppressed. A deliberate per-category disable is still honored.
        let off = B.decide(
            msg(.bolusDeliveryFailed),
            settings: [.bolusDeliveryFailed: B.CategorySettings(enabled: false)],
            state: B.State(), now: at(9, 0), calendar: cal)
        #expect(!off.deliver && off.reason == .categoryDisabled)
        // Snooze is REFUSED on both sides: the write side records nothing, and even a hand-forged snooze
        // map cannot suppress it on the read side.
        let snoozed = B.snooze(B.State(), category: .bolusDeliveryFailed, until: at(10, 0))
        #expect(snoozed.snoozedUntil?["bolusDeliveryFailed"] == nil, "the write side must refuse the snooze")
        let forged = B.State(snoozedUntil: ["bolusDeliveryFailed": at(10, 0)])
        let d = B.decide(
            msg(.bolusDeliveryFailed), settings: enabled(.bolusDeliveryFailed),
            state: forged, now: at(9, 0), calendar: cal)
        #expect(d.deliver, "an unresolved-dose alert must never be silenced by a snooze")
    }

    /// `bolusIndeterminate` is governed (suppressible), not in the never-suppressible set, and ON by
    /// default.
    @Test func bolusIndeterminateIsGovernedNotNeverSuppressibleAndDefaultEnabled() {
        #expect(!C.bolusIndeterminate.neverSuppressible)
        #expect(C.bolusIndeterminate.defaultEnabled)
        #expect(!C.bolusIndeterminate.isPumpSourced)
        // Disabled → suppressed (proving it honors normal governance, unlike the trio).
        let off = B.decide(
            msg(.bolusIndeterminate),
            settings: [.bolusIndeterminate: B.CategorySettings(enabled: false)],
            state: B.State(), now: at(9, 0), calendar: cal)
        #expect(!off.deliver && off.reason == .categoryDisabled)
    }

    /// The app-owned urgent-low alarm has its own never-suppressible category, decoupled from
    /// `.cgmDataLoss`. Disabling + acknowledging `.cgmDataLoss` must not silence `.urgentLowGlucose`.
    @Test func urgentLowGlucoseIsAnIndependentNeverSuppressibleCategoryDecoupledFromCgmDataLoss() {
        #expect(C.urgentLowGlucose.neverSuppressible)
        #expect(C.urgentLowGlucose.isUserConfigurable, "it has its own acknowledged-disable row, like the trio")
        #expect(!C.urgentLowGlucose.isPumpSourced, "app-generated, not relayed from the pump")
        #expect(C.urgentLowGlucose.defaultEnabled)
        // The user has explicitly disabled + acknowledged ONLY `.cgmDataLoss`.
        let settings: [C: B.CategorySettings] = [
            .cgmDataLoss: B.CategorySettings(enabled: false, userAcknowledgedSafetyDisable: true)
        ]
        // `.cgmDataLoss` itself does not deliver — since 2026-08-30 it is UI state only, so it is refused
        // as `.uiStateOnly` BEFORE the acknowledged-disable escape is ever consulted.
        let cgm = B.decide(msg(.cgmDataLoss), settings: settings, state: B.State(), now: at(9, 0), calendar: cal)
        #expect(!cgm.deliver && cgm.reason == .uiStateOnly)
        // `.urgentLowGlucose` is UNAFFECTED — its own category still delivers.
        let low = B.decide(msg(.urgentLowGlucose), settings: settings, state: B.State(), now: at(9, 0), calendar: cal)
        #expect(low.deliver, "disabling `.cgmDataLoss` must NOT silence the urgent-low backstop (category decoupling)")
    }

    @Test func safetyCategoriesAlwaysDeliverEvenFullyLocked() {
        // A trio delivers UNLESS the user acknowledged the safety-disable warning. Maximally hostile
        // config without the paired acknowledgment has zero effect on never-suppressible categories.
        let settings = Dictionary(
            uniqueKeysWithValues: C.allCases.map { ($0, B.CategorySettings(enabled: false)) })
        // Day already blown past a zero budget.
        let state = B.State(dayKey: B.dayKey(at(3, 0), calendar: cal), deliveredToday: 999, mealDeliveredToday: 999)
        // `.cgmDataLoss` is excluded: it is never-suppressible AND never a notification at all since
        // 2026-08-30 (`deliversAsNotification == false`), so "always delivers" does not apply to it. Its
        // own refusal is asserted explicitly at the end of this test, so the coverage is not just dropped.
        for c in C.allCases where c.neverSuppressible && c.deliversAsNotification {
            let d = B.decide(
                msg(c), settings: settings, state: state,
                budget: B.Budget(dailyTotal: 0, dailyMeal: 0), now: at(3, 0), calendar: cal)
            #expect(d.deliver, "\(c.rawValue) must always deliver when the ack flag is unset")
            // A never-suppressible delivery is budget-exempt: lastDeliveredAt/notifiedEpisodes advance,
            // but the budget counter must stay untouched so a flapping safety category can never exhaust
            // the budget that gates a genuine bolusDeliveryFailed.
            #expect(
                d.nextState.deliveredToday == 999,
                "\(c.rawValue) is budget-exempt — the daily counter must not move")
            #expect(
                d.nextState.lastDeliveredAt[c.rawValue] == at(3, 0),
                "\(c.rawValue) must still be recorded via lastDeliveredAt")
        }
        // A governed category in the SAME config is suppressed (proves the config really is hostile).
        let g = B.decide(
            msg(.pumpAlert), settings: settings, state: state,
            budget: B.Budget(dailyTotal: 0), now: at(3, 0), calendar: cal)
        #expect(!g.deliver)
        // The SAME maximally hostile config, but with the paired acknowledgment ALSO set — this is the
        // one and only condition under which a user-configurable never-suppressible member suppresses.
        let acknowledged = Dictionary(
            uniqueKeysWithValues: C.allCases.map {
                ($0, B.CategorySettings(enabled: false, userAcknowledgedSafetyDisable: true))
            })
        for c in C.allCases where c.neverSuppressible && c.isUserConfigurable && c.deliversAsNotification {
            let d = B.decide(
                msg(c), settings: acknowledged, state: state,
                budget: B.Budget(dailyTotal: 0, dailyMeal: 0), now: at(3, 0), calendar: cal)
            #expect(
                !d.deliver && d.reason == .categoryDisabled,
                "\(c.rawValue) must suppress once the user acknowledged disabling it")
        }
        // The excluded category, asserted directly: `.cgmDataLoss` is refused under the SAME hostile
        // config for a policy reason (`.uiStateOnly`), not because the user disabled anything, and it
        // consumes no budget slot and records no episode on the way out.
        let cgm = B.decide(
            msg(.cgmDataLoss), settings: settings, state: state,
            budget: B.Budget(dailyTotal: 0, dailyMeal: 0), now: at(3, 0), calendar: cal)
        #expect(!cgm.deliver && cgm.reason == .uiStateOnly)
        #expect(cgm.nextState.lastDeliveredAt["cgmDataLoss"] == nil)
        #expect(cgm.nextState.notifiedEpisodes.isEmpty)
        // The non-configurable never-suppressible category (`pumpConnectionUnstable`) has no
        // acknowledged-disable path — even a paired ack cannot suppress it.
        for c in C.allCases where c.neverSuppressible && !c.isUserConfigurable {
            let d = B.decide(
                msg(c), settings: acknowledged, state: state,
                budget: B.Budget(dailyTotal: 0, dailyMeal: 0), now: at(3, 0), calendar: cal)
            #expect(d.deliver, "\(c.rawValue) is non-configurable — a forged acknowledged-disable must NOT suppress it")
        }
    }

    @Test func disabledGovernedCategoryIsSuppressed() {
        let d = B.decide(
            msg(.pumpAlert), settings: [.pumpAlert: .init(enabled: false)],
            state: B.State(), now: at(12, 0), calendar: cal)
        #expect(d.reason == .categoryDisabled)
    }

    @Test func dailyBudgetCapsGovernedButNotSafety() {
        let state = B.State(dayKey: B.dayKey(at(9, 0), calendar: cal), deliveredToday: 2)
        let budget = B.Budget(dailyTotal: 2)
        #expect(
            B.decide(
                msg(.pumpAlert), settings: enabled(.pumpAlert), state: state, budget: budget,
                now: at(9, 0), calendar: cal
            ).reason == .dailyBudgetReached)
        // A safety category is delivered past the same exhausted budget.
        #expect(
            B.decide(
                msg(.pumpDisconnect), settings: [:], state: state, budget: budget,
                now: at(9, 0), calendar: cal
            ).deliver)
    }

    @Test func mealSubBudgetCapsMealRemindersBeforeTheTotal() {
        let state = B.State(dayKey: B.dayKey(at(9, 0), calendar: cal), deliveredToday: 3, mealDeliveredToday: 2)
        let budget = B.Budget(dailyTotal: 40, dailyMeal: 2)  // total has room; meal is spent
        let d = B.decide(
            msg(.mealReminder), settings: enabled(.mealReminder), state: state, budget: budget,
            now: at(9, 0), calendar: cal)
        #expect(d.reason == .mealBudgetReached)
    }

    @Test func oneNotificationPerEpisodeForGovernedButSafetyStillRepeats() {
        let s = enabled(.pumpAlert)
        let first = B.decide(
            msg(.pumpAlert, episode: "ep1"), settings: s, state: B.State(), now: at(9, 0), calendar: cal)
        #expect(first.deliver)
        // A governed repeat of the same episode is dropped…
        let second = B.decide(
            msg(.pumpAlert, episode: "ep1"), settings: s, state: first.nextState, now: at(9, 5), calendar: cal)
        #expect(second.reason == .episodeAlreadyNotified)
        // …but a safety category is NOT episode-gated.
        let safety1 = B.decide(
            msg(.pumpDisconnect, episode: "epX"), settings: [:], state: B.State(), now: at(9, 0), calendar: cal)
        let safety2 = B.decide(
            msg(.pumpDisconnect, episode: "epX"), settings: [:], state: safety1.nextState, now: at(9, 5), calendar: cal)
        #expect(safety1.deliver && safety2.deliver)
    }

    @Test func dailyCountersRollOverAtADayBoundary() {
        let state = B.State(dayKey: B.dayKey(at(23, 0, day: 1), calendar: cal), deliveredToday: 39)
        // Next day, same message: the day key differs, so the counter resets before this delivery.
        let d = B.decide(
            msg(.pumpAlert), settings: enabled(.pumpAlert), state: state,
            budget: B.Budget(dailyTotal: 40), now: at(0, 5, day: 2), calendar: cal)
        #expect(d.deliver)
        #expect(d.nextState.deliveredToday == 1)
    }

    /// The invariant that outlived the force-protection axis: the identities the old axis force-protected
    /// each resolve to a LOUD pump-mirror rung by default — none is silent (`.off`) out of the box. Stated
    /// through the unified resolver's classifier + default rung, not a boolean safety flag.
    @Test func theFormerlyForceProtectedIdentitiesAreLoudByDefaultNoneSilent() {
        typealias R = NotificationRules
        // The identities the removed axis force-protected: alarms 2/26; alerts 0/17/40/41/42/48;
        // CGM alerts 11/13/14/27/39 — 13 in all.
        let alarms = [(PumpAlertKind.alarm, 2), (.alarm, 26)]
        let alerts = [(PumpAlertKind.alert, 0), (.alert, 17), (.alert, 40), (.alert, 41), (.alert, 42), (.alert, 48)]
        let cgm = [(PumpAlertKind.cgmAlert, 11), (.cgmAlert, 13), (.cgmAlert, 14), (.cgmAlert, 27), (.cgmAlert, 39)]
        for (kind, id) in alarms + alerts + cgm {
            let group = R.pumpMirrorGroup(kind: kind, id: id, isMalfunction: false)
            let intent = R.defaultIntent(for: group)
            #expect(intent >= .alert, "\(kind):\(id) must be loud (Alert or louder) by default")
            #expect(intent != .off, "\(kind):\(id) must never be silent by default")
        }
    }

    @Test func snoozeSuppressesGovernedUntilTheDeadlineButNeverSafety() {
        // Distinguishes a TRANSIENT snooze (never silences a never-suppressible category) from the
        // DELIBERATE acknowledged disable (the one path that does).
        // Snooze pumpAlert until 10:00: suppressed before, delivers after.
        let s = B.snooze(B.State(), category: .pumpAlert, until: at(10, 0))
        #expect(
            B.decide(msg(.pumpAlert), settings: enabled(.pumpAlert), state: s, now: at(9, 0), calendar: cal).reason
                == .snoozed)
        #expect(
            B.decide(msg(.pumpAlert), settings: enabled(.pumpAlert), state: s, now: at(10, 1), calendar: cal).deliver)
        // The write side refuses to record a snooze for a safety category…
        #expect(B.snooze(B.State(), category: .cgmDataLoss, until: at(10, 0)).snoozedUntil?["cgmDataLoss"] == nil)
        // …and even a hand-forged snooze map can't silence one (the read side bypasses it above the check).
        let forged = B.State(snoozedUntil: [
            "pumpDisconnect": at(10, 0), "cgmDataLoss": at(10, 0), "bolusReconciliation": at(10, 0)
        ])
        for c in C.allCases where c.neverSuppressible && c.deliversAsNotification {
            #expect(
                B.decide(msg(c), settings: [:], state: forged, now: at(9, 0), calendar: cal).deliver,
                "a transient snooze — even hand-forged — can never silence a trio")
        }
        // `.cgmDataLoss` is excluded from the loop only because it no longer notifies at all — the forged
        // snooze is still not what stops it.
        let forgedCgm = B.decide(msg(.cgmDataLoss), settings: [:], state: forged, now: at(9, 0), calendar: cal)
        #expect(forgedCgm.reason == .uiStateOnly, "refused as UI-state-only, never as `.snoozed`")
        // NEW arm: the SAME forged-snooze state, but now with the deliberate acknowledged disable ALSO
        // set — THIS is the one path that suppresses, proving snooze and acknowledged-disable are
        // distinct mechanisms (a transient snooze is refused; a deliberate acknowledgment is honored).
        let ackedWhileForged = Dictionary(
            uniqueKeysWithValues: C.allCases.map {
                ($0, B.CategorySettings(enabled: false, userAcknowledgedSafetyDisable: true))
            })
        for c in C.allCases where c.neverSuppressible && c.isUserConfigurable && c.deliversAsNotification {
            let d = B.decide(msg(c), settings: ackedWhileForged, state: forged, now: at(9, 0), calendar: cal)
            #expect(
                !d.deliver && d.reason == .categoryDisabled,
                "\(c.rawValue): the acknowledged disable — not the forged snooze — is what suppresses")
        }
    }

    @Test func criticalGovernedAlarmBypassesEveryUserAndBudgetSuppression() {
        // An occlusion / empty-cartridge / pump-error alarm is surfaced as the GOVERNED
        // `.pumpAlert` category but with `Severity.critical`. It must survive a maximally hostile config —
        // category disabled, a snooze in force, and a day past a zero budget — because critical alarms
        // bypass the budget unconditionally (the axis that once made this toggle-able is retired). A
        // `.warning` in the SAME config is suppressed (proving the config is genuinely hostile).
        let settings: [C: B.CategorySettings] = [.pumpAlert: B.CategorySettings(enabled: false)]
        var state = B.State(
            lastDeliveredAt: ["pumpAlert": at(3, 0)],
            dayKey: B.dayKey(at(3, 0), calendar: cal), deliveredToday: 999)
        state = B.snooze(state, category: .pumpAlert, until: at(23, 59))
        let budget = B.Budget(dailyTotal: 0)
        let crit = B.decide(
            criticalAlarm(), settings: settings, state: state, budget: budget, now: at(3, 30), calendar: cal)
        #expect(crit.deliver, "a CRITICAL pump alarm must not be droppable by disable/snooze/budget")
        #expect(crit.nextState.deliveredToday == 1000, "still recorded")
        let warn = B.Message(category: .pumpAlert, severity: .warning, title: "t", body: "b", dedupeKey: "occ")
        #expect(
            !B.decide(warn, settings: settings, state: state, budget: budget, now: at(3, 30), calendar: cal).deliver)
    }

    @Test func criticalAlarmStillHonorsOneNotificationPerEpisode() {
        // The nuance vs a neverSuppressible category: a critical governed alarm is NOT re-delivered every
        // poll. The pump re-raises an ACTIVE alarm each cycle; re-notification is driven by forgetEpisode
        // (dropping the episode from state), NOT by ignoring the dedup here — else an active occlusion
        // would spam a notification every few seconds.
        let s = enabled(.pumpAlert)
        let first = B.decide(
            criticalAlarm(episode: "occ-1"), settings: s, state: B.State(), now: at(9, 0), calendar: cal)
        #expect(first.deliver)
        let again = B.decide(
            criticalAlarm(episode: "occ-1"), settings: s, state: first.nextState, now: at(9, 1), calendar: cal)
        #expect(again.reason == .episodeAlreadyNotified, "an active critical alarm dedupes per episode (no spam)")
    }

    @Test func stateAndSettingsRoundTripCodable() throws {
        let state = B.State(
            lastDeliveredAt: ["pumpAlert": at(9, 0)], dayKey: "2026-1-1",
            deliveredToday: 3, mealDeliveredToday: 1, notifiedEpisodes: ["ep1"],
            snoozedUntil: ["pumpAlert": at(9, 0)])
        let s2 = try JSONDecoder().decode(B.State.self, from: JSONEncoder().encode(state))
        #expect(s2 == state)
        let cfg = B.CategorySettings(enabled: true)
        #expect((try JSONDecoder().decode(B.CategorySettings.self, from: JSONEncoder().encode(cfg))) == cfg)
        let budget = B.Budget(dailyTotal: 40, dailyMeal: 6)
        #expect((try JSONDecoder().decode(B.Budget.self, from: JSONEncoder().encode(budget))) == budget)
        // userAcknowledgedSafetyDisable round-trips when set…
        let cfg3 = B.CategorySettings(enabled: false, userAcknowledgedSafetyDisable: true)
        #expect((try JSONDecoder().decode(B.CategorySettings.self, from: JSONEncoder().encode(cfg3))) == cfg3)
        #expect(
            (try JSONDecoder().decode(B.CategorySettings.self, from: JSONEncoder().encode(cfg3)))
                .userAcknowledgedSafetyDisable == true)
        // …AND a pre-this-plan blob (still carrying the now-deleted `quietStartMinuteOfDay` /
        // `quietEndMinuteOfDay` keys plus two OTHER now-retired governance keys AND missing the ack key
        // entirely) still decodes — the now-unrecognized keys are silently ignored (synthesized
        // `Decodable` never fails on an EXTRA key, only a missing non-optional one), and the ack field
        // defaults to nil. The two other retired keys are represented by stand-in names here (not their
        // literal historical spelling) so this fixture does not itself become residue of the names this
        // plan retires.
        let preFieldJSON = """
            {"enabled":true,"quietStartMinuteOfDay":0,"quietEndMinuteOfDay":0,"retiredRateLimitKey":0,"retiredBypassFlagKey":true}
            """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(B.CategorySettings.self, from: preFieldJSON)
        #expect(
            decoded.userAcknowledgedSafetyDisable == nil, "a pre-field blob must decode with the ack flag nil, not fail"
        )
        #expect(decoded.enabled == true)
    }

    // MARK: - Budget exemption + typed urgency

    /// Recording a never-suppressible OR `.error`-severity delivery does NOT increment `deliveredToday` —
    /// a flapping disconnect posting repeated `.error` escalation steps must never exhaust the budget that
    /// gates a genuine `bolusDeliveryFailed`.
    @Test func neverSuppressibleOrErrorSeverityDeliveryIsBudgetExempt() {
        let state = B.State(dayKey: B.dayKey(at(9, 0), calendar: cal))
        // A never-suppressible trio category, plain severity.
        let trio = B.decide(msg(.pumpDisconnect), settings: [:], state: state, now: at(9, 0), calendar: cal)
        #expect(
            trio.deliver && trio.nextState.deliveredToday == 0,
            "a never-suppressible delivery must not increment deliveredToday")
        // A GOVERNED category at `.error` severity (mirrors a disconnect-escalation-style message that
        // happened to be governed) is ALSO exempt — the exemption keys on severity, not only category.
        let errGoverned = B.Message(category: .pumpAlert, severity: .error, title: "t", body: "b", dedupeKey: "e1")
        let errDecision = B.decide(
            errGoverned, settings: enabled(.pumpAlert), state: trio.nextState, now: at(9, 1), calendar: cal)
        #expect(
            errDecision.deliver && errDecision.nextState.deliveredToday == 0,
            "an `.error`-severity delivery must not increment deliveredToday even on a governed category")
    }

    /// Interleaving several budget-exempt safety deliveries with ONE genuinely-counted ordinary delivery
    /// never lets the exempt deliveries perturb the counter —
    /// proving there is no generic per-dedupeKey "withdraw refund" that could undercount (no such refund
    /// exists in `NotificationBroker` at all: since safety/`.error` deliveries never consumed a slot in the
    /// first place, `withdraw`-ing one — an app-layer, OS-request-removal operation with no counterpart
    /// here — has nothing to refund).
    @Test func budgetExemptDeliveriesNeverUndercountGenuinelyCountedOrdinaryOnes() {
        var state = B.State(dayKey: B.dayKey(at(9, 0), calendar: cal))
        for i in 0..<5 {
            let d = B.decide(
                B.Message(
                    category: .pumpDisconnect, severity: .error, title: "t", body: "b",
                    dedupeKey: "esc-\(i)"),
                settings: [:], state: state, now: at(9, 0), calendar: cal)
            #expect(d.deliver)
            state = d.nextState
        }
        #expect(state.deliveredToday == 0, "five budget-exempt safety deliveries must not touch deliveredToday")
        let ordinary = B.decide(
            msg(.pumpAlert), settings: enabled(.pumpAlert), state: state, now: at(9, 1), calendar: cal)
        #expect(ordinary.deliver)
        #expect(
            ordinary.nextState.deliveredToday == 1,
            "exactly the one genuinely-counted ordinary delivery — the exempt deliveries neither consumed nor refunded a slot"
        )
    }

    /// An ordinary suppressible delivery still increments the counter and can still be budget-limited —
    /// the exemption above must not have
    /// accidentally widened to cover governed, non-`.error`, non-safety messages.
    @Test func ordinarySuppressibleDeliveryStillIncrementsAndIsBudgetLimited() {
        let budget = B.Budget(dailyTotal: 1)
        let state = B.State(dayKey: B.dayKey(at(9, 0), calendar: cal))
        let first = B.decide(
            msg(.pumpAlert, key: "a"), settings: enabled(.pumpAlert), state: state,
            budget: budget, now: at(9, 0), calendar: cal)
        #expect(first.deliver && first.nextState.deliveredToday == 1)
        let second = B.decide(
            msg(.pumpAlert, key: "b"), settings: enabled(.pumpAlert), state: first.nextState,
            budget: budget, now: at(9, 1), calendar: cal)
        #expect(!second.deliver && second.reason == .dailyBudgetReached)
    }

    /// The unified resolver's phone intent — not a separate breakthrough predicate — decides how loud a
    /// pump-mirror alert is, and the delivery gate reads the SAME resolver, so the two cannot disagree. An
    /// unnamed, delivery-suspending alert id hits the fail-safe cell (loud), never the routine group.
    @Test func pumpMirrorLoudnessAndDeliveryComeFromTheOneResolver() {
        typealias R = NotificationRules
        // A delivery-stopped alarm defaults to Alert (loud, but NOT Urgent — the pump remains the primary
        // annunciator); the delivery gate delivers it under the same cascade.
        let alarmGroup = R.pumpMirrorGroup(kind: .alarm, id: 2, isMalfunction: false)
        #expect(R.defaultIntent(for: alarmGroup) == .alert)
        let alarmCascade = R.Cascade(category: .init(intent: R.defaultIntent(for: alarmGroup)))
        let alarmDecision = B.decide(
            msg(.pumpAlert), settings: [:], state: B.State(), now: at(9, 0), calendar: cal,
            rules: alarmCascade, timeSensitiveAvailable: true)
        #expect(alarmDecision.deliver)

        // An unnamed alert id (the delivery-suspending Control-IQ Max Insulin id 52) resolves loud, never
        // to the most-ignorable group.
        let unnamed = R.pumpMirrorGroup(kind: .alert, id: 52, isMalfunction: false)
        #expect(unnamed != .pumpRoutine)
        #expect(R.defaultIntent(for: unnamed) >= .alert)

        // A source-level Off silences the mirror in one move, and the delivery gate honors it.
        let offDecision = B.decide(
            msg(.pumpAlert), settings: [:], state: B.State(), now: at(9, 0), calendar: cal,
            rules: R.Cascade(source: .init(intent: .off)), timeSensitiveAvailable: true)
        #expect(!offDecision.deliver && offDecision.reason == .ruleResolvedOff)
    }

    /// Exactly `.pumpDisconnect` is in the "safety set" so far — the marker that
    /// replaces `neverSuppressible` semantics for a category wired onto the unified ladder. Every
    /// safety-set member is (for now, this tracer) also `neverSuppressible`; a later plan generalizes.
    @Test func isSafetySetMarksExactlyPumpDisconnectForNow() {
        #expect(Set(C.allCases.filter { $0.isSafetySet }.map(\.rawValue)) == ["pumpDisconnect"])
        for c in C.allCases where c.isSafetySet {
            #expect(c.neverSuppressible, "\(c.rawValue) is in the safety set but not neverSuppressible")
        }
    }

    /// TRACER: `.pumpDisconnect` — the first app-own category wired onto the unified
    /// ladder — resolves delivery through the SAME resolver a pump-mirror category uses, source=appOwn.
    /// The Alert DEFAULT delivers on BOTH capability states (never capability-dependent); a
    /// user-RAISED Urgent resolves to `.urgent` only when the capability is present (else the ladder
    /// tops out at Alert); Off suppresses.
    @Test func pumpDisconnectResolvesThroughTheUnifiedLadderEndToEnd() {
        typealias R = NotificationRules
        // Default (no override): Alert, delivered, on BOTH capability states — never capability-dependent.
        let defaultCascade = R.PersistedRules().cascade(for: .pumpDisconnect)
        for capability in [true, false] {
            let d = B.decide(
                msg(.pumpDisconnect), settings: [:], state: B.State(), now: at(9, 0), calendar: cal,
                rules: defaultCascade, timeSensitiveAvailable: capability)
            #expect(d.deliver, "the Alert default must deliver regardless of the time-sensitive capability")
            #expect(
                R.resolve(defaultCascade, timeSensitiveAvailable: capability).phone == .alert,
                "the Alert default must never depend on the capability")
        }
        // A user-raised Urgent, WITH the capability: resolves to `.urgent`.
        var raised = R.PersistedRules()
        raised.appOwnCategoryOverrides[C.pumpDisconnect.rawValue] = R.Rule(intent: .urgent)
        let raisedCascade = raised.cascade(for: .pumpDisconnect)
        #expect(R.resolve(raisedCascade, timeSensitiveAvailable: true).phone == .urgent)
        // The SAME user-raised Urgent, WITHOUT the capability: the ladder tops out at Alert — never a
        // silently-degraded Urgent (Decision 3).
        #expect(R.resolve(raisedCascade, timeSensitiveAvailable: false).phone == .alert)
        // Lowering to Off suppresses the post.
        var lowered = R.PersistedRules()
        lowered.appOwnCategoryOverrides[C.pumpDisconnect.rawValue] = R.Rule(intent: .off)
        let loweredCascade = lowered.cascade(for: .pumpDisconnect)
        let offDecision = B.decide(
            msg(.pumpDisconnect), settings: [:], state: B.State(), now: at(9, 0), calendar: cal,
            rules: loweredCascade, timeSensitiveAvailable: true)
        #expect(!offDecision.deliver && offDecision.reason == .ruleResolvedOff)
    }

    /// For every user-configurable never-suppressible category, suppression requires BOTH
    /// `enabled == false` AND `userAcknowledgedSafetyDisable == true`; either alone still delivers.
    @Test func trioSuppressedOnlyByAcknowledgedDisable() {
        // `.cgmDataLoss` is excluded: since 2026-08-30 it never delivers regardless of the ack flag, so
        // the AND-gate this test is about is not observable on it. `CgmGapIsUiStateNotANotificationTests`
        // owns its behaviour.
        for c in C.allCases where c.neverSuppressible && c.isUserConfigurable && c.deliversAsNotification {
            // enabled:false, ack:nil → delivers (the mandatory gate is unmet).
            let notAcked = B.decide(
                msg(c), settings: [c: B.CategorySettings(enabled: false)],
                state: B.State(), now: at(9, 0), calendar: cal)
            #expect(notAcked.deliver, "\(c.rawValue): enabled==false alone (ack nil) must still deliver")
            // enabled:true, ack:true → delivers (enabled must ALSO be false).
            let enabledButAcked = B.decide(
                msg(c),
                settings: [c: B.CategorySettings(enabled: true, userAcknowledgedSafetyDisable: true)],
                state: B.State(), now: at(9, 0), calendar: cal)
            #expect(enabledButAcked.deliver, "\(c.rawValue): enabled==true must still deliver even if ack is set")
            // enabled:false, ack:true → suppressed (the AND-gate is satisfied).
            let suppressed = B.decide(
                msg(c),
                settings: [c: B.CategorySettings(enabled: false, userAcknowledgedSafetyDisable: true)],
                state: B.State(), now: at(9, 0), calendar: cal)
            #expect(
                !suppressed.deliver && suppressed.reason == .categoryDisabled,
                "\(c.rawValue): enabled==false AND ack==true must suppress")
        }
    }

    /// The flap alert (`pumpConnectionUnstable`) is truly non-muteable. Muting `pumpDisconnect` does not
    /// touch it, and even a forged settings blob that disables it cannot suppress it.
    @Test func nonConfigurableSafetyCategoryIsTrulyNonMuteable() {
        #expect(C.pumpConnectionUnstable.neverSuppressible)
        #expect(!C.pumpConnectionUnstable.isUserConfigurable, "the flap alert must never be user-configurable")

        // (1) The user muted pump-disconnect (acknowledged-disable). The flap alert still delivers.
        let mutedPumpDisconnect: [C: B.CategorySettings] = [
            .pumpDisconnect: B.CategorySettings(enabled: false, userAcknowledgedSafetyDisable: true)
        ]
        let survives = B.decide(
            msg(.pumpConnectionUnstable), settings: mutedPumpDisconnect,
            state: B.State(), now: at(9, 0), calendar: cal)
        #expect(survives.deliver, "the flap alert must fire even when the user has muted pumpDisconnect")

        // (2) Even a forged disable of the flap category itself cannot suppress it.
        let forgedDisable: [C: B.CategorySettings] = [
            .pumpConnectionUnstable: B.CategorySettings(enabled: false, userAcknowledgedSafetyDisable: true)
        ]
        let stillDelivers = B.decide(
            msg(.pumpConnectionUnstable), settings: forgedDisable,
            state: B.State(), now: at(9, 0), calendar: cal)
        #expect(stillDelivers.deliver, "a forged disable of the non-configurable flap category must NOT suppress it")

        // Contrast: the ORIGINAL trio IS suppressible via the same acknowledged-disable blob.
        let trioSuppressed = B.decide(
            msg(.pumpDisconnect), settings: mutedPumpDisconnect,
            state: B.State(), now: at(9, 0), calendar: cal)
        #expect(
            !trioSuppressed.deliver, "the user-configurable pumpDisconnect IS suppressed by its acknowledged-disable")
    }
}
