import Foundation
import Testing
import faBolusCore

@testable import Alerts

/// One resolver serves both consumers, the phone's notification and what the watch mirrors, so "notify"
/// can't mean two things: the two differ only by surface. Ported from the old app's suite of the same
/// name; there the watch side was the remote composer's helper, here it is the active alerts the phone
/// hands the watch (`AlertSnapshot.active`).
@Suite struct NotificationRulesConsumerTests {
    typealias R = NotificationRules

    @Test func phoneAndWatchBothTraceToTheOneResolver_differingOnlyBySurface() async {
        let h = await Harness.launch()
        await h.send(.connectionUnstable)
        await h.send(.alertsChanged([PumpAlert(id: 0, kind: .alert, title: "Low insulin")]))
        let active = await h.coordinator.snapshot.active
        #expect(active.count == 2)
        for alert in active {
            let resolved = R.resolve(alert.category, policy: AlertPolicy())
            #expect(alert.phoneIntent == resolved.phone, "the phone side traces to the resolver's phone output")
            #expect(alert.watchIntent == resolved.watch, "the watch side traces to the same resolver")
            #expect(alert.watchIntent != .urgent, "the Garmin ladder has no urgent rung")
        }
        // The time-sensitive phone alert is urgent on the phone and vibrates the watch.
        let unstable = active.first { $0.category == .pumpConnectionUnstable }
        #expect(unstable?.phoneIntent == .urgent && unstable?.watchIntent == .alert)
    }

    @Test func aCategoryResolvedOff_deliversNothingOnEitherSurface() async {
        let h = await Harness.launch()
        var policy = AlertPolicy()
        policy.setOn(false, for: .pumpAlert)
        await h.coordinator.setPolicy(policy)
        await h.send(.alertsChanged([PumpAlert(id: 0, kind: .alert, title: "Low insulin")]))
        #expect(await h.scheduler.adds.isEmpty, "nothing on the phone")
        #expect(await h.coordinator.snapshot.active.isEmpty, "nothing for the watch to mirror")
        let resolved = R.resolve(.pumpAlert, policy: policy)
        #expect(resolved.phone == .off && resolved.watch == .off)
    }

    /// Changed: the old per-rule watch override is gone with the ladder (owner decision 2026-11-01:
    /// per-category on/off, fixed urgency). The watch always follows the phone, for every category.
    @Test func watchFollowsPhoneForEveryCategory() {
        for category in NotificationBroker.Category.allCases {
            let resolved = R.resolve(category, policy: AlertPolicy())
            #expect(resolved.watch == Swift.min(resolved.phone, .alert), "\(category.rawValue)")
        }
    }
}
