import Foundation
import Testing
import faBolusCore

@testable import Alerts

/// What survives a relaunch, and what doesn't: nothing the app owes the OS is lost, nothing is posted
/// twice, and a settled bolus is announced exactly once. A relaunch is a new coordinator (and a new
/// ledger owner) over the same stores; the OS keeps what it was given.
@Suite struct RelaunchTests {
    let request = Fixtures.request()
    var key: RemoteBolusLedger.Key { request.ledgerKey }
    var id: String { AlertEngine.bolusIdentifier(key) }

    @Test func steadyConditionsAreNotPostedAgainAfterARelaunch() async throws {
        let h = await Harness.launch()
        await h.send(.disconnected(.linkLost(code: nil)))
        await h.send(.connectionUnstable)
        await h.send(.alertsChanged([PumpAlert(id: 0, kind: .alert, title: "Low insulin")]))
        let before = await h.scheduler.held
        #expect(before.count >= 3)
        await h.scheduler.clearCalls()
        let next = await h.relaunch()
        await next.send(.alertsChanged([PumpAlert(id: 0, kind: .alert, title: "Low insulin")]))
        #expect(await next.scheduler.adds.isEmpty, "nothing re-posted (a re-post re-alerts)")
        // The disconnect schedule still stands; the link's instability is per process and is withdrawn.
        #expect(await next.scheduler.held[DisconnectEscalation.firstNoticeId] != nil)
        #expect(await next.scheduler.removed == [AlertEngine.connectionUnstableId])
    }

    /// A pump notification whose remote-clear answer changes, as after the phone's first clear on a pump not
    /// yet known, isn't posted again: that would alert again for nothing new. What the watch is told follows
    /// the new answer.
    @Test func aRemoteClearChangeAloneIsNotPostedAgain() async throws {
        let h = await Harness.launch()
        await h.send(.alertsChanged([PumpAlert(id: 0, kind: .alert, title: "Low insulin", remoteClear: .tryable)]))
        #expect(await h.scheduler.held.count == 1)
        await h.scheduler.clearCalls()
        await h.send(.alertsChanged([PumpAlert(id: 0, kind: .alert, title: "Low insulin", remoteClear: .available)]))
        #expect(await h.scheduler.adds.isEmpty, "nothing re-posted (a re-post re-alerts)")
        let active = await h.coordinator.snapshot.active
        #expect(active.compactMap(\.pumpAlert?.remoteClear) == [.available])
    }

    /// A bolus that settled while the app wasn't running is announced on the next launch, once.
    @Test func aBolusThatSettledWhileTheAppWasDownIsAnnouncedOnceOnLaunch() async throws {
        let h = await Harness.launch()
        _ = try await h.ledger.begin(request, now: h.clock.now)
        await h.send(.bolusOutcome(key, .requested))
        _ = try await h.ledger.markAccepted(key, bolusId: 7, pumpKey: "pump", pumpClock: 100, now: h.clock.now)
        _ = try await h.ledger.markUnknown(key, now: h.clock.now)
        await h.send(.bolusOutcome(key, .unknown(since: h.clock.now)))
        #expect(await h.scheduler.held[id]?.title == "Bolus outcome unknown")
        // The app is killed; another owner of the ledger (the next launch's session) settles it before the
        // alert pipeline hears about it.
        var ledger = try #require(h.ledgerStore.saved)
        ledger.markDeliveredFromHistory(key, units: 2, historyPumpKey: "pump", now: h.clock.now)
        h.ledgerStore.saved = ledger
        await h.scheduler.clearCalls()
        let next = await h.relaunch()
        #expect(await next.scheduler.adds.map(\.title) == ["Bolus delivered"])
        await next.scheduler.clearCalls()
        let third = await next.relaunch()
        #expect(await third.scheduler.adds.isEmpty, "announced once, never again")
    }

    /// A restart turns an in-flight bolus unknown (`recoverAfterRestart`) without any session event: the
    /// launch reads the ledger and posts the notice.
    @Test func anInFlightBolusLeftByACrashGetsItsNoticeOnLaunch() async throws {
        let h = await Harness.launch()
        _ = try await h.ledger.begin(request, now: h.clock.now)
        await h.send(.bolusOutcome(key, .requested))
        _ = try await h.ledger.markAccepted(key, bolusId: 7, pumpKey: "pump", pumpClock: 100, now: h.clock.now)
        await h.send(.bolusOutcome(key, .accepted))
        let next = await h.relaunch()
        let notice = try #require(await next.scheduler.held[id])
        #expect(notice.title == "Bolus outcome unknown" && notice.level == .timeSensitive)
        #expect(await next.coordinator.snapshot.banners == [.unknownBolusOutcome])
    }

    /// An unknown outcome the alert pipeline never heard about (its state file was lost) is still
    /// announced: the ledger is the authority.
    @Test func anUnknownOutcomeInTheLedgerIsAnnouncedEvenWithNoAlertState() async throws {
        let ledgerStore = MemoryLedgerStore(Fixtures.ledger(.unknown(since: .now), at: TestClock().now))
        let h = await Harness.launch(ledgerStore: ledgerStore)
        #expect(await h.scheduler.held[id]?.level == .timeSensitive)
    }

    /// A request the previous process hadn't sent fails on restart; the user is told it never reached the
    /// pump, as a bolus result.
    @Test func aRequestInterruptedBeforeThePumpIsAnnouncedAsNotDelivered() async throws {
        let h = await Harness.launch()
        _ = try await h.ledger.begin(request, now: h.clock.now)
        await h.send(.bolusOutcome(key, .requested))
        let next = await h.relaunch()
        let notice = try #require(await next.scheduler.held[id])
        #expect(notice.title == "Bolus not delivered" && notice.category == .bolusReconciliation)
        #expect(notice.body.contains("never reached the pump"))
    }

    /// Persist before post: when the OS is asked to post, the request is already saved as owed. A crash
    /// right then leaves it in the outbox, and the next launch performs it.
    @Test func everyPostIsSavedAsOwedBeforeTheOSIsAsked() async throws {
        let store = MemoryAlertStore()
        let scheduler = FakeScheduler()
        await scheduler.setOnAdd { request in
            let owed = store.savedState?.outbox.contains { $0.effect == .post(request) } ?? false
            #expect(owed, "\(request.identifier) was posted before it was saved")
        }
        let h = await Harness.launch(store: store, scheduler: scheduler)
        await h.send(.connectionUnstable)
        #expect(await scheduler.adds.count == 1)
        #expect(store.savedState?.outbox.isEmpty == true, "acknowledged once performed")
    }

    @Test func anEffectCutOffByACrashIsPerformedOnTheNextLaunch() async throws {
        let store = MemoryAlertStore()
        // The last process derived and saved a disconnect notice but died before handing it to the OS.
        let clock = TestClock()
        var engine = AlertEngine(policy: AlertPolicy(pumpDisconnectDelay: .immediately))
        engine.handle(.pump(.disconnected(.linkLost(code: nil))), now: clock.now)
        try store.saveState(engine.state)
        try store.savePolicy(AlertPolicy(pumpDisconnectDelay: .immediately))
        let h = await Harness.launch(store: store, clock: clock)
        #expect(await h.scheduler.held[DisconnectEscalation.firstNoticeId] != nil, "performed, not lost")
        #expect(store.savedState?.outbox.isEmpty == true)
    }

    /// A post still owed for a condition that has since ended is dropped, not shown just before its
    /// withdrawal: the user doesn't hear an alert for something that is over.
    @Test func anOwedPostForAConditionThatEndedIsNotShown() async throws {
        let store = MemoryAlertStore()
        var engine = AlertEngine()
        engine.handle(.pump(.connectionUnstable), now: TestClock().now)
        try store.saveState(engine.state)
        let h = await Harness.launch(store: store)
        #expect(await h.scheduler.adds.isEmpty, "the new process's link is stable: nothing to show")
        #expect(await h.scheduler.removed == [AlertEngine.connectionUnstableId], "withdrawn in case it was shown")
        #expect(store.savedState?.outbox.isEmpty == true)
    }

    /// The fresh-start clean-up runs before anything is handed to the OS, so an input that came before
    /// `start` isn't removed by it.
    @Test func anInputBeforeStartIsNotRemovedByTheFreshStartCleanUp() async {
        let clock = TestClock()
        let low = GlucoseSourceState(
            latest: GlucoseSample(mgdl: 45, date: clock.now, sourceID: "dexcom-share"), status: .connected)
        let h = await Harness.launch(clock: clock, reportNoBackup: false) { await $0.backupGlucoseChanged(low) }
        #expect(await h.scheduler.held[UrgentLowAlarm.dedupeKey] != nil)
        let calls = await h.scheduler.calls
        #expect(calls.first == .removeAll)
    }

    /// A state file a later build wrote with a field this one doesn't know, or missing one it expects,
    /// still loads: what the last process owed the OS isn't lost.
    @Test func theStateFileLoadsDespiteUnknownOrMissingFields() throws {
        var engine = AlertEngine()
        engine.handle(.pump(.connectionUnstable), now: TestClock().now)
        var json = try #require(
            JSONSerialization.jsonObject(with: JSONEncoder().encode(engine.state)) as? [String: Any])
        json["aFieldFromALaterBuild"] = ["x": 1]
        json["cgmLost"] = "not a bool"
        json.removeValue(forKey: "nextSequence")
        let decoded = try JSONDecoder().decode(
            AlertEngine.State.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.outbox == engine.state.outbox)
        #expect(decoded.posted == engine.state.posted)
        #expect(decoded.connectionUnstable)
        #expect(!decoded.cgmLost)
        var next = AlertEngine(state: decoded)
        let added = next.handle(.pump(.connectionRestored), now: TestClock().now)
        #expect(!decoded.outbox.map(\.sequence).contains(added.first?.sequence ?? 0), "sequence numbers aren't reused")
    }

    /// The first launch of the new app removes every notification the old app left, pending or delivered.
    @Test func aFreshInstallRemovesEveryOldNotification() async {
        let scheduler = FakeScheduler()
        await scheduler.preload(
            AlertRequest(
                identifier: "safety.cgmStalenessWatchdog", category: .cgmDataLoss, severity: .warning,
                level: .timeSensitive, title: "CGM data may be stale", body: "old app",
                fireDate: Date(timeIntervalSince1970: 1_900_000_000)))
        let h = await Harness.launch(scheduler: scheduler) { await $0.resetForFreshInstall() }
        #expect(await scheduler.removedAll == 1)
        #expect(await h.scheduler.held.isEmpty)
    }

    /// With no state file the earlier process's notices aren't known, so every one is withdrawn at start
    /// rather than left to fire or linger: the fixed ones, and a per-request "outcome unknown" and an old
    /// pump alert, whose identifiers can't be named.
    @Test func withNoStateFileEveryOldNoticeIsWithdrawnAtStart() async {
        let scheduler = FakeScheduler()
        let old = AlertRequest(
            identifier: AlertEngine.bolusIdentifier(key), category: .bolusReconciliation, severity: .warning,
            level: .timeSensitive, title: "Bolus outcome unknown", body: "", fireDate: nil)
        await scheduler.preload(old)
        let h = await Harness.launch(scheduler: scheduler)
        #expect(await scheduler.removedAll == 1)
        #expect(await h.scheduler.held[old.identifier] == nil, "the ledger holds no such request any more")
    }

    /// A state that couldn't be read at launch turns out corrupt once it can be: what the earlier process
    /// posted is withdrawn then, and what is true now is posted again.
    @Test func aStateThatTurnsOutCorruptWithdrawsTheOldNotices() async throws {
        let store = MemoryAlertStore()
        let h = await Harness.launch(store: store)
        let old = AlertRequest(
            identifier: AlertEngine.bolusIdentifier(key), category: .bolusReconciliation, severity: .warning,
            level: .timeSensitive, title: "Bolus outcome unknown", body: "", fireDate: nil)
        await h.scheduler.preload(old)
        store.locked = true
        let next = await h.relaunch()
        await next.send(.alertsChanged([PumpAlert(id: 0, kind: .alert, title: "Low insulin")]))
        #expect(await next.scheduler.held[old.identifier] != nil, "nothing withdrawn while it can't be read")
        store.locked = false
        store.corrupt = true
        await next.coordinator.tick()
        #expect(await next.scheduler.held[old.identifier] == nil)
        #expect(await next.scheduler.held.values.contains { $0.title == "Low insulin" })
    }

    /// A launch before the first unlock can't read the saved state. It withdraws nothing and writes nothing
    /// over it; once the file reads, it is adopted, so a notice it records as posted isn't posted again.
    @Test func aStateThatCantBeReadYetIsAdoptedNotOverwritten() async throws {
        let store = MemoryAlertStore()
        let h = await Harness.launch(store: store)
        await h.send(.alertsChanged([PumpAlert(id: 0, kind: .alert, title: "Low insulin")]))
        let saved = try #require(store.savedState)
        store.locked = true
        await h.scheduler.clearCalls()
        let next = await h.relaunch()
        #expect(await !next.scheduler.calls.contains(.removeAll))
        #expect(await next.scheduler.removed.isEmpty)
        store.locked = false
        #expect(store.savedState == saved, "not written over while it couldn't be read")
        await next.send(.alertsChanged([PumpAlert(id: 0, kind: .alert, title: "Low insulin")]))
        #expect(await next.coordinator.engine.state.posted == saved.posted)
        #expect(store.savedState?.posted == saved.posted)
    }

    /// A notice this process posted while the saved state couldn't be read isn't posted again when the
    /// state is adopted, though the saved state never had it.
    @Test func whatWasPostedWhileLockedIsntPostedAgainOnAdoption() async throws {
        let store = MemoryAlertStore()
        let h = await Harness.launch(store: store)
        await h.send(.disconnected(.linkLost(code: nil)))
        await h.send(.linkChanged(.connected))
        _ = try #require(store.savedState)
        store.locked = true
        let next = await h.relaunch()
        let alert = PumpAlert(id: 0, kind: .alert, title: "Low insulin")
        await next.send(.alertsChanged([alert]))
        let id = try #require(await next.scheduler.held.values.first { $0.title == "Low insulin" }?.identifier)
        store.locked = false
        await next.coordinator.tick()
        await next.send(.alertsChanged([alert]))
        #expect(await next.scheduler.adds.filter { $0.identifier == id }.count == 1)
        #expect(store.savedState?.posted[id] != nil, "the adopted state knows it's posted")
    }

    /// Inputs held while locked are applied to the saved state at the time they happened: a drop is down
    /// from when it happened, not from the unlock.
    @Test func heldInputsKeepTheirOwnTime() async {
        let store = MemoryAlertStore()
        let clock = TestClock()
        let h = await Harness.launch(store: store, clock: clock)
        await h.send(.disconnected(.linkLost(code: nil)))
        await h.send(.linkChanged(.connected))
        #expect(store.savedState != nil)
        store.locked = true
        let next = await h.relaunch()
        let droppedAt = clock.now
        await next.send(.disconnected(.linkLost(code: nil)))
        clock.advance(3600)
        store.locked = false
        await next.coordinator.tick()
        #expect(await next.coordinator.engine.state.linkDownSince == droppedAt)
    }

    /// The unlock brings several inputs at once: each runs the adoption, which happens once, and none of
    /// their effects is lost to a second copy adopted over the first.
    @Test func concurrentInputsAdoptTheStateOnce() async {
        let store = MemoryAlertStore()
        let h = await Harness.launch(store: store)
        await h.send(.disconnected(.linkLost(code: nil)))
        await h.send(.linkChanged(.connected))
        #expect(store.savedState != nil)
        store.locked = true
        let next = await h.relaunch()
        store.locked = false
        let alert = PumpAlert(id: 0, kind: .alert, title: "Low insulin")
        async let ledger: () = next.coordinator.ledgerChanged()
        async let pump: () = next.send(.alertsChanged([alert]))
        async let tick: () = next.coordinator.tick()
        _ = await (ledger, pump, tick)
        #expect(await next.coordinator.engine.state.pumpAlerts == [alert])
        #expect(await next.scheduler.held.values.contains { $0.title == "Low insulin" })
        #expect(await next.coordinator.heldInputCount == 0)
    }

    /// While the state can't be read the held inputs stay bounded: one kept per latest-only kind, and a cap
    /// on the rest.
    @Test func heldInputsAreBounded() async {
        let store = MemoryAlertStore()
        let h = await Harness.launch(store: store)
        store.locked = true
        let next = await h.relaunch()
        let before = await next.coordinator.heldInputCount
        for n in 0..<50 { await next.send(.alertsChanged([PumpAlert(id: 0, kind: .alert, title: "A\(n)")])) }
        #expect(await next.coordinator.heldInputCount == before + 1)
        for n in 0..<(AlertCoordinator.deferredInputsCap + 20) {
            await next.coordinator.remoteBolusRefused(peerId: "garmin", requestId: "r\(n)", reason: "no")
        }
        #expect(await next.coordinator.heldInputCount == AlertCoordinator.deferredInputsCap)
    }
}
