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
    static let pumpAlert = PumpAlert(id: 2, kind: .alert, title: "Low insulin")
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

    @Test func aSettingsChangeSendsTheNewConfigOnce() async {
        let rig = HostRig()
        await rig.start()
        var settings = HostRig.settings()
        settings.preferences.clockAnalog = true
        await rig.host.settingsChanged(settings)
        await rig.host.settingsChanged(settings)
        await rig.settle()
        #expect(rig.transport.configs.count == 2)
        #expect(rig.transport.configs.last?.clockAnalog == true)
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
