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

    private func msg(_ c: NotificationBroker.Category = .pumpAlert, key: String = "k") -> NotificationBroker.Message
    {
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
}
