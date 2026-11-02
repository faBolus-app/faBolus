@testable import Alerts
import Foundation
import PumpSession
import RemoteProtocol
import Testing
import WatchLink
import faBolusCore

@testable import RemoteHost

@MainActor
@Suite struct RemoteHostBolusTests {
    @Test func aBolusIsAcknowledgedThenDelivered() async {
        let rig = HostRig()
        await rig.services.set(
            decision: .deliver(composed("b1")),
            delivery: .started(.init(peerId: "garmin", requestId: "b1"), .delivering))
        await rig.start()
        await rig.receive(bolus("b1"))
        #expect(rig.transport.outcomes.map(\.outcome) == [.received, .delivering])
        #expect(rig.transport.outcomes.last?.requestedMilliunits == 2000)
        #expect(await rig.services.delivered.count == 1)
        let request = await rig.services.composed.first
        #expect(request?.amount == .units(2))
        #expect(request?.surface == .garmin)
        #expect(request?.peerId == "garmin")
    }

    /// A resend while the first is still being worked on is answered, not composed again.
    @Test func aDuplicateInFlightIsAnsweredNotDeliveredTwice() async {
        let rig = HostRig()
        await rig.services.set(
            decision: .deliver(composed("b1")),
            delivery: .started(.init(peerId: "garmin", requestId: "b1"), .delivering),
            delay: .milliseconds(50))
        await rig.start()
        rig.transport.handler?(.received(bolus("b1").wire))
        rig.transport.handler?(.received(bolus("b1").wire))
        try? await Task.sleep(for: .milliseconds(150))
        await rig.settle()
        #expect(await rig.services.composed.count == 1)
        #expect(await rig.services.delivered.count == 1)
    }

    /// Refused before the ledger: the watch is told why and the refusal is announced; a resend gets the
    /// same answer without a second attempt.
    @Test func aRefusalIsAnsweredOnceAndRepeatedOnResend() async {
        let rig = HostRig()
        await rig.services.set(decision: .refused(.unavailable(.accessDenied(.remotesReadOnly))))
        await rig.start()
        await rig.receive(bolus("b2"))
        #expect(rig.transport.outcomes.map(\.outcome) == [.received, .failed])
        #expect(rig.transport.outcomes.last?.message == AccessPolicy.DenialReason.remotesReadOnly.userMessage)
        #expect(await rig.services.refusals == ["b2"])
        await rig.receive(bolus("b2"))
        #expect(await rig.services.composed.count == 1)
        #expect(rig.transport.outcomes.last?.outcome == .failed)
        // And a poll naming it gets it again.
        await rig.receive(
            .poll(
                .init(
                    configRevision: nil, awaitingRequestId: "b2", wantsHistory: false, freshGlucose: false,
                    appVersion: "t")))
        #expect(rig.transport.outcomes.filter { $0.outcome == .failed }.count == 3)
    }

    @Test func aDeliveryThatCantStartIsAFailure() async {
        let rig = HostRig()
        await rig.services.set(
            decision: .deliver(composed("b3")), delivery: .notStarted(.blocked(.unknownOutcome(since: HostRig.now))))
        await rig.start()
        await rig.receive(bolus("b3"))
        #expect(rig.transport.outcomes.last?.outcome == .failed)
        #expect(await rig.services.refusals == ["b3"])
    }

    /// The ledger holds the request already: its outcome, never a second delivery.
    @Test func aRecordedRequestGetsItsOutcome() async {
        let rig = HostRig()
        await rig.services.set(entry: entry("b4", delivered: 2))
        await rig.services.set(decision: .alreadyRecorded(.delivered(units: 2)))
        await rig.start()
        await rig.receive(bolus("b4"))
        #expect(rig.transport.outcomes.last?.outcome == .delivered)
        #expect(rig.transport.outcomes.last?.deliveredMilliunits == 2000)
        #expect(await rig.services.delivered.isEmpty)
    }

    /// The session's later moves for this remote's request reach the watch; another peer's don't.
    @Test func sessionOutcomesForThisRemoteAreSent() async {
        let rig = HostRig()
        await rig.services.set(entry: entry("b5", delivered: 1.5))
        await rig.start()
        await rig.host.pumpEvent(.bolusOutcome(.init(peerId: "garmin", requestId: "b5"), .delivered(units: 1.5)))
        await rig.host.pumpEvent(.bolusOutcome(.init(peerId: "phone", requestId: "p1"), .delivered(units: 3)))
        await rig.settle()
        #expect(rig.transport.outcomes.map(\.requestId) == ["b5"])
        #expect(rig.transport.outcomes.first?.deliveredMilliunits == 1500)
        #expect(rig.transport.outcomes.first?.requestedMilliunits == 2000)
    }

    /// After a relaunch the phone holds nothing in memory; the watch's poll names the request and the
    /// ledger answers.
    @Test func aPollNamingARequestGetsItsOutcomeFromTheLedger() async {
        let rig = HostRig()
        await rig.services.set(entry: entry("b6", delivered: 2))
        await rig.start()
        await rig.receive(fixture: "poll")
        await rig.receive(
            .poll(
                .init(
                    configRevision: nil, awaitingRequestId: "b6", wantsHistory: false, freshGlucose: false,
                    appVersion: "t")))
        #expect(rig.transport.outcomes.map(\.requestId) == ["b6"])
        #expect(rig.transport.outcomes.first?.outcome == .delivered)
    }

    /// A request the phone has never seen isn't called failed: the message carrying it may still arrive.
    @Test func aPollNamingAnUnknownRequestGetsNoOutcome() async {
        let rig = HostRig()
        await rig.start()
        await rig.receive(
            .poll(
                .init(
                    configRevision: nil, awaitingRequestId: "never", wantsHistory: false, freshGlucose: false,
                    appVersion: "t")))
        #expect(rig.transport.outcomes.isEmpty)
    }

    @Test func anUnreadableBolusIsAnsweredAsNotDelivered() async {
        let rig = HostRig()
        await rig.start()
        rig.transport.handler?(
            .received(
                .object([
                    "version": .int(2), "kind": .string("bolus"),
                    "payload": .object(["requestId": .string("bad"), "mode": .string("units"), "mU": .double(2.5)])
                ])))
        await rig.settle()
        #expect(rig.transport.outcomes.map(\.outcome) == [.failed])
        #expect(await rig.services.composed.isEmpty)
    }

    /// The old watch app's bolus request is answered in its own form and never reaches the composer.
    @Test func aVersionOneBolusNeverReachesTheComposer() async {
        let rig = HostRig()
        await rig.start()
        await rig.receive(fixture: "v1-bolusRequest-from-watch")
        #expect(await rig.services.composed.isEmpty)
        let reply = GoldenFixtures.fixtures.first { $0.name == "v1-reply-to-bolusRequest" }!.wire
        #expect(rig.transport.sent.contains(reply))
    }

    /// Cancel is never gated: read-only and bolusing off don't stop it.
    @Test func cancelIsNeverGated() async {
        let rig = HostRig(settings: HostRig.settings(readOnly: true, enabled: false))
        await rig.start()
        await rig.receive(fixture: "cancel")
        #expect(await rig.services.cancels == 1)
    }

    /// A cancel that arrives while one is with the session isn't dropped: the session is asked again once
    /// the first returns, since that one may have found nothing to stop before a delivery started.
    @Test func aCancelDuringACancelRunsAgain() async {
        let rig = HostRig()
        await rig.services.set(cancelDelay: .milliseconds(200))
        await rig.start()
        await rig.receive(fixture: "cancel")
        await rig.receive(fixture: "cancel")
        try? await Task.sleep(for: .milliseconds(600))
        await rig.settle()
        #expect(await rig.services.cancels == 2)
    }

    /// A request refused before the ledger is recorded there, so after a relaunch, with a ledger read back
    /// from its file, its resend gets the same refusal and nothing is composed. However many other requests
    /// were refused in between.
    @Test(arguments: [0, 20])
    func aRefusalSurvivesARelaunch(othersBetween: Int) async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("host-ledger-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        func bolus(_ id: String) -> BolusRequestPayload {
            BolusRequestPayload(
                requestId: id, sentAt: GoldenFixtures.now, amount: .units(milliunits: 2000), glucoseMgdl: nil,
                includeStaleGlucose: false)
        }
        let first = HostRig(services: FakeServices(ledgerStore: RemoteBolusLedgerStore(url: url)))
        await first.services.set(decision: .refused(.unavailable(.pumpNotLinked)))
        await first.start()
        await first.receive(.bolus(bolus("x")))
        for i in 0..<othersBetween { await first.receive(.bolus(bolus("other-\(i)"))) }
        let told = try #require(first.transport.outcomes.last { $0.requestId == "x" })
        #expect(told.outcome == .failed)

        let relaunched = HostRig(services: FakeServices(ledgerStore: RemoteBolusLedgerStore(url: url)))
        await relaunched.start()
        await relaunched.receive(.bolus(bolus("x")))
        #expect(await relaunched.services.composed.isEmpty)
        let again = try #require(relaunched.transport.outcomes.last { $0.requestId == "x" })
        #expect(again.outcome == .failed)
        #expect(again.message == told.message)
        // Not announced a second time.
        #expect(await relaunched.services.refusals.isEmpty)
    }

    /// One request's refusal doesn't stop the next one being composed. (That the ledger doesn't block on a
    /// refusal is DurableBolusLedgerTests'.)
    @Test func aRefusalDoesntStopTheNextRequest() async {
        let rig = HostRig()
        await rig.services.set(decision: .refused(.unavailable(.pumpNotLinked)))
        await rig.start()
        await rig.receive(
            .bolus(
                BolusRequestPayload(
                    requestId: "a", sentAt: GoldenFixtures.now, amount: .units(milliunits: 2000), glucoseMgdl: nil,
                    includeStaleGlucose: false)))
        await rig.receive(
            .bolus(
                BolusRequestPayload(
                    requestId: "b", sentAt: GoldenFixtures.now, amount: .units(milliunits: 2000), glucoseMgdl: nil,
                    includeStaleGlucose: false)))
        #expect(await rig.services.composed.map(\.id) == ["a", "b"])
    }

    /// A cancel naming a request the phone hasn't seen is recorded in the ledger, so a copy that arrives
    /// after a relaunch is refused and nothing is composed. One the ledger has an entry for is answered from
    /// the entry, never as cancelled: its delivery may have gone in.
    @Test func aCancelNamingALateRequestSurvivesARelaunchButNotADelivery() async throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("host-ledger-\(UUID()).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let late = BolusRequestPayload(
            requestId: "late-1", sentAt: GoldenFixtures.now, amount: .units(milliunits: 2000), glucoseMgdl: nil,
            includeStaleGlucose: false)
        let first = HostRig(services: FakeServices(ledgerStore: RemoteBolusLedgerStore(url: url)))
        await first.start()
        await first.receive(.cancel(CancelPayload(requestId: "c-1", bolusRequestId: "late-1")))
        try? await Task.sleep(for: .milliseconds(50))
        let relaunched = HostRig(services: FakeServices(ledgerStore: RemoteBolusLedgerStore(url: url)))
        await relaunched.start()
        await relaunched.receive(.bolus(late))
        #expect(await relaunched.services.composed.isEmpty)
        #expect(relaunched.transport.outcomes.last { $0.requestId == "late-1" }?.message == RemoteHost.cancelledMessage)

        // A request already delivered, then named by a cancel: its resend gets its own outcome.
        let rig = HostRig()
        var ledger = RemoteBolusLedger()
        let request = DoseRequest(
            id: "done-1", origin: .remote(peerId: "garmin", sentAt: HostRig.now), shape: .now(units: 2))
        _ = ledger.begin(request, now: HostRig.now)
        _ = ledger.markAccepted(request.ledgerKey, bolusId: 7, now: HostRig.now)
        _ = ledger.markDelivered(request.ledgerKey, units: 2, now: HostRig.now)
        await rig.services.set(entry: try #require(ledger.entry(request.ledgerKey)))
        await rig.services.set(decision: .alreadyRecorded(.delivered(units: 2)))
        await rig.start()
        await rig.receive(.cancel(CancelPayload(requestId: "c-2", bolusRequestId: "done-1")))
        await rig.receive(
            .bolus(
                BolusRequestPayload(
                    requestId: "done-1", sentAt: GoldenFixtures.now, amount: .units(milliunits: 2000), glucoseMgdl: nil,
                    includeStaleGlucose: false)))
        #expect(rig.transport.outcomes.last { $0.requestId == "done-1" }?.outcome == .delivered)
    }

    /// A cancel the session couldn't confirm is tried again, a bounded number of times.
    @Test func anUnconfirmedCancelIsTriedAgain() async {
        let rig = HostRig()
        await rig.services.set(cancelResults: [.notConnected, .unconfirmed, .cancelled])
        await rig.start()
        await rig.host.setCancelRetryDelay(.milliseconds(10))
        await rig.receive(fixture: "cancel")
        try? await Task.sleep(for: .milliseconds(200))
        await rig.settle()
        #expect(await rig.services.cancels == 3)
        // It stops trying after its retries.
        let stuck = HostRig()
        await stuck.services.set(cancelResults: Array(repeating: .notConnected, count: 10))
        await stuck.start()
        await stuck.host.setCancelRetryDelay(.milliseconds(10))
        await stuck.receive(fixture: "cancel")
        try? await Task.sleep(for: .milliseconds(300))
        await stuck.settle()
        #expect(await stuck.services.cancels == 4)
    }

    /// A cancel that names a request the phone hasn't seen yet refuses it when it arrives, so a copy the
    /// watch was still resending isn't delivered after the user cancelled it.
    @Test func aRequestCancelledBeforeItArrivesIsRefused() async {
        let rig = HostRig()
        await rig.services.set(decision: .refused(.noDoseSpecified))
        await rig.start()
        let bolus = BolusRequestPayload(
            requestId: "late-1", sentAt: GoldenFixtures.now, amount: .units(milliunits: 2000), glucoseMgdl: nil,
            includeStaleGlucose: false)
        await rig.receive(.cancel(CancelPayload(requestId: "c-1", bolusRequestId: "late-1")))
        await rig.receive(.bolus(bolus))
        #expect(await rig.services.composed.isEmpty)
        let outcomes = rig.transport.outcomes.filter { $0.requestId == "late-1" }
        #expect(outcomes.last?.outcome == .failed)
        #expect(outcomes.last?.message == RemoteHost.cancelledMessage)
    }

    @Test func v2RequestsMapExactly() {
        let carbs = BolusRequestPayload(
            requestId: "c", sentAt: GoldenFixtures.now, amount: .calculator(carbsGrams: 45, estimateMilliunits: 6050),
            glucoseMgdl: 142, includeStaleGlucose: true)
        let r = RemoteDoseRequest(v2: carbs, peerId: "garmin", surface: .garmin)
        #expect(r.amount == .calculator(carbsGrams: 45, estimateUnits: 6.05))
        #expect(r.glucoseMgdl == 142)
        #expect(r.includeStaleGlucose)
        #expect(r.sentAt == Date(timeIntervalSince1970: TimeInterval(GoldenFixtures.now)))
    }
}

@MainActor
@Suite struct RemoteHostDismissTests {
    static let pumpAlert = PumpAlert(id: 2, kind: .alert, title: "Low insulin", remoteClear: .available)
    static func active(_ id: String, pump: PumpAlert?) -> ActiveAlert {
        ActiveAlert(
            AlertRequest(
                identifier: id, category: .pumpAlert, severity: .warning, level: .active, title: "Low insulin",
                body: "", pumpAlert: pump))
    }

    @Test func aPumpAlertIsDismissedOnceAndTheResultKept() async {
        let rig = HostRig()
        await rig.start()
        await rig.host.alertsChanged([Self.active("pump.alert.2", pump: Self.pumpAlert)])
        await rig.receive(fixture: "dismiss")
        await rig.receive(fixture: "dismiss")
        #expect(await rig.services.dismissed.count == 1)
        #expect(rig.transport.dismissResults.map(\.result) == [.cleared, .cleared])
    }

    @Test func anUnknownAlertIsNotFound() async {
        let rig = HostRig()
        await rig.start()
        await rig.receive(fixture: "dismiss")
        #expect(rig.transport.dismissResults.map(\.result) == [.notFound])
        #expect(await rig.services.dismissed.isEmpty)
    }

    /// An app alert has nothing on the pump to clear; a malfunction can't be cleared remotely.
    @Test func whatThePumpCantClearIsUnsupported() async {
        let rig = HostRig()
        await rig.start()
        let malfunction = PumpAlert(id: 4, kind: .alarm, title: "Malfunction", isDismissable: false, malfunctionCode: 4)
        await rig.host.alertsChanged([Self.active("pump.alert.2", pump: nil), Self.active("m", pump: malfunction)])
        await rig.receive(fixture: "dismiss")
        await rig.receive(.dismiss(.init(requestId: "d2", alertId: "m")))
        #expect(rig.transport.dismissResults.map(\.result) == [.unsupported, .unsupported])
        #expect(await rig.services.dismissed.isEmpty)
    }

    /// An alert the phone may still try clearing isn't offered to the watch, and a dismiss that arrives
    /// anyway sends nothing: the watch is told to clear it on the pump. A pump that answers "cleared" but
    /// leaves the alert is the same answer.
    @Test func theWatchClearsOnlyWhatCanBeClearedRemotely() async {
        let rig = HostRig()
        await rig.start()
        let tryable = PumpAlert(id: 2, kind: .alert, title: "Low insulin", remoteClear: .tryable)
        await rig.host.alertsChanged([Self.active("pump.alert.2", pump: tryable)])
        await rig.settle()
        #expect(rig.transport.statuses.last?.alerts.map(\.dismissable) == [false])
        await rig.receive(fixture: "dismiss")
        #expect(rig.transport.dismissResults.map(\.result) == [.unsupported])
        #expect(await rig.services.dismissed.isEmpty)

        let seen = HostRig()
        await seen.services.set(dismissOutcome: .notCleared)
        await seen.start()
        await seen.host.alertsChanged([Self.active("pump.alert.2", pump: Self.pumpAlert)])
        await seen.settle()
        #expect(seen.transport.statuses.last?.alerts.map(\.dismissable) == [true])
        await seen.receive(fixture: "dismiss")
        #expect(seen.transport.dismissResults.map(\.result) == [.unsupported])
    }

    /// An unconfirmed dismiss may be tried again.
    @Test func anUnconfirmedDismissIsRetried() async {
        let rig = HostRig()
        await rig.services.set(dismissOutcome: .unconfirmed)
        await rig.start()
        await rig.host.alertsChanged([Self.active("pump.alert.2", pump: Self.pumpAlert)])
        await rig.receive(fixture: "dismiss")
        await rig.receive(fixture: "dismiss")
        #expect(await rig.services.dismissed.count == 2)
    }
}

@MainActor
@Suite struct RemoteHostStatusTests {
    @Test func startingSendsTheConfigAndAStatus() async {
        let rig = HostRig()
        await rig.start()
        #expect(rig.transport.configs.count == 1)
        #expect(rig.transport.statuses.last?.configRevision == rig.transport.configs.first?.revision)
    }

    /// A change to the phone's freshness windows changes the watch's, through the config.
    @Test func aFreshnessChangeResendsTheConfig() async {
        let rig = HostRig()
        await rig.start()
        var settings = HostRig.settings()
        settings.freshness = FreshnessThresholds(glucoseStaleAfter: 12 * 60)
        await rig.host.settingsChanged(settings)
        await rig.settle()
        #expect(rig.transport.configs.count == 2)
        #expect(rig.transport.configs.last?.glucoseStaleMinutes == 12)
    }

    @Test func aSettingsChangeSendsTheNewConfigOnce() async {
        let rig = HostRig()
        await rig.start()
        var settings = HostRig.settings()
        settings.preferences.complicationLabels = true
        await rig.host.settingsChanged(settings)
        await rig.host.settingsChanged(settings)
        await rig.settle()
        #expect(rig.transport.configs.count == 2)
        #expect(rig.transport.configs.last?.complicationLabels == true)
        #expect(rig.transport.statuses.last?.configRevision == rig.transport.configs.last?.revision)
    }

    /// Turning remotes read-only reaches the watch's status at once, not only its config.
    @Test func readOnlyBlocksBolusingInTheStatus() async {
        let rig = HostRig()
        var state = PumpState()
        state.link = .connected
        state.model = .tslimX2
        await rig.services.set(state: state)
        await rig.start()
        #expect(rig.transport.statuses.last?.bolusBlock == nil)
        await rig.host.settingsChanged(HostRig.settings(readOnly: true))
        await rig.settle()
        #expect(rig.transport.statuses.last?.bolusBlock == .readOnly)
    }

    /// An outcome the phone couldn't save locks delivery on the watch; once it's saved, the watch is told.
    @Test func aSavedOutcomeUnlocksTheWatch() async {
        let rig = HostRig()
        var state = PumpState()
        state.link = .connected
        state.model = .tslimX2
        await rig.services.set(state: state)
        await rig.services.set(block: .outcomeNotSaved)
        await rig.start()
        #expect(rig.transport.statuses.last?.bolusBlock == .deliveryLocked)
        await rig.services.set(block: nil)
        await rig.host.pumpEvent(.bolusOutcomesSaved)
        await rig.settle()
        #expect(rig.transport.statuses.last?.bolusBlock == nil)
    }

    @Test func historyIsSentWhenAsked() async {
        let rig = HostRig()
        await rig.services.set(
            history: (0..<200).map {
                faBolusCore.GlucoseReading(date: HostRig.now.addingTimeInterval(TimeInterval(-300 * $0)), mgdl: 120)
            })
        await rig.start()
        await rig.receive(fixture: "poll")
        let history = rig.transport.messages.compactMap { m -> HistoryPayload? in
            if case .history(let h) = m { return h } else { return nil }
        }
        #expect(history.count == 1)
        #expect(history.first?.points.count == WireLimits.maxHistoryPoints)
        #expect(history.first?.points.last?.at == GoldenFixtures.now)
    }
}

/// The review's findings, each pinned.
@MainActor
@Suite struct RemoteHostReviewTests {
    /// A cancel while the bolus is still being composed has no session bolus to stop; the host stops it
    /// before the hand-off, and doesn't announce it as a refusal.
    @Test func aCancelDuringComposeStopsTheBolus() async {
        let rig = HostRig()
        await rig.services.set(
            decision: .deliver(composed("b1")),
            delivery: .started(.init(peerId: "garmin", requestId: "b1"), .delivering),
            delay: .milliseconds(80))
        await rig.start()
        rig.transport.handler?(.received(bolus("b1").wire))
        await rig.settle()
        await rig.receive(fixture: "cancel")
        try? await Task.sleep(for: .milliseconds(200))
        await rig.settle()
        #expect(await rig.services.delivered.isEmpty)
        #expect(await rig.services.cancels == 1)
        #expect(rig.transport.outcomes.last?.outcome == .failed)
        #expect(rig.transport.outcomes.last?.message == RemoteHost.cancelledMessage)
        #expect(await rig.services.refusals.isEmpty)
    }

    /// A damaged copy of a request being worked on doesn't call it failed.
    @Test func anUnreadableDuplicateOfALiveRequestIsIgnored() async {
        let rig = HostRig()
        await rig.services.set(
            decision: .deliver(composed("b1")),
            delivery: .started(.init(peerId: "garmin", requestId: "b1"), .delivering),
            delay: .milliseconds(80))
        await rig.start()
        rig.transport.handler?(.received(bolus("b1").wire))
        await rig.settle()
        rig.transport.handler?(
            .received(
                .object([
                    "version": .int(2), "kind": .string("bolus"),
                    "payload": .object(["requestId": .string("b1"), "mode": .string("units"), "mU": .double(2)])
                ])))
        try? await Task.sleep(for: .milliseconds(200))
        await rig.settle()
        #expect(!rig.transport.outcomes.contains { $0.outcome == .failed })
        #expect(rig.transport.outcomes.last?.outcome == .delivering)
    }

    /// Two refreshes overlap and the older finishes last: the newer snapshot stays.
    @Test func anOlderStatusRefreshFinishingLastIsDropped() async {
        let rig = HostRig()
        await rig.start()
        var old = PumpState()
        old.link = .connecting
        var new = PumpState()
        new.link = .connected
        await rig.services.set(pumpScript: [(.milliseconds(80), old), (.zero, new)])
        async let a: Void = rig.host.pumpEvent(.linkChanged(.connecting))
        try? await Task.sleep(for: .milliseconds(10))
        async let b: Void = rig.host.pumpEvent(.linkChanged(.connected))
        _ = await (a, b)
        await rig.settle()
        #expect(rig.transport.statuses.last?.pumpLink == .connected)
    }

    /// A status with nothing new isn't sent again; events that can't change it don't build one.
    @Test func anUnchangedStatusIsNotResent() async {
        let rig = HostRig()
        await rig.start()
        let before = rig.transport.statuses.count
        await rig.host.pumpEvent(.connectionRestored)
        await rig.host.pumpEvent(.historySync(.idle(lastSynced: nil)))
        await rig.settle()
        #expect(rig.transport.statuses.count == before)
    }

    /// A new reading at the same mg/dL is news: it carries its own time, so the status goes again. A backup
    /// CGM's reading reaches the watch through `glucoseChanged()`; with nothing new, nothing is sent.
    @Test func aNewReadingAtTheSameValueSendsAStatus() async {
        let rig = HostRig()
        var state = PumpState()
        state.link = .connected
        state.model = .tslimX2
        state.glucose = Observed(
            PumpGlucose(mgdl: 120, trend: .flat), measuredAt: HostRig.now.addingTimeInterval(-300),
            receivedAt: HostRig.now)
        await rig.services.set(state: state)
        await rig.start()
        let before = rig.transport.statuses.count
        state.glucose = Observed(PumpGlucose(mgdl: 120, trend: .flat), measuredAt: HostRig.now, receivedAt: HostRig.now)
        await rig.services.set(state: state)
        await rig.host.glucoseChanged()
        await rig.settle()
        #expect(rig.transport.statuses.count == before + 1)
        #expect(rig.transport.statuses.last?.glucose?.at == GoldenFixtures.now)
        #expect(rig.transport.statuses.last?.glucose?.value.mgdl == 120)
        await rig.host.glucoseChanged()
        await rig.settle()
        #expect(rig.transport.statuses.count == before + 1)
    }

    /// A finished history sync that found an auto-correction sends it with the next status. A host with
    /// none known, as after a relaunch before history shows one again, sends none: never a zero or an old
    /// time.
    @Test func aFinishedSyncSendsTheLastAutoCorrection() async {
        let rig = HostRig()
        await rig.start()
        #expect(rig.transport.statuses.last.map { $0.lastAutoCorrectionAt == nil } == true)
        let at = HostRig.now.addingTimeInterval(-1800)
        await rig.services.set(autoCorrection: at)
        await rig.host.pumpEvent(.historySync(.syncing))
        await rig.settle()
        #expect(rig.transport.statuses.last?.lastAutoCorrectionAt == nil)
        await rig.host.pumpEvent(.historySync(.idle(lastSynced: HostRig.now)))
        await rig.settle()
        #expect(rig.transport.statuses.last?.lastAutoCorrectionAt == Int(at.timeIntervalSince1970))
    }

    /// A long alert identifier gets a distinct wire ID that a dismiss still finds.
    @Test func longAlertIdentifiersStayDistinctAndDismissable() async {
        let prefix = String(repeating: "x", count: 70)
        let a = RemoteHostDismissTests.active(prefix + "a", pump: RemoteHostDismissTests.pumpAlert)
        let b = RemoteHostDismissTests.active(prefix + "b", pump: nil)
        let items = StatusComposer.alertItems([a, b])
        #expect(Set(items.map(\.id)).count == 2)
        #expect(items.allSatisfy { $0.id.count <= WireLimits.maxIdLength })
        let rig = HostRig()
        await rig.start()
        await rig.host.alertsChanged([a, b])
        await rig.receive(.dismiss(.init(requestId: "d1", alertId: StatusComposer.wireId(prefix + "a"))))
        #expect(rig.transport.dismissResults.map(\.result) == [.cleared])
    }

    @Test func aClockOutOfRangeStillMakesReadableMessages() {
        #expect(wireEpoch(Date(timeIntervalSince1970: 0)) == WireLimits.epochs.lowerBound)
        #expect(wireEpoch(.distantFuture) == WireLimits.epochs.upperBound)
    }
}
