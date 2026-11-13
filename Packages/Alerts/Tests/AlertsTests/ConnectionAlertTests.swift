import Foundation
import Testing
import faBolusCore

@testable import Alerts

/// Pump disconnected and connection unstable, from the session's link events.
@Suite struct ConnectionAlertTests {
    let m: TimeInterval = 60

    /// The owner's default: nothing for 15 minutes, then the first notice, then the 30-minute follow-up,
    /// all scheduled with the OS at the drop so they fire while the app is suspended.
    @Test func aDropSchedulesTheNoticesAtTheUsersDelay() async {
        let h = await Harness.launch()
        let droppedAt = h.clock.now
        await h.send(.disconnected(.linkLost(code: 7)))
        let adds = await h.scheduler.adds
        #expect(
            adds.map(\.identifier).sorted()
                == [
                    DisconnectEscalation.firstNoticeId, "safety.pumpDisconnect.escalation.30m"
                ].sorted())
        let first = adds.first { $0.identifier == DisconnectEscalation.firstNoticeId }
        #expect(first?.fireDate == droppedAt.addingTimeInterval(15 * m))
        #expect(first?.level == .timeSensitive)
        #expect(adds.allSatisfy { $0.category == .pumpDisconnect })
        // Not showing yet: the watch mirrors only what the phone has posted.
        #expect(await h.coordinator.snapshot.active.isEmpty)
        h.clock.advance(15 * m)
        #expect(await h.coordinator.snapshot.active.map(\.identifier) == [DisconnectEscalation.firstNoticeId])
    }

    /// The phone's clock set forward an hour while the pump is down brings no notice forward: the first still
    /// comes 15 minutes after the drop, by the time that really passed.
    @Test func aClockSetForwardBringsNoNoticeForward() async {
        let h = await Harness.launch()
        await h.send(.disconnected(.linkLost(code: 7)))
        let posted = await h.scheduler.adds.count
        h.clock.set(by: 60 * m)
        h.clock.advance(m)
        await h.send(.disconnected(.linkLost(code: 7)))
        #expect(await h.scheduler.adds.count == posted, "nothing posted again")
        #expect(await h.coordinator.snapshot.active.isEmpty)
        h.clock.advance(14 * m)
        await h.coordinator.tick()
        #expect(await h.coordinator.snapshot.active.map(\.identifier) == [DisconnectEscalation.firstNoticeId])
    }

    /// What the watch is shown follows the clock too, before anything else runs.
    @Test func aSnapshotRightAfterTheClockIsSetShowsNothingEarly() async {
        let h = await Harness.launch()
        await h.send(.disconnected(.linkLost(code: 7)))
        _ = await h.coordinator.snapshot
        h.clock.set(by: 60 * m)
        #expect(await h.coordinator.snapshot.active.isEmpty)
    }

    @Test func reconnectingWithdrawsEveryDisconnectNotice() async {
        let h = await Harness.launch()
        await h.send(.disconnected(.linkLost(code: nil)))
        await h.send(.linkChanged(.connecting))
        await h.send(.linkChanged(.connected))
        #expect(
            Set(await h.scheduler.removed).isSuperset(
                of: Set(DisconnectEscalation.schedule(delay: .standard).map(\.id))))
        #expect(await h.scheduler.held.isEmpty)
    }

    /// A drop while already down keeps the first drop's time, so a flap can't push the notice back.
    @Test func repeatedDropsDontPushTheNoticeBack() async {
        let h = await Harness.launch()
        let droppedAt = h.clock.now
        await h.send(.disconnected(.linkLost(code: nil)))
        h.clock.advance(5 * m)
        await h.send(.disconnected(.linkLost(code: nil)))
        #expect(await h.scheduler.adds.count == 2, "posted once, not again")
        #expect(
            await h.scheduler.held[DisconnectEscalation.firstNoticeId]?.fireDate == droppedAt.addingTimeInterval(15 * m)
        )
    }

    /// The user or the app closing the link (forgetting the pump) is nothing to alert about.
    @Test func aRequestedDisconnectAlertsNothingAndClearsAnOutstandingOne() async {
        let h = await Harness.launch()
        await h.send(.disconnected(.requested))
        #expect(await h.scheduler.adds.isEmpty)
        await h.send(.disconnected(.bluetoothUnavailable))
        await h.send(.disconnected(.requested))
        #expect(await h.scheduler.held.isEmpty)
    }

    @Test func immediatelyAndNeverAreHonored() async {
        let h = await Harness.launch()
        await h.coordinator.setPolicy(AlertPolicy(pumpDisconnectDelay: .immediately))
        await h.send(.disconnected(.linkLost(code: nil)))
        #expect(await h.scheduler.held[DisconnectEscalation.firstNoticeId]?.fireDate == h.clock.now)
        #expect(await h.coordinator.snapshot.active.count == 1)
        // Changing to never while down withdraws everything scheduled.
        await h.coordinator.setPolicy(AlertPolicy(pumpDisconnectDelay: .never))
        #expect(await h.scheduler.held.isEmpty)
        // And back: rescheduled from the original drop, not from now.
        let droppedAt = h.clock.now
        h.clock.advance(2 * m)
        await h.coordinator.setPolicy(AlertPolicy(pumpDisconnectDelay: .fiveMinutes))
        #expect(
            await h.scheduler.held[DisconnectEscalation.firstNoticeId]?.fireDate == droppedAt.addingTimeInterval(5 * m))
    }

    /// Changing the delay while the pump is down leaves a notice the user has seen alone, and posts only
    /// the latest notice that is already due.
    @Test func changingTheDelayWhileDownNeitherRepeatsNorStacksNotices() async {
        let h = await Harness.launch()
        let droppedAt = h.clock.now
        await h.send(.disconnected(.linkLost(code: nil)))
        h.clock.advance(20 * m)
        await h.coordinator.tick()
        await h.scheduler.clearCalls()
        // Longer: the 15-minute notice, already shown, isn't re-posted.
        await h.coordinator.setPolicy(AlertPolicy(pumpDisconnectDelay: .thirtyMinutes))
        #expect(await h.scheduler.adds.isEmpty)
        #expect(
            await h.scheduler.held[DisconnectEscalation.firstNoticeId]?.fireDate == droppedAt.addingTimeInterval(15 * m)
        )

        // Off and back on at 5 minutes, 20 minutes in: only the latest due notice (the 15-minute follow-up)
        // posts now, with the 30-minute one still to come.
        await h.coordinator.setPolicy(AlertPolicy(pumpDisconnectDelay: .never))
        await h.scheduler.clearCalls()
        await h.coordinator.setPolicy(AlertPolicy(pumpDisconnectDelay: .fiveMinutes))
        let adds = await h.scheduler.adds
        #expect(
            adds.map(\.identifier).sorted() == [
                "safety.pumpDisconnect.escalation.15m", "safety.pumpDisconnect.escalation.30m"
            ])
        #expect(adds.filter { $0.hasFired(by: h.clock.now) }.count == 1, "one notice now, not a stack")
    }

    /// The snapshot is published when a scheduled notice comes due, not only on an input.
    @Test func aNoticeComingDueIsPublished() async {
        let h = await Harness.launch()
        await h.send(.disconnected(.linkLost(code: nil)))
        let stream = await h.coordinator.snapshots()
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next()?.active.isEmpty == true)
        h.clock.advance(15 * m)
        await h.coordinator.tick()
        #expect(await iterator.next()?.active.map(\.identifier) == [DisconnectEscalation.firstNoticeId])
    }

    @Test func connectionUnstableRaisesOnceAndClearsWhenRestored() async {
        let h = await Harness.launch()
        await h.send(.connectionUnstable)
        await h.send(.connectionUnstable)
        let adds = await h.scheduler.adds
        #expect(adds.map(\.identifier) == [AlertEngine.connectionUnstableId])
        #expect(adds.first?.level == .timeSensitive && adds.first?.fireDate == nil)
        // A reconnect is half of every flap: it doesn't clear it.
        await h.send(.linkChanged(.connected))
        #expect(await h.scheduler.held[AlertEngine.connectionUnstableId] != nil)
        await h.send(.connectionRestored)
        #expect(await h.scheduler.held[AlertEngine.connectionUnstableId] == nil)
    }

    @Test func turningConnectionUnstableOffWithdrawsItAndOnPostsItAgain() async {
        let h = await Harness.launch()
        await h.send(.connectionUnstable)
        var policy = AlertPolicy()
        policy.setOn(false, for: .pumpConnectionUnstable)
        await h.coordinator.setPolicy(policy)
        #expect(await h.scheduler.held.isEmpty)
        policy.setOn(true, for: .pumpConnectionUnstable)
        await h.coordinator.setPolicy(policy)
        #expect(await h.scheduler.held[AlertEngine.connectionUnstableId] != nil)
    }

    /// Pump notifications: one notification each, under its switch, withdrawn when the pump clears it.
    @Test func pumpNotificationsFollowThePumpsList() async {
        let h = await Harness.launch()
        let lowInsulin = PumpAlert(id: 0, kind: .alert, title: "Low insulin", detail: "20 U left")
        let sensor = PumpAlert(id: 11, kind: .cgmAlert, title: "Sensor failed")
        let occlusion = PumpAlert(id: 2, kind: .alarm, title: "Occlusion", isDismissable: false)
        let malfunction = PumpAlert(id: 2, kind: .alarm, title: "Malfunction", isDismissable: false, malfunctionCode: 2)
        await h.send(.alertsChanged([lowInsulin, sensor, occlusion, malfunction]))
        let held = await h.scheduler.held
        #expect(held.count == 4, "an alarm and a malfunction on the same bit are two notifications")
        #expect(held[AlertEngine.pumpAlertIdentifier(sensor)]?.category == .pumpCgmAlert)
        #expect(held[AlertEngine.pumpAlertIdentifier(occlusion)]?.category == .pumpAlert)
        #expect(held[AlertEngine.pumpAlertIdentifier(lowInsulin)]?.body == "20 U left")
        #expect(held.values.allSatisfy { $0.level == .active })
        // The same list again posts nothing; a cleared one is withdrawn.
        await h.scheduler.clearCalls()
        await h.send(.alertsChanged([lowInsulin, sensor, occlusion, malfunction]))
        #expect(await h.scheduler.calls.isEmpty)
        await h.send(.alertsChanged([sensor, occlusion, malfunction]))
        #expect(await h.scheduler.removed == [AlertEngine.pumpAlertIdentifier(lowInsulin)])
        // CGM alerts off: the sensor notification goes, the pump's stay.
        var policy = AlertPolicy()
        policy.setOn(false, for: .pumpCgmAlert)
        await h.coordinator.setPolicy(policy)
        #expect(await h.scheduler.held[AlertEngine.pumpAlertIdentifier(sensor)] == nil)
        #expect(await h.scheduler.held.count == 2)
    }
}
