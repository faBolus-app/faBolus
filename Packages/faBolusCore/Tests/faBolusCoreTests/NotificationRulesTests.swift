import Testing
import Foundation
@testable import faBolusCore

/// Pins the shared, unified notification-rules engine's contract: the abstract intent ladder, the
/// `pumpMirror | appOwn` source scope, the `global → source → category → perNotification` cascade
/// with inheritance, and the pure per-surface (phone + watch) resolver — plus the ONE governed
/// decision point in `NotificationBroker.decide` that reads it for the pump-mirror tracer category.
@Suite struct NotificationRulesTests {
    typealias R = NotificationRules

    // MARK: - Intent ladder

    @Test func intentLadderIsOrderedOffQuietAlertUrgent() {
        #expect(R.Intent.off < R.Intent.quiet)
        #expect(R.Intent.quiet < R.Intent.alert)
        #expect(R.Intent.alert < R.Intent.urgent)
    }

    // MARK: - Source scope

    @Test func pumpAlertIsTheSolePumpMirrorCategoryEveryOtherIsAppOwn() {
        let mirrored = Set(NotificationBroker.Category.allCases.filter { $0.notificationSource == .pumpMirror })
        #expect(mirrored == [.pumpAlert])
        let appOwn = Set(NotificationBroker.Category.allCases.filter { $0.notificationSource == .appOwn })
        #expect(appOwn == Set(NotificationBroker.Category.allCases).subtracting([.pumpAlert]))
    }

    // MARK: - Cascade / inheritance

    @Test func categoryLevelOverridesSourceLevel_andAnUnsetLevelInherits() {
        // Category beats source when both are set.
        let overridden = R.resolve(
            source: .init(intent: .alert), category: .init(intent: .quiet), timeSensitiveAvailable: true)
        #expect(overridden.phone == .quiet)

        // With the category level unset, the resolution inherits the source-level value.
        let inherited = R.resolve(source: .init(intent: .alert), category: nil, timeSensitiveAvailable: true)
        #expect(inherited.phone == .alert)
    }

    @Test func perNotificationBeatsEveryOtherLevel() {
        let resolved = R.resolve(
            global: .init(intent: .quiet), source: .init(intent: .alert), category: .init(intent: .off),
            perNotification: .init(intent: .urgent), timeSensitiveAvailable: true)
        #expect(resolved.phone == .urgent)
    }

    @Test func everyLevelUnsetResolvesToOff() {
        let resolved = R.resolve(timeSensitiveAvailable: true)
        #expect(resolved.phone == .off)
        #expect(resolved.watch == .off)
    }

    // MARK: - Time-sensitive capability (Decision 3)

    @Test func unentitledBuildCanNeverYieldUrgentOnThePhone() {
        let rule = R.Rule(intent: .urgent)
        let unentitled = R.resolve(category: rule, timeSensitiveAvailable: false)
        #expect(unentitled.phone == .alert, "the rung is absent, not a degraded alert-labelled-urgent")

        let entitled = R.resolve(category: rule, timeSensitiveAvailable: true)
        #expect(entitled.phone == .urgent)
    }

    // MARK: - Per-surface: watch never carries Urgent

    @Test func watchNeverCarriesUrgent_defaultsToFollowingThePhone() {
        let resolved = R.resolve(category: .init(intent: .urgent), timeSensitiveAvailable: true)
        #expect(resolved.phone == .urgent)
        #expect(resolved.watch == .alert, "phone Urgent follows to the watch's top rung, never a watch-Urgent")
    }

    @Test func watchFollowsPhoneByDefault_perRuleOverrideWinsWhenPresent() {
        let followed = R.resolve(category: .init(intent: .alert), timeSensitiveAvailable: true)
        #expect(followed.watch == .alert)

        let overridden = R.resolve(
            category: .init(intent: .alert, watchOverride: .off), timeSensitiveAvailable: true)
        #expect(overridden.watch == .off)
    }

    @Test func cascadeOverload_matchesTheFourParameterForm() {
        let cascade = R.Cascade(source: .init(intent: .quiet), category: .init(intent: .urgent))
        let viaCascade = R.resolve(cascade, timeSensitiveAvailable: true)
        let viaParams = R.resolve(
            global: cascade.global, source: cascade.source, category: cascade.category,
            perNotification: cascade.perNotification, timeSensitiveAvailable: true)
        #expect(viaCascade.phone == viaParams.phone)
        #expect(viaCascade.watch == viaParams.watch)
    }

    // MARK: - Purity: deterministic, no hidden state

    @Test func resolverIsDeterministic_sameInputsSameOutputAcrossRepeatedCalls() {
        let cascade = R.Cascade(category: .init(intent: .alert))
        let first = R.resolve(cascade, timeSensitiveAvailable: false)
        let second = R.resolve(cascade, timeSensitiveAvailable: false)
        #expect(first == second)
    }

    // MARK: - `NotificationBroker.decide` reads the ONE resolver for the pump-mirror tracer category

    private func msg(_ c: NotificationBroker.Category = .pumpAlert, key: String = "k") -> NotificationBroker.Message {
        NotificationBroker.Message(category: c, severity: .warning, title: "t", body: "b", dedupeKey: key)
    }

    @Test func pumpAlertRoutesThroughTheResolverWhenACascadeIsSupplied() {
        let offCascade = R.Cascade(category: .init(intent: .off))
        let decision = NotificationBroker.decide(
            msg(), settings: [:], state: .init(), now: Date(timeIntervalSince1970: 0), rules: offCascade,
            timeSensitiveAvailable: true)
        #expect(!decision.deliver)
        #expect(decision.reason == .ruleResolvedOff)
    }

    @Test func pumpAlertDeliversWhenTheResolverResolvesAboveOff() {
        let alertCascade = R.Cascade(category: .init(intent: .alert))
        let decision = NotificationBroker.decide(
            msg(), settings: [:], state: .init(), now: Date(timeIntervalSince1970: 0), rules: alertCascade,
            timeSensitiveAvailable: true)
        #expect(decision.deliver)
        #expect(decision.reason == nil)
    }

    @Test func pumpAlertWithNoCascadeStaysOnTheExistingGovernedPath() {
        // Additive: a caller that omits `rules` keeps the pre-existing settings-driven behavior
        // byte-for-byte — proves `decide`'s signature stayed stable for every existing caller.
        let decision = NotificationBroker.decide(
            msg(), settings: [.pumpAlert: .init(enabled: false)], state: .init(),
            now: Date(timeIntervalSince1970: 0))
        #expect(!decision.deliver)
        #expect(decision.reason == .categoryDisabled)
    }

    // MARK: - The full pump-mirror taxonomy (the six groups on the `category` cascade level)

    /// Group 1 is a KIND rule: every alarm AND every malfunction (a malfunction arrives as `.alarm`
    /// with the dismissable flag false) resolves to the delivery-stopped group, so an unknown alarm/
    /// malfunction bit fails safe here rather than in a routine group.
    @Test func deliveryStoppedIsAKindRuleOverEveryAlarmAndEveryMalfunction() {
        // A named occlusion alarm.
        #expect(R.pumpMirrorGroup(kind: .alarm, id: 2, isMalfunction: false) == .deliveryStopped)
        // An UNKNOWN alarm bit still lands in delivery-stopped by KIND.
        #expect(R.pumpMirrorGroup(kind: .alarm, id: 63, isMalfunction: false) == .deliveryStopped)
        // A malfunction (decodes as `.alarm`, dismissable false) — the discriminator makes the KIND
        // rule statable even for an unnamed malfunction bit.
        #expect(R.pumpMirrorGroup(kind: .alarm, id: 5, isMalfunction: true) == .deliveryStopped)
    }

    /// Every named alert / CGM-alert / reminder id lands in its group per the inventory-backed table.
    @Test func knownIdsMapToTheirGroupRung() {
        // Running low (insulin or power).
        for id in [0, 1, 2, 3, 5, 7, 17] {
            #expect(R.pumpMirrorGroup(kind: .alert, id: id, isMalfunction: false) == .runningLow)
        }
        // Urgent low glucose — the single CGM id.
        #expect(R.pumpMirrorGroup(kind: .cgmAlert, id: 1, isMalfunction: false) == .urgentLowGlucose)
        // Glucose and Control-IQ.
        for id in [2, 3, 5, 6, 7, 8] {
            #expect(R.pumpMirrorGroup(kind: .cgmAlert, id: id, isMalfunction: false) == .glucoseAndControlIQ)
        }
        for id in [35, 50, 51] {
            #expect(R.pumpMirrorGroup(kind: .alert, id: id, isMalfunction: false) == .glucoseAndControlIQ)
        }
        // CGM sensor and transmitter (includes the loss-of-coverage ids force-protected before this phase).
        for id in [4, 9, 10, 11, 12, 13, 14, 16, 17, 18, 19, 20, 22, 25, 26, 27, 39] {
            #expect(R.pumpMirrorGroup(kind: .cgmAlert, id: id, isMalfunction: false) == .cgmSensorAndTransmitter)
        }
        for id in [19, 20, 22, 27, 28, 29, 39, 40, 41, 42, 44, 48] {
            #expect(R.pumpMirrorGroup(kind: .alert, id: id, isMalfunction: false) == .cgmSensorAndTransmitter)
        }
        // Pump reminders and routine.
        for id in [6, 8, 11, 12, 13, 14, 15, 18, 23, 26, 33, 34] {
            #expect(R.pumpMirrorGroup(kind: .alert, id: id, isMalfunction: false) == .pumpRoutine)
        }
        #expect(R.pumpMirrorGroup(kind: .reminder, id: 0, isMalfunction: false) == .pumpRoutine)
        #expect(R.pumpMirrorGroup(kind: .reminder, id: 63, isMalfunction: false) == .pumpRoutine)
    }

    /// The fail-safe cell (the whole reason 28.1's inventory exists): an ALERT id this table does not
    /// name — the delivery-suspending Control-IQ Max Insulin id 52 is the proof case — must NOT resolve
    /// to the most-ignorable group, and its default rung is loud.
    @Test func unknownAlertIdHitsTheFailSafeCellNotTheRoutineGroup() {
        let group = R.pumpMirrorGroup(kind: .alert, id: 52, isMalfunction: false)
        #expect(group != .pumpRoutine, "an unnamed, delivery-suspending alert must not fall into the routine group")
        #expect(R.defaultIntent(for: group) >= .alert, "the fail-safe rung is loud, never quiet or off")
        // Any other unnamed alert bit shares the same fail-safe floor.
        #expect(R.pumpMirrorGroup(kind: .alert, id: 60, isMalfunction: false) != .pumpRoutine)
    }

    /// Fatigue-averse defaults (safety = Alert, pump-alarm = Alert not Urgent, non-safety quieter): no
    /// pump-mirror group defaults to `.off`, none to `.urgent`.
    @Test func noGroupDefaultsToOffAndNoneToUrgent() {
        for group in R.PumpMirrorGroup.allCases {
            #expect(R.defaultIntent(for: group) != .off, "\(group) must not be silent by default")
            #expect(R.defaultIntent(for: group) != .urgent, "\(group) must not pierce DND by default")
        }
        // The pump-alarm (delivery-stopped) category defaults to Alert, never Urgent.
        #expect(R.defaultIntent(for: .deliveryStopped) == .alert)
    }

    /// Decision 1c — one-move silence: a source-level `Off` on the pump-mirror source drives every
    /// group's category default to `Off`, UNLESS a category level overrides upward.
    @Test func sourceLevelOffSilencesEveryGroupUnlessCategoryOverridesUpward() {
        for group in R.PumpMirrorGroup.allCases {
            let categoryDefault = R.Rule(intent: R.defaultIntent(for: group))
            // Source Off + the group's default at the category level: the category (more specific) wins,
            // so the group's loud default overrides the source Off upward.
            let overriding = R.resolve(
                source: .init(intent: .off), category: categoryDefault, timeSensitiveAvailable: true)
            #expect(overriding.phone == R.defaultIntent(for: group))
            // Source Off with NO category-level rule: the whole pump mirror goes silent in one move.
            let silenced = R.resolve(source: .init(intent: .off), category: nil, timeSensitiveAvailable: true)
            #expect(silenced.phone == .off)
        }
    }

    // MARK: - Persisted rules model (fresh defaults, decode-tolerant, no migration)

    /// A fresh install AND an upgrading install (no override for any group) both resolve through
    /// `defaultIntent(for:)` — never through the legacy `notificationBroker.settings.v1` blob, which
    /// this model has no code path to read at all.
    @Test func freshAndUpgradingInstallsBothLandOnFreshDefaults_noMigrationPath() {
        let fresh = R.PersistedRules()
        for group in R.PumpMirrorGroup.allCases {
            let resolved = R.resolve(fresh.cascade(for: group), timeSensitiveAvailable: true)
            #expect(resolved.phone == R.defaultIntent(for: group))
        }
    }

    /// A blob missing a key (simulating a build that predates a later-added field) decodes without
    /// reverting any OTHER field — the hand-written `decodeIfPresent` decoder, not the legacy
    /// per-field-Optional discipline, is what buys this.
    @Test func aBlobMissingAKeyDecodesWithoutRevertingOtherFields() throws {
        let json = Data(#"{"sourceOverride":{"intent":1}}"#.utf8)
        let decoded = try JSONDecoder().decode(R.PersistedRules.self, from: json)
        #expect(decoded.sourceOverride?.intent == .quiet)
        #expect(decoded.groupOverrides.isEmpty, "the missing key must default to empty, not fail the whole decode")
    }

    /// A malformed/unparseable blob (the caller's `try?` fallback) never yields a SAFETY group at
    /// `.off` — the fallback is `.init()` (no overrides), which resolves every group through its
    /// fatigue-averse default, never silence.
    @Test func decodeFailureFallsBackToDefaultsNeverASilentSafetyOff() {
        let garbage = Data([0xFF, 0x00, 0x13, 0x42])
        let decoded = (try? JSONDecoder().decode(R.PersistedRules.self, from: garbage)) ?? R.PersistedRules()
        for group in R.PumpMirrorGroup.allCases {
            let resolved = R.resolve(decoded.cascade(for: group), timeSensitiveAvailable: true)
            #expect(resolved.phone != .off, "\(group) must never resolve to Off from a decode failure")
        }
    }

    /// Round-trip: encode → decode preserves a user's chosen non-default rung for a group.
    @Test func roundTripPreservesAUsersChosenNonDefaultRungForAGroup() throws {
        var rules = R.PersistedRules()
        rules.groupOverrides[R.PumpMirrorGroup.pumpRoutine.rawValue] = R.Rule(intent: .urgent)
        let decoded = try JSONDecoder().decode(R.PersistedRules.self, from: JSONEncoder().encode(rules))
        #expect(decoded == rules)
        #expect(decoded.cascade(for: .pumpRoutine).category?.intent == .urgent)
        #expect(R.resolve(decoded.cascade(for: .pumpRoutine), timeSensitiveAvailable: true).phone == .urgent)
        // An un-overridden group in the SAME blob is unaffected — still its fatigue-averse default.
        #expect(decoded.cascade(for: .glucoseAndControlIQ).category == nil)
        #expect(
            R.resolve(decoded.cascade(for: .glucoseAndControlIQ), timeSensitiveAvailable: true).phone
                == R.defaultIntent(for: .glucoseAndControlIQ))
    }

    /// The one-move pump-mirror source override still yields to a category-level override (more
    /// specific wins), exactly as `resolve`'s cascade already proves — pinned here through the
    /// persisted model's own `cascade(for:)` construction, not just the raw resolver call.
    @Test func sourceOverridePersistsAndCategoryOverrideStillWinsWhenBothSet() {
        var rules = R.PersistedRules(sourceOverride: .init(intent: .off))
        rules.groupOverrides[R.PumpMirrorGroup.deliveryStopped.rawValue] = R.Rule(intent: .urgent)
        let silencedGroup = R.resolve(rules.cascade(for: .runningLow), timeSensitiveAvailable: true)
        #expect(silencedGroup.phone == .off, "no category override for this group — the source Off wins")
        let overriddenGroup = R.resolve(rules.cascade(for: .deliveryStopped), timeSensitiveAvailable: true)
        #expect(overriddenGroup.phone == .urgent, "a category-level override still beats the source Off")
    }
}
