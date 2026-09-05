import Testing
import Foundation
import faBolusCore
@testable import faBolus

/// Proves ONE resolver serves BOTH consumers — the phone (`NotificationBroker.decide`) and the
/// composer's pure watch-intent helper — for the pump-mirror tracer category, so "notify means two
/// things" cannot recur by construction: the phone and watch sides differ only by SURFACE, never
/// by a duplicated re-derivation of thresholding.
///
/// SCOPE: this proves the composer computes its watch intent by CALLING the resolver through a
/// pure helper. It does NOT emit a wire property and does NOT assert the watch reads the engine
/// on-wire end-to-end — that on-wire cross-surface proof is a later plan (the additive schema
/// field + the watch consuming it). No assertion here claims a relay was exercised.
@Suite struct NotificationRulesConsumerTests {
    typealias R = NotificationRules

    private func pumpAlertMessage(key: String = "k") -> NotificationBroker.Message {
        NotificationBroker.Message(category: .pumpAlert, severity: .warning, title: "t", body: "b", dedupeKey: key)
    }

    @Test func phoneAndWatchBothTraceToTheOneResolver_differingOnlyBySurface() {
        let cascade = R.Cascade(category: .init(intent: .urgent))
        let resolved = R.resolve(cascade, timeSensitiveAvailable: true)

        let decision = NotificationBroker.decide(
            pumpAlertMessage(), settings: [:], state: .init(), now: Date(timeIntervalSince1970: 0),
            rules: cascade, timeSensitiveAvailable: true)
        #expect(decision.deliver == (resolved.phone != .off), "the phone side traces to the resolver's phone output")

        let watchIntent = RemoteStatusComposer.pumpMirrorWatchIntent(rules: cascade, timeSensitiveAvailable: true)
        #expect(watchIntent == resolved.watch, "the composer's helper traces to the SAME resolver's watch output")
        #expect(watchIntent != .urgent, "the Garmin ladder has no Urgent rung, even though the phone resolved Urgent")
    }

    @Test func aCategoryResolvedOff_deliversNothingOnEitherSurface() {
        let cascade = R.Cascade(category: .init(intent: .off))
        let resolved = R.resolve(cascade, timeSensitiveAvailable: true)

        let decision = NotificationBroker.decide(
            pumpAlertMessage(), settings: [:], state: .init(), now: Date(timeIntervalSince1970: 0),
            rules: cascade, timeSensitiveAvailable: true)
        #expect(!decision.deliver)

        let watchIntent = RemoteStatusComposer.pumpMirrorWatchIntent(rules: cascade, timeSensitiveAvailable: true)
        #expect(watchIntent == .off)
        #expect(watchIntent == resolved.watch)
    }

    @Test func watchFollowsPhoneByDefault_perRuleOverrideWinsOnTheComposerSide() {
        let following = R.Cascade(category: .init(intent: .alert))
        #expect(
            RemoteStatusComposer.pumpMirrorWatchIntent(rules: following, timeSensitiveAvailable: true) == .alert)

        let overridden = R.Cascade(category: .init(intent: .alert, watchOverride: .off))
        #expect(
            RemoteStatusComposer.pumpMirrorWatchIntent(rules: overridden, timeSensitiveAvailable: true) == .off)
    }
}
