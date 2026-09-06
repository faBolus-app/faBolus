import Testing
import Foundation
@testable import faBolusCore

/// Pins that safety categories resolve through the unified ladder — a transient snooze / rate-limit /
/// budget can never silence one, but a deliberate ladder Off (aimed OR inherited from a source rule) can —
/// and that governed gates suppress only when they should.
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

    @Test func exactlyTheFiveSafetySetCategories() {
        // The safety set is exactly these five app-own categories. They all default to Alert and are all
        // user-tunable down to Off through the ladder — there is no longer a "non-configurable" member
        // (`pumpConnectionUnstable` gained a settings row) and no "trio" (it was always five).
        let safety = Set(C.allCases.filter { $0.isSafetySet }.map(\.rawValue))
        #expect(
            safety == [
                "pumpDisconnect", "bolusReconciliation", "cgmDataLoss", "pumpConnectionUnstable", "urgentLowGlucose"
            ])
    }

    @Test func isPumpSourcedClassifiesOnlyThePumpAlertCategory() {
        // pumpAlert is the sole pump-sourced category; every other category (incl. all five safety-set
        // categories) is app-generated.
        #expect(Set(C.allCases.filter { $0.isPumpSourced }.map(\.rawValue)) == ["pumpAlert"])
    }

    @Test func bolusDeliveryFailedIsGovernedNotASafetyCategory() {
        // A FAILED / BLOCKED delivery notification. The owner decided it is SUPPRESSIBLE (unlike the safety
        // categories) — it defaults ON and can be disabled. It can NO LONGER be snoozed (owner decision
        // 2026-08-30 — an unresolved-dose alert must not be one-tap silenceable; see
        // `Category.permitsSilencingAction`), which is what the last arm pins. (The INDETERMINATE outcome
        // it is deliberately NOT posted for stays a `bolusReconciliation` concern, and that category IS in
        // the safety set.)
        #expect(!C.bolusDeliveryFailed.isSafetySet)
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

    /// `bolusIndeterminate` is governed (suppressible), not in the safety set, and ON by default.
    @Test func bolusIndeterminateIsGovernedNotSafetySetAndDefaultEnabled() {
        #expect(!C.bolusIndeterminate.isSafetySet)
        #expect(C.bolusIndeterminate.defaultEnabled)
        #expect(!C.bolusIndeterminate.isPumpSourced)
        // Disabled → suppressed (proving it honors normal governance, unlike a safety category).
        let off = B.decide(
            msg(.bolusIndeterminate),
            settings: [.bolusIndeterminate: B.CategorySettings(enabled: false)],
            state: B.State(), now: at(9, 0), calendar: cal)
        #expect(!off.deliver && off.reason == .categoryDisabled)
    }

    /// The app-owned urgent-low alarm is its own safety-set category, decoupled from `.cgmDataLoss`:
    /// lowering `.cgmDataLoss` on the ladder must not touch `.urgentLowGlucose`'s cascade.
    @Test func urgentLowGlucoseIsAnIndependentSafetyCategoryDecoupledFromCgmDataLoss() {
        typealias R = NotificationRules
        #expect(C.urgentLowGlucose.isSafetySet)
        #expect(!C.urgentLowGlucose.isPumpSourced, "app-generated, not relayed from the pump")
        #expect(C.urgentLowGlucose.defaultEnabled)
        // The user lowered ONLY `.cgmDataLoss` to Off on the ladder.
        var rules = R.PersistedRules()
        rules.appOwnCategoryOverrides[C.cgmDataLoss.rawValue] = R.Rule(intent: .off)
        // `.urgentLowGlucose`'s cascade reads only its OWN override, so it is untouched — still Alert.
        // (Disambiguate the `cascade(for:)` overloads: `PumpMirrorGroup` also has an `.urgentLowGlucose`.)
        #expect(R.resolve(rules.cascade(for: C.urgentLowGlucose), timeSensitiveAvailable: true).phone == .alert)
        let low = B.decide(
            msg(.urgentLowGlucose), settings: [:], state: B.State(), now: at(9, 0), calendar: cal,
            rules: rules.cascade(for: C.urgentLowGlucose), timeSensitiveAvailable: true)
        #expect(low.deliver, "lowering `.cgmDataLoss` must NOT silence the urgent-low backstop (category decoupling)")
    }

    /// TRANSIENT-suppression invariant: with NO supplied cascade, every safety category is delivered
    /// unconditionally — a maximally hostile settings blob + a blown budget cannot silence one, and a
    /// safety delivery consumes no budget slot. (`.cgmDataLoss` never notifies at all, so it is refused as
    /// `.uiStateOnly` instead; asserted directly.)
    @Test func safetyCategoriesAlwaysDeliverUnderAHostileConfigWithNoCascade() {
        let settings = Dictionary(
            uniqueKeysWithValues: C.allCases.map { ($0, B.CategorySettings(enabled: false)) })
        // Day already blown past a zero budget.
        let state = B.State(dayKey: B.dayKey(at(3, 0), calendar: cal), deliveredToday: 999)
        for c in C.allCases where c.isSafetySet && c.deliversAsNotification {
            let d = B.decide(
                msg(c), settings: settings, state: state,
                budget: B.Budget(dailyTotal: 0), now: at(3, 0), calendar: cal)
            #expect(d.deliver, "\(c.rawValue) must always deliver with no cascade — transient gates cannot silence it")
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
        // `.cgmDataLoss` is refused as UI-state-only (it never notifies), consuming no budget/episode.
        let cgm = B.decide(
            msg(.cgmDataLoss), settings: settings, state: state,
            budget: B.Budget(dailyTotal: 0), now: at(3, 0), calendar: cal)
        #expect(!cgm.deliver && cgm.reason == .uiStateOnly)
        #expect(cgm.nextState.lastDeliveredAt["cgmDataLoss"] == nil)
        #expect(cgm.nextState.notifiedEpisodes.isEmpty)
    }

    /// Amendment B: a deliberate ladder Off DOES suppress a safety category — whether aimed at the category
    /// itself OR inherited from the app-own SOURCE one-move control. This is the ONLY thing that can silence
    /// a safety category, and it is always the resolver's decision (`.ruleResolvedOff`), never a transient.
    @Test func aLadderOffSuppressesEverySafetyCategoryAimedOrInheritedFromSource() {
        typealias R = NotificationRules
        for c in C.allCases where c.isSafetySet && c.deliversAsNotification {
            // Aimed: the category's own override is Off.
            var aimed = R.PersistedRules()
            aimed.appOwnCategoryOverrides[c.rawValue] = R.Rule(intent: .off)
            let aimedDecision = B.decide(
                msg(c), settings: [:], state: B.State(), now: at(9, 0), calendar: cal,
                rules: aimed.cascade(for: c), timeSensitiveAvailable: true)
            #expect(
                !aimedDecision.deliver && aimedDecision.reason == .ruleResolvedOff,
                "\(c.rawValue): an aimed ladder Off must suppress")
            // Inherited: the app-own SOURCE override is Off, the category has no override of its own.
            var inherited = R.PersistedRules()
            inherited.appOwnSourceOverride = R.Rule(intent: .off)
            let inheritedDecision = B.decide(
                msg(c), settings: [:], state: B.State(), now: at(9, 0), calendar: cal,
                rules: inherited.cascade(for: c), timeSensitiveAvailable: true)
            #expect(
                !inheritedDecision.deliver && inheritedDecision.reason == .ruleResolvedOff,
                "\(c.rawValue): an inherited source Off must cascade to safety and suppress (Amendment B)")
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
        // A safety category (no cascade) is delivered past the same exhausted budget.
        #expect(
            B.decide(
                msg(.pumpDisconnect), settings: [:], state: state, budget: budget,
                now: at(9, 0), calendar: cal
            ).deliver)
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
        // …but a safety category (no cascade) is NOT episode-gated.
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

    /// A TRANSIENT snooze never silences a safety category (write side refuses; a hand-forged read-side map
    /// is bypassed by the safety fallback), while a deliberate ladder Off DOES — proving the two are
    /// distinct mechanisms.
    @Test func aTransientSnoozeNeverSilencesSafetyButALadderOffDoes() {
        typealias R = NotificationRules
        // A governed snooze works normally: suppressed before, delivers after.
        let s = B.snooze(B.State(), category: .pumpAlert, until: at(10, 0))
        #expect(
            B.decide(msg(.pumpAlert), settings: enabled(.pumpAlert), state: s, now: at(9, 0), calendar: cal).reason
                == .snoozed)
        #expect(
            B.decide(msg(.pumpAlert), settings: enabled(.pumpAlert), state: s, now: at(10, 1), calendar: cal).deliver)
        // The write side refuses to record a snooze for a safety category…
        #expect(B.snooze(B.State(), category: .cgmDataLoss, until: at(10, 0)).snoozedUntil?["cgmDataLoss"] == nil)
        // …and even a hand-forged snooze map can't silence one (the safety fallback returns above the check).
        let forged = B.State(snoozedUntil: [
            "pumpDisconnect": at(10, 0), "cgmDataLoss": at(10, 0), "bolusReconciliation": at(10, 0)
        ])
        for c in C.allCases where c.isSafetySet && c.deliversAsNotification {
            #expect(
                B.decide(msg(c), settings: [:], state: forged, now: at(9, 0), calendar: cal).deliver,
                "a transient snooze — even hand-forged — can never silence a safety category")
        }
        // `.cgmDataLoss` is refused as UI-state-only, never as `.snoozed`.
        let forgedCgm = B.decide(msg(.cgmDataLoss), settings: [:], state: forged, now: at(9, 0), calendar: cal)
        #expect(forgedCgm.reason == .uiStateOnly, "refused as UI-state-only, never as `.snoozed`")
        // The SAME forged-snooze state, but now with a deliberate ladder Off cascade — THIS is the one path
        // that suppresses, proving a transient snooze and a ladder Off are distinct mechanisms.
        var lowered = R.PersistedRules()
        for c in C.allCases where c.isSafetySet && c.deliversAsNotification {
            lowered.appOwnCategoryOverrides[c.rawValue] = R.Rule(intent: .off)
            let d = B.decide(
                msg(c), settings: [:], state: forged, now: at(9, 0), calendar: cal,
                rules: lowered.cascade(for: c), timeSensitiveAvailable: true)
            #expect(
                !d.deliver && d.reason == .ruleResolvedOff,
                "\(c.rawValue): a deliberate ladder Off — not the forged snooze — is what suppresses")
        }
    }

    /// Decision 4 finalizes the still-open cross-phase question on the `.critical` axis: the
    /// `.critical`-severity budget/snooze/disable BYPASS is retired —
    /// nothing in `decide()` special-cases `.critical` any more. A GOVERNED `.pumpAlert` message
    /// (surfaced without a resolver cascade, mirroring an occlusion/empty-cartridge/pump-error alarm)
    /// is now suppressed by a hostile config REGARDLESS of severity — exactly like `.warning`.
    @Test func criticalSeverityGovernedAlarmIsNoLongerSpecialCased() {
        let settings: [C: B.CategorySettings] = [.pumpAlert: B.CategorySettings(enabled: false)]
        var state = B.State(
            lastDeliveredAt: ["pumpAlert": at(3, 0)],
            dayKey: B.dayKey(at(3, 0), calendar: cal), deliveredToday: 999)
        state = B.snooze(state, category: .pumpAlert, until: at(23, 59))
        let budget = B.Budget(dailyTotal: 0)
        let crit = B.decide(
            criticalAlarm(), settings: settings, state: state, budget: budget, now: at(3, 30), calendar: cal)
        #expect(
            !crit.deliver && crit.reason == .categoryDisabled,
            "a `.critical`-severity governed alarm with no resolver cascade is suppressed just like any other severity — the bypass no longer exists")
        let warn = B.Message(category: .pumpAlert, severity: .warning, title: "t", body: "b", dedupeKey: "occ")
        let warnDecision = B.decide(
            warn, settings: settings, state: state, budget: budget, now: at(3, 30), calendar: cal)
        #expect(!warnDecision.deliver && warnDecision.reason == crit.reason, "severity no longer changes the outcome")
    }

    @Test func criticalAlarmStillHonorsOneNotificationPerEpisode() {
        // The nuance vs a safety category: a critical governed alarm is NOT re-delivered every poll. The
        // pump re-raises an ACTIVE alarm each cycle; re-notification is driven by forgetEpisode (dropping
        // the episode from state), NOT by ignoring the dedup here — else an active occlusion would spam a
        // notification every few seconds.
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
            deliveredToday: 3, notifiedEpisodes: ["ep1"],
            snoozedUntil: ["pumpAlert": at(9, 0)])
        let s2 = try JSONDecoder().decode(B.State.self, from: JSONEncoder().encode(state))
        #expect(s2 == state)
        let cfg = B.CategorySettings(enabled: true)
        #expect((try JSONDecoder().decode(B.CategorySettings.self, from: JSONEncoder().encode(cfg))) == cfg)
        let budget = B.Budget(dailyTotal: 40)
        #expect((try JSONDecoder().decode(B.Budget.self, from: JSONEncoder().encode(budget))) == budget)
        // A pre-this-plan blob (carrying now-deleted keys: the old quiet-hours window, the retired
        // safety-ack flag, the meal sub-budget counter, and stand-in names for two other retired governance
        // keys) still decodes — synthesized `Decodable` never fails on an EXTRA key, only a missing
        // non-optional one. Stand-in names are used (not the literal historical spelling) so this fixture
        // does not itself become residue of the names this plan retires.
        let preFieldJSON = """
            {"enabled":true,"quietStartMinuteOfDay":0,"quietEndMinuteOfDay":0,"userAcknowledgedSafetyDisable":true,"retiredMealSubBudgetKey":0,"retiredBypassFlagKey":true}
            """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(B.CategorySettings.self, from: preFieldJSON)
        #expect(decoded.enabled == true, "a pre-field blob must decode, ignoring every unrecognized key")
    }

    // MARK: - Budget exemption + typed urgency

    /// Recording a safety-set OR `.error`-severity delivery does NOT increment `deliveredToday` — a
    /// flapping disconnect posting repeated `.error` escalation steps must never exhaust the budget that
    /// gates a genuine `bolusDeliveryFailed`.
    @Test func safetySetOrErrorSeverityDeliveryIsBudgetExempt() {
        let state = B.State(dayKey: B.dayKey(at(9, 0), calendar: cal))
        // A safety-set category, plain severity, no cascade.
        let safety = B.decide(msg(.pumpDisconnect), settings: [:], state: state, now: at(9, 0), calendar: cal)
        #expect(
            safety.deliver && safety.nextState.deliveredToday == 0,
            "a safety-set delivery must not increment deliveredToday")
        // A GOVERNED category at `.error` severity (mirrors a disconnect-escalation-style message that
        // happened to be governed) is ALSO exempt — the exemption keys on severity, not only category.
        let errGoverned = B.Message(category: .pumpAlert, severity: .error, title: "t", body: "b", dedupeKey: "e1")
        let errDecision = B.decide(
            errGoverned, settings: enabled(.pumpAlert), state: safety.nextState, now: at(9, 1), calendar: cal)
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

    /// The safety set is exactly the five app-own safety categories — the marker that replaces the retired
    /// never-suppressible tier for a category on the unified ladder.
    @Test func isSafetySetMarksExactlyTheFiveSafetyCategories() {
        #expect(
            Set(C.allCases.filter { $0.isSafetySet }.map(\.rawValue))
                == ["pumpDisconnect", "bolusReconciliation", "cgmDataLoss", "pumpConnectionUnstable", "urgentLowGlucose"])
    }

    /// `.pumpDisconnect` resolves delivery through the SAME resolver a pump-mirror category uses,
    /// source=appOwn. The Alert DEFAULT delivers on BOTH capability states (never capability-dependent); a
    /// user-RAISED Urgent resolves to `.urgent` only when the capability is present (else the ladder tops
    /// out at Alert); Off suppresses.
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

    /// The resolver routing in `decide()` is CATEGORY-AGNOSTIC — any category with a
    /// supplied cascade resolves through it, not through an enumerated allowlist of category names.
    /// Proven with a category that is neither `.pumpAlert` nor in the safety set.
    @Test func anyCategoryWithASuppliedCascadeRoutesThroughTheResolver() {
        typealias R = NotificationRules
        let offCascade = R.Cascade(category: .init(intent: .off))
        let d = B.decide(
            msg(.remoteBolusRejected), settings: enabled(.remoteBolusRejected), state: B.State(),
            now: at(9, 0), calendar: cal,
            rules: offCascade, timeSensitiveAvailable: true)
        #expect(
            !d.deliver && d.reason == .ruleResolvedOff,
            "a governed category outside the pumpAlert/safety-set allowlist must still resolve through the SAME resolver when a caller supplies a cascade — the routing is not hardcoded per category"
        )
    }

    /// `pumpConnectionUnstable` is now a full safety-set member: it is user-tunable to Off through the
    /// ladder (it gained a settings row), a transient snooze still cannot silence it, and lowering a
    /// DIFFERENT safety category does not touch it.
    @Test func pumpConnectionUnstableIsATunableSafetyCategory() {
        typealias R = NotificationRules
        #expect(C.pumpConnectionUnstable.isSafetySet)
        // A transient snooze (write side) is refused, exactly like every other safety category.
        #expect(
            B.snooze(B.State(), category: .pumpConnectionUnstable, until: at(10, 0))
                .snoozedUntil?["pumpConnectionUnstable"] == nil)
        // Lowering `.pumpDisconnect` to Off does not touch `.pumpConnectionUnstable` (independent overrides).
        var rules = R.PersistedRules()
        rules.appOwnCategoryOverrides[C.pumpDisconnect.rawValue] = R.Rule(intent: .off)
        let survives = B.decide(
            msg(.pumpConnectionUnstable), settings: [:], state: B.State(), now: at(9, 0), calendar: cal,
            rules: rules.cascade(for: .pumpConnectionUnstable), timeSensitiveAvailable: true)
        #expect(survives.deliver, "lowering pumpDisconnect must not silence the flap alert")
        // But its OWN ladder Off does suppress it (it is tunable now, not un-muteable).
        var aimed = R.PersistedRules()
        aimed.appOwnCategoryOverrides[C.pumpConnectionUnstable.rawValue] = R.Rule(intent: .off)
        let lowered = B.decide(
            msg(.pumpConnectionUnstable), settings: [:], state: B.State(), now: at(9, 0), calendar: cal,
            rules: aimed.cascade(for: .pumpConnectionUnstable), timeSensitiveAvailable: true)
        #expect(!lowered.deliver && lowered.reason == .ruleResolvedOff, "the flap alert is tunable to Off")
    }

    // MARK: - The reconcile-keyed unresolved-dose disclosure: durable + loud PER-POST, not by category

    private func reconcileIndeterminate(key: String) -> B.Message {
        B.Message(
            category: .bolusIndeterminate, severity: .warning, title: "Bolus outcome unknown",
            body: "b", dedupeKey: key)
    }

    /// A reconcile-keyed unresolved-dose `.bolusIndeterminate` post resolves through the app-own ladder
    /// exactly like a safety category (the coordinator gives it that cascade), so a TRANSIENT
    /// rate-limit/daily-budget can never silence it — the resolver returns before the budget gate. A
    /// send-time `indeterminate-*` post carries no cascade and IS budget-limited (unchanged), proving the
    /// difference is PER-POST, not a category promotion.
    @Test func aReconcileKeyedUnresolvedDosePostSurvivesAHostileTransientBudgetButASendTimeOneDoesNot() {
        typealias R = NotificationRules
        let hostile = B.State(dayKey: B.dayKey(at(9, 0), calendar: cal), deliveredToday: 999)
        let budget = B.Budget(dailyTotal: 0)
        // Reconcile-keyed, WITH the app-own cascade the coordinator supplies (default Alert).
        let durable = B.decide(
            reconcileIndeterminate(key: "reconcile-watch-r1"), settings: [:], state: hostile,
            budget: budget, now: at(9, 0), calendar: cal,
            rules: R.PersistedRules().cascade(for: .bolusIndeterminate), timeSensitiveAvailable: true)
        #expect(
            durable.deliver,
            "a reconcile-keyed unresolved-dose post must deliver through the ladder despite an exhausted budget")
        // Send-time keyed, no cascade (the plain-poster path) → governed, and the exhausted budget eats it.
        let sendTime = B.decide(
            reconcileIndeterminate(key: "indeterminate-local-r1"),
            settings: enabled(.bolusIndeterminate), state: hostile,
            budget: budget, now: at(9, 0), calendar: cal)
        #expect(
            !sendTime.deliver && sendTime.reason == .dailyBudgetReached,
            "a send-time indeterminate-* post stays governed and budget-limited — unchanged")
    }

    /// Amendment B: a global/source ladder Off DOES cascade to the reconcile-keyed unresolved-dose post
    /// (nothing is immune-by-construction) — it is user-tunable to Off, but only through a deliberate
    /// ladder choice (the UI gates that behind the one-time warning), never a transient.
    @Test func aLadderOffCascadesToTheReconcileKeyedUnresolvedDosePost() {
        typealias R = NotificationRules
        var sourceOff = R.PersistedRules()
        sourceOff.appOwnSourceOverride = R.Rule(intent: .off)
        let d = B.decide(
            reconcileIndeterminate(key: "reconcile-watch-r2"), settings: [:], state: B.State(),
            now: at(9, 0), calendar: cal,
            rules: sourceOff.cascade(for: .bolusIndeterminate), timeSensitiveAvailable: true)
        #expect(
            !d.deliver && d.reason == .ruleResolvedOff,
            "an app-own source Off must cascade to the unresolved-dose post (Amendment B) — the one thing that CAN lower it")
    }

    /// A reconcile-keyed post does not consume the daily budget (the durable dose-safety disclosure must
    /// not burn the slot that gates an ordinary notification) — the same exemption the settled
    /// `.bolusReconciliation` arms already get via `isSafetySet`, extended per-post to the unresolved arms.
    @Test func aReconcileKeyedUnresolvedDosePostIsBudgetExempt() {
        typealias R = NotificationRules
        let state = B.State(dayKey: B.dayKey(at(9, 0), calendar: cal))
        let d = B.decide(
            reconcileIndeterminate(key: "reconcile-watch-r3"), settings: [:], state: state,
            now: at(9, 0), calendar: cal,
            rules: R.PersistedRules().cascade(for: .bolusIndeterminate), timeSensitiveAvailable: true)
        #expect(
            d.deliver && d.nextState.deliveredToday == 0,
            "a reconcile-keyed unresolved-dose delivery must not increment deliveredToday")
        // A send-time indeterminate-* delivery, by contrast, DOES consume a slot (unchanged governance).
        let sendTime = B.decide(
            reconcileIndeterminate(key: "indeterminate-local-r3"),
            settings: enabled(.bolusIndeterminate), state: state, now: at(9, 1), calendar: cal)
        #expect(
            sendTime.deliver && sendTime.nextState.deliveredToday == 1,
            "a send-time indeterminate-* delivery still consumes a budget slot")
    }
}
