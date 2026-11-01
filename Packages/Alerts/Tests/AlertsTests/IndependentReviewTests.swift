import Foundation
import Testing
import faBolusCore

@testable import Alerts

/// The sequences the session actually produces around a relaunch, a forgotten or mismatched pump, late
/// events and the notification permission, each of which once lost, kept or repeated a notification.
@Suite struct IndependentReviewTests {
    let m: TimeInterval = 60

    private func low(_ clock: TestClock) -> GlucoseSourceState {
        GlucoseSourceState(
            latest: GlucoseSample(mgdl: 48, date: clock.now, sourceID: "dexcom-share"), status: .connected)
    }

    private func stalePump(_ clock: TestClock) -> PumpState {
        var s = PumpState()
        let taken = clock.now.addingTimeInterval(-20 * m)
        s.glucose = Observed(PumpGlucose(mgdl: 90, trend: nil), measuredAt: taken, receivedAt: taken)
        return s
    }

    /// A relaunched process knows nothing of the backup until it reports; judging before then would
    /// withdraw an urgent low that is still real (and re-alert it a reading later).
    @Test func aRelaunchKeepsTheUrgentLowUntilTheBackupReports() async {
        let h = await Harness.launch()
        await h.coordinator.backupGlucoseChanged(low(h.clock))
        #expect(await h.scheduler.held[UrgentLowAlarm.dedupeKey] != nil)
        await h.scheduler.clearCalls()
        let next = await h.relaunch(reportNoBackup: false)
        await next.send(.readingsChanged([.glucose], stalePump(next.clock)))
        await next.coordinator.tick()
        #expect(await next.scheduler.calls.isEmpty, "nothing withdrawn or re-posted before the backup reports")
        await next.coordinator.backupGlucoseChanged(low(next.clock))
        #expect(await next.scheduler.calls.isEmpty, "still the same low: not posted again")
    }

    /// An input during the fresh-start clean-up's await is performed after it, never removed by it.
    @Test func anInputDuringTheCleanUpIsNotRemovedByIt() async throws {
        let scheduler = FakeScheduler()
        await scheduler.setRemoveDelay(.milliseconds(100))
        let clock = TestClock()
        let ledger = DurableBolusLedger(store: MemoryLedgerStore(), now: clock.now)
        let coordinator = AlertCoordinator(
            store: MemoryAlertStore(), scheduler: scheduler, ledger: ledger, tickInterval: nil, clock: { clock.now })
        let (stream, _) = AsyncStream<PumpEvent>.makeStream()
        let starting = Task { await coordinator.start(events: stream) }
        try await Task.sleep(for: .milliseconds(20))
        await coordinator.backupGlucoseChanged(low(clock))
        await starting.value
        #expect(await scheduler.held[UrgentLowAlarm.dedupeKey] != nil)
    }

    /// Forgetting the pump while it is down: the session sends no requested disconnect (there is no
    /// connection to close), so the app says so and everything about the pump goes.
    @Test func forgettingThePumpWhileDownWithdrawsEverythingAboutIt() async {
        let h = await Harness.launch()
        await h.send(.disconnected(.linkLost(code: nil)))
        await h.send(.connectionUnstable)
        await h.send(.alertsChanged([PumpAlert(id: 0, kind: .alert, title: "Low insulin")]))
        await h.send(.linkChanged(.disconnected))
        await h.coordinator.pairingForgotten()
        #expect(await h.scheduler.held.isEmpty)
        #expect(await h.coordinator.snapshot.active.isEmpty)
    }

    /// A different pump under the pairing: the session closes the link, and the requested disconnect that
    /// follows doesn't hide that the user's pump is unreachable.
    @Test func anIdentityMismatchLeavesThePumpDown() async {
        let h = await Harness.launch()
        let at = h.clock.now
        await h.send(.linkFailed(.identityMismatch))
        await h.send(.disconnected(.requested))
        #expect(await h.scheduler.held[DisconnectEscalation.firstNoticeId]?.fireDate == at.addingTimeInterval(15 * m))
        // A later requested disconnect is the user's again.
        await h.send(.disconnected(.requested))
        #expect(await h.scheduler.held.isEmpty)
    }

    /// A paired pump this process never reaches is announced: a pending connect never fails, so no drop
    /// is reported. Within the first minute, even "immediately" waits for the connection being restored.
    @Test func aPairedPumpThatNeverConnectsAfterLaunchIsAnnounced() async {
        let store = MemoryAlertStore()
        try? store.savePolicy(AlertPolicy(pumpDisconnectDelay: .immediately))
        let h = await Harness.launch(store: store, pumpPaired: true)
        let launch = h.clock.now
        #expect(await h.scheduler.held[DisconnectEscalation.firstNoticeId]?.fireDate == launch.addingTimeInterval(m))
        await h.send(.linkChanged(.connecting))
        await h.send(.linkChanged(.connected))
        #expect(await h.scheduler.held.isEmpty, "connected within the minute: nothing shown")
        // Without a paired pump nothing starts.
        let unpaired = await Harness.launch()
        #expect(await unpaired.scheduler.held.isEmpty)
    }

    /// The drop after a probe is expected; with "immediately" it still waits a minute, unless a real drop
    /// follows.
    @Test func theDropAfterAProbeGetsAGraceARealDropDoesnt() async {
        let h = await Harness.launch()
        await h.coordinator.setPolicy(AlertPolicy(pumpDisconnectDelay: .immediately))
        let at = h.clock.now
        await h.send(.disconnected(.afterUnsupportedRequest(opcode: 60)))
        #expect(await h.scheduler.held[DisconnectEscalation.firstNoticeId]?.fireDate == at.addingTimeInterval(m))
        await h.send(.disconnected(.linkLost(code: nil)))
        #expect(await h.scheduler.held[DisconnectEscalation.firstNoticeId]?.fireDate == at)
    }

    /// The ledger can be several steps ahead of the events; the late ones neither re-track the bolus nor
    /// announce it again.
    @Test func lateEventsSeveralStepsBehindTheLedgerAnnounceOnce() async throws {
        let h = await Harness.launch()
        let request = Fixtures.request()
        let key = request.ledgerKey
        _ = try await h.ledger.begin(request, now: h.clock.now)
        _ = try await h.ledger.markAccepted(key, bolusId: 7, pumpKey: "pump", pumpClock: 1, now: h.clock.now)
        _ = try await h.ledger.markRefused(key, reason: "Refused.", now: h.clock.now)
        await h.send(.bolusOutcome(key, .requested))
        await h.send(.bolusOutcome(key, .accepted))
        await h.send(.bolusOutcome(key, .refused(reason: "Refused.")))
        #expect(await h.scheduler.adds.count == 1)
        #expect(await h.coordinator.snapshot.banners.isEmpty, "never shown as unknown")
    }

    /// A remote resends the same request after a reconnect: refused once, announced once.
    @Test func aResentRemoteRefusalIsAnnouncedOnce() async {
        let h = await Harness.launch()
        for _ in 0..<3 {
            await h.coordinator.remoteBolusRefused(peerId: "garmin", requestId: "r1", reason: "Read-only.")
        }
        #expect(await h.scheduler.adds.count == 1)
    }

    /// Before the user answers the permission prompt the OS refuses posts; once authorized they are posted.
    @Test func postsRefusedBeforeThePromptArePostedOnceAuthorized() async {
        let scheduler = FakeScheduler()
        await scheduler.setPermission(.notDetermined)
        await scheduler.setRefuseAdds(true)
        let h = await Harness.launch(scheduler: scheduler)
        await h.send(.connectionUnstable)
        #expect(await scheduler.held.isEmpty)
        await scheduler.setRefuseAdds(false)
        await scheduler.setPermission(
            NotificationPermission(authorization: .authorized, alerts: .enabled, timeSensitive: .enabled))
        await h.coordinator.tick()
        #expect(await scheduler.held[AlertEngine.connectionUnstableId] != nil)
    }

    /// The settled result replaces the unknown notice by posting under its identifier; no withdrawal is
    /// sent first that could race the post and remove the result.
    @Test func theSettledResultIsNotPrecededByAWithdrawalOfItsIdentifier() async throws {
        let h = await Harness.launch()
        let request = Fixtures.request()
        let key = request.ledgerKey
        let id = AlertEngine.bolusIdentifier(key)
        _ = try await h.ledger.begin(request, now: h.clock.now)
        await h.send(.bolusOutcome(key, .requested))
        _ = try await h.ledger.markAccepted(key, bolusId: 7, pumpKey: "pump", pumpClock: 1, now: h.clock.now)
        _ = try await h.ledger.markUnknown(key, now: h.clock.now)
        await h.send(.bolusOutcome(key, .unknown(since: h.clock.now)))
        await h.scheduler.clearCalls()
        _ = try await h.ledger.markDeliveredFromHistory(key, units: 2, historyPumpKey: "pump", now: h.clock.now)
        await h.send(.bolusOutcome(key, .delivered(units: 2)))
        #expect(await !h.scheduler.removed.contains(id))
        #expect(await h.scheduler.held[id]?.title == "Bolus delivered")
    }

    /// A ledger with no store is empty, which says nothing about the boluses being followed.
    @Test func aLedgerWithNoStoreDoesntDropFollowedBoluses() {
        var engine = AlertEngine()
        let key = Fixtures.request().ledgerKey
        engine.handle(.pump(.bolusOutcome(key, .requested)), now: TestClock().now)
        engine.handle(.pump(.bolusOutcome(key, .unknown(since: TestClock().now))), now: TestClock().now)
        engine.handle(.ledger(LedgerView(RemoteBolusLedger(), block: .noDurableStore)), now: TestClock().now)
        #expect(engine.hasOpenBolusResult)
    }
}
