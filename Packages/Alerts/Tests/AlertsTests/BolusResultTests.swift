import Foundation
import Testing
import faBolusCore

@testable import Alerts

/// The bolus result (R11): an unknown outcome is announced right away and how it settles is announced
/// once, both time-sensitive, and the app never suppresses either. Driven the way the session drives it:
/// the ledger records, then the session emits `.bolusOutcome`.
@Suite struct BolusResultTests {
    let request = Fixtures.request()
    var key: RemoteBolusLedger.Key { request.ledgerKey }
    var id: String { AlertEngine.bolusIdentifier(key) }

    /// Every switch off: the most hostile policy a user can set.
    static var everythingOff: AlertPolicy {
        var p = AlertPolicy()
        for c in NotificationBroker.Category.allCases { p.setOn(false, for: c) }
        return p
    }

    /// The session's path to an unknown outcome: recorded, accepted, sent, then lost track.
    private func goUnknown(_ h: Harness) async throws {
        _ = try await h.ledger.begin(request, now: h.clock.now)
        await h.send(.bolusOutcome(key, .requested))
        _ = try await h.ledger.markAccepted(key, bolusId: 7, pumpKey: "pump", pumpClock: 100, now: h.clock.now)
        await h.send(.bolusOutcome(key, .accepted))
        _ = try await h.ledger.markDelivering(key, now: h.clock.now)
        await h.send(.bolusOutcome(key, .delivering))
        _ = try await h.ledger.markUnknown(key, now: h.clock.now)
        await h.send(.bolusOutcome(key, .unknown(since: h.clock.now)))
    }

    @Test func anUnknownOutcomeIsAnnouncedRightAwayTimeSensitive() async throws {
        let h = await Harness.launch()
        try await goUnknown(h)
        let posted = await h.scheduler.adds
        #expect(posted.map(\.identifier) == [id], "exactly one notice, and nothing for the steps before")
        let notice = try #require(posted.first)
        #expect(notice.category == .bolusReconciliation)
        #expect(notice.level == .timeSensitive)
        #expect(notice.fireDate == nil, "right away")
        #expect(notice.title == "Bolus outcome unknown")
        #expect(!notice.body.lowercased().contains("fail"), "an unknown outcome is never called failed")
    }

    /// The app never suppresses the bolus result: with every switch off, the unknown notice and the
    /// settled announcement both post, time-sensitive.
    @Test func theBolusResultIsPostedWithEverySwitchOff() async throws {
        let h = await Harness.launch()
        await h.coordinator.setPolicy(Self.everythingOff)
        try await goUnknown(h)
        _ = try await h.ledger.markDeliveredFromHistory(key, units: 2, historyPumpKey: "pump", now: h.clock.now)
        await h.send(.bolusOutcome(key, .delivered(units: 2)))
        let posted = await h.scheduler.adds
        #expect(posted.count == 2)
        #expect(posted.allSatisfy { $0.category == .bolusReconciliation && $0.level == .timeSensitive })
    }

    /// Turning every category off, or changing the policy at all, never withdraws an open notice.
    @Test func noPolicyChangeWithdrawsAnOpenNotice() async throws {
        let h = await Harness.launch()
        try await goUnknown(h)
        await h.scheduler.clearCalls()
        await h.coordinator.setPolicy(Self.everythingOff)
        await h.coordinator.setPolicy(AlertPolicy(pumpDisconnectDelay: .immediately))
        #expect(await !h.scheduler.removed.contains(id))
        #expect(await h.scheduler.held[id] != nil)
    }

    @Test func aSettledOutcomeReplacesTheNoticeOnceAndIsNotRepeated() async throws {
        let h = await Harness.launch()
        try await goUnknown(h)
        _ = try await h.ledger.markDeliveredFromHistory(key, units: 1.5, historyPumpKey: "pump", now: h.clock.now)
        await h.send(.bolusOutcome(key, .delivered(units: 1.5)))
        let settled = try #require(await h.scheduler.held[id])
        #expect(settled.title == "Bolus delivered")
        #expect(settled.body.contains("1.50 U"))
        // The same event again, a ledger re-read and a tick: no second announcement.
        await h.scheduler.clearCalls()
        await h.send(.bolusOutcome(key, .delivered(units: 1.5)))
        await h.coordinator.ledgerChanged()
        await h.coordinator.tick()
        #expect(await h.scheduler.adds.isEmpty)
        #expect(await h.scheduler.held[id] == settled, "the announcement stays; nothing withdraws it")
    }

    @Test func historyShowingItNeverStartedIsAnnouncedAsNotDeliveredNeverAsUnknown() async throws {
        let h = await Harness.launch()
        try await goUnknown(h)
        _ = try await h.ledger.markAbsentFromHistory(key, historyPumpKey: "pump", now: h.clock.now)
        await h.send(.bolusOutcome(key, .failed(reason: "Pump history shows no such bolus.")))
        let settled = try #require(await h.scheduler.held[id])
        #expect(settled.title == "Bolus not delivered")
        #expect(settled.category == .bolusReconciliation)
    }

    /// Confirming on the pump lifts the block: the notice and the banner go, but the bolus is still
    /// followed, so a later settlement from history is announced.
    @Test func confirmingOnThePumpWithdrawsTheNoticeAndASettlementIsStillAnnounced() async throws {
        let h = await Harness.launch()
        try await goUnknown(h)
        #expect(await h.coordinator.snapshot.banners == [.unknownBolusOutcome])
        _ = try await h.ledger.confirmOnPump(key, now: h.clock.now)
        await h.coordinator.ledgerChanged()
        #expect(await h.scheduler.held[id] == nil)
        #expect(await h.coordinator.snapshot.banners.isEmpty)
        _ = try await h.ledger.markDeliveredFromHistory(key, units: 2, historyPumpKey: "pump", now: h.clock.now)
        await h.send(.bolusOutcome(key, .delivered(units: 2)))
        #expect(await h.scheduler.held[id]?.title == "Bolus delivered")
    }

    /// A bolus that ends normally while the app runs is reported where it was asked for: no notification.
    @Test func aNormalDeliveryPostsNothing() async throws {
        let h = await Harness.launch()
        _ = try await h.ledger.begin(request, now: h.clock.now)
        await h.send(.bolusOutcome(key, .requested))
        _ = try await h.ledger.markAccepted(key, bolusId: 7, pumpKey: "pump", pumpClock: 100, now: h.clock.now)
        await h.send(.bolusOutcome(key, .accepted))
        _ = try await h.ledger.markDelivered(key, units: 2, now: h.clock.now)
        await h.send(.bolusOutcome(key, .delivered(units: 2)))
        #expect(await h.scheduler.adds.isEmpty)
        #expect(await h.coordinator.snapshot.banners.isEmpty)
    }

    /// A refusal or a known failure is "Bolus not delivered": standard level, and switchable.
    @Test func aRefusalIsBolusNotDeliveredAndCanBeTurnedOff() async throws {
        let h = await Harness.launch()
        _ = try await h.ledger.begin(request, now: h.clock.now)
        await h.send(.bolusOutcome(key, .requested))
        _ = try await h.ledger.markRefused(key, reason: "The pump refused the bolus.", now: h.clock.now)
        await h.send(.bolusOutcome(key, .refused(reason: "The pump refused the bolus.")))
        let notice = try #require(await h.scheduler.adds.first)
        #expect(notice.category == .bolusDeliveryFailed)
        #expect(notice.level == .active)
        #expect(notice.body == "The pump refused the bolus.")

        let off = await Harness.launch()
        var policy = AlertPolicy()
        policy.setOn(false, for: .bolusDeliveryFailed)
        await off.coordinator.setPolicy(policy)
        _ = try await off.ledger.begin(request, now: off.clock.now)
        await off.send(.bolusOutcome(key, .requested))
        _ = try await off.ledger.markRefused(key, reason: "No.", now: off.clock.now)
        await off.send(.bolusOutcome(key, .refused(reason: "No.")))
        #expect(await off.scheduler.adds.isEmpty)
    }

    @Test func anUnreadableLedgerIsAnnouncedAndBanneredUntilItReads() async throws {
        let ledgerStore = MemoryLedgerStore()
        ledgerStore.corrupt = true
        let h = await Harness.launch(ledgerStore: ledgerStore)
        let notice = try #require(await h.scheduler.held[RemoteBolusLedger.unreadableLedgerReconciliationDedupeKey])
        #expect(notice.level == .timeSensitive)
        let banners = await h.coordinator.snapshot.banners
        #expect(banners == [.bolusRecordUnreadable])
        #expect(banners.first?.body == BolusBlock.ledgerUnreadable.userMessage, "history can't fix this one")
        // Readable again on the next launch: the notice goes.
        ledgerStore.corrupt = false
        let next = await h.relaunch()
        #expect(await next.scheduler.held[RemoteBolusLedger.unreadableLedgerReconciliationDedupeKey] == nil)
        #expect(await next.coordinator.snapshot.banners.isEmpty)
    }

    /// The session records before it emits, so the ledger read after one event can already show a later
    /// outcome. That outcome is announced from the read, and its own event, arriving after, adds nothing.
    @Test func aLedgerReadAheadOfTheEventsDoesntAnnounceTwice() async throws {
        let h = await Harness.launch()
        _ = try await h.ledger.begin(request, now: h.clock.now)
        // Refused before the coordinator saw `.requested`: its post-event ledger read shows the refusal.
        _ = try await h.ledger.markRefused(key, reason: "The pump refused the bolus.", now: h.clock.now)
        await h.send(.bolusOutcome(key, .requested))
        await h.send(.bolusOutcome(key, .refused(reason: "The pump refused the bolus.")))
        #expect(await h.scheduler.adds.count == 1, "one \"Bolus not delivered\", not two")

        // Unknown, then settled from history before the coordinator saw the unknown event.
        let other = Fixtures.request("garmin", "r2")
        _ = try await h.ledger.begin(other, now: h.clock.now)
        await h.send(.bolusOutcome(other.ledgerKey, .requested))
        _ = try await h.ledger.markAccepted(
            other.ledgerKey, bolusId: 8, pumpKey: "pump", pumpClock: 1, now: h.clock.now)
        _ = try await h.ledger.markUnknown(other.ledgerKey, now: h.clock.now)
        await h.send(.bolusOutcome(other.ledgerKey, .unknown(since: h.clock.now)))
        _ = try await h.ledger.markAbsentFromHistory(other.ledgerKey, historyPumpKey: "pump", now: h.clock.now)
        await h.coordinator.ledgerChanged()
        await h.scheduler.clearCalls()
        await h.send(.bolusOutcome(other.ledgerKey, .failed(reason: "absent")))
        #expect(await h.scheduler.calls.isEmpty, "the late event doesn't replace the bolus result")
        #expect(await h.scheduler.held[AlertEngine.bolusIdentifier(other.ledgerKey)]?.category == .bolusReconciliation)
    }

    @Test func aRemoteRefusalIsPostedUnderItsOwnSwitch() async {
        let h = await Harness.launch()
        await h.coordinator.remoteBolusRefused(peerId: "garmin", requestId: "r9", reason: "Remotes are read-only.")
        let notice = await h.scheduler.adds.first
        #expect(notice?.category == .remoteBolusRejected)
        #expect(notice?.body == "Remotes are read-only.")
        var policy = AlertPolicy()
        policy.setOn(false, for: .remoteBolusRejected)
        await h.coordinator.setPolicy(policy)
        await h.scheduler.clearCalls()
        await h.coordinator.remoteBolusRefused(peerId: "garmin", requestId: "r10", reason: "x")
        #expect(await h.scheduler.adds.isEmpty)
    }
}
