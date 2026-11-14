import Foundation
import RemoteProtocol
import Testing

@testable import WatchLink

@Suite struct ConnectingTests {
    @Test func phasesFollowTheFacts() {
        var h = Harness()
        #expect(h.state.phase == .notPaired)
        h.send(.paired(true))
        #expect(h.state.phase == .unreachable)
        h.send(.deviceStatus(.connected))
        // Connected isn't ready (Connect IQ: wait for the characteristics); it probes instead.
        #expect(h.state.phase == .unreachable)
        #expect(h.probes == 1)
        h.send(.characteristicsDiscovered)
        #expect(h.state.phase == .reachable)
    }

    /// The config goes in full whenever the watch connects, then a status naming its revision.
    @Test func aConnectingWatchGetsTheConfigThenAStatus() {
        var h = Harness()
        h.send(.setConfig(Fixture.config))
        h.send(.setStatus(Fixture.status()))
        h.send(.paired(true))
        h.send(.deviceStatus(.connected))
        #expect(h.transmitted.isEmpty)
        h.send(.characteristicsDiscovered)
        h.deliverAll()
        #expect(h.transmittedKinds == ["config", "status"])
        #expect(h.state.phase == .reachable)

        // Every reconnect sends both again.
        h.effects = []
        h.send(.deviceStatus(.notConnected))
        h.send(.deviceStatus(.connected))
        h.send(.characteristicsDiscovered)
        h.deliverAll()
        #expect(h.transmittedKinds == ["config", "status"])
    }

    /// A probe that finds the app installed shows the watch can take messages, as when the device was
    /// already connected before the registration and discovery never re-fires.
    @Test func aSuccessfulProbeArmsTheLink() {
        var h = Harness()
        h.send(.setStatus(Fixture.status()))
        h.send(.paired(true))
        h.send(.deviceStatus(.connected))
        guard case .probeAppStatus(let probe)? = h.effects.last else {
            Issue.record("no probe")
            return
        }
        h.send(.appStatus(installed: true, probe: probe))
        #expect(h.state.phase == .awaitingReply)
        #expect(h.transmittedKinds == ["status"])
    }

    /// An answer to an earlier probe, after a newer one went out, changes nothing.
    @Test func aStaleProbeAnswerIsIgnored() {
        var h = Harness()
        h.send(.paired(true))
        h.send(.deviceStatus(.connected))
        h.advance(25)
        #expect(h.state.probe == 2)
        h.send(.appStatus(installed: false, probe: 1))
        #expect(h.state.appInstalled == nil)
        h.send(.appStatus(installed: true, probe: 2))
        #expect(h.state.phase == .reachable)
    }

    /// An unanswered probe is retried at a bounded rate, never in a tight loop.
    @Test func probesWhileUnreadyAreBounded() {
        var h = Harness()
        h.send(.paired(true))
        h.send(.deviceStatus(.connected))
        h.advance(3600)
        // 20 s, then every 60 s: about 60 in an hour, never hundreds.
        #expect(h.probes > 30 && h.probes < 70)
        #expect(h.state.phase == .unreachable)
    }

    /// Probe answers for a watch that has since disconnected don't arm the next connection.
    @Test func aProbeAnswerAfterADisconnectIsIgnored() {
        var h = Harness()
        h.send(.paired(true))
        h.send(.deviceStatus(.connected))
        h.send(.deviceStatus(.notConnected))
        h.send(.appStatus(installed: true, probe: 1))
        h.send(.deviceStatus(.connected))
        #expect(h.state.phase == .unreachable)
    }

    @Test func unpairingForgetsEverything() {
        var h = Harness.ready()
        h.send(.setStatus(Fixture.status()))
        h.send(.sendResult(Fixture.outcome("r1", .delivered)))
        h.send(.paired(false))
        #expect(h.state.phase == .notPaired)
        #expect(h.state.queued.isEmpty)
        #expect(h.state.inFlight == nil)
    }

    /// A relaunched phone starts from nothing: the watch's next poll tells it what the watch is missing.
    @Test func aRelaunchStartsFromAFreshState() {
        var h = Harness()
        h.send(.paired(true))
        h.send(.deviceStatus(.connected))
        h.send(.received(Fixture.poll(revision: Fixture.config.revision, awaiting: "r7")))
        #expect(h.state.phase == .reachable)
        #expect(h.hostRequests == [.outcome(requestId: "r7")])
        // The host sets what it has; the watch gets it.
        h.send(.setConfig(Fixture.config))
        h.send(.setStatus(Fixture.status()))
        h.deliverAll()
        #expect(h.transmittedKinds == ["config", "status"])
    }
}

@Suite struct ConfigResyncTests {
    /// The watch missed a config change: its poll names the old revision, so the config goes again.
    @Test func aPollWithAnotherRevisionGetsTheConfig() {
        var h = Harness.ready()
        h.send(.received(Fixture.poll(revision: "0123456789abcdef")))
        h.deliverAll()
        #expect(h.transmittedKinds == ["config", "status"])
    }

    /// A watch whose storage was wiped holds no revision.
    @Test func aPollWithNoRevisionGetsTheConfig() {
        var h = Harness.ready()
        h.send(.received(Fixture.poll(revision: nil)))
        h.deliverAll()
        #expect(h.transmittedKinds == ["config", "status"])
    }

    @Test func aPollWithTheSameRevisionGetsOnlyAStatus() {
        var h = Harness.ready()
        h.send(.received(Fixture.poll(revision: Fixture.config.revision)))
        h.deliverAll()
        #expect(h.transmittedKinds == ["status"])
    }

    @Test func aChangedConfigIsSentOnce() {
        var h = Harness.ready()
        var config = Fixture.config
        config.complicationLabels = true
        h.send(.setConfig(config))
        h.send(.setConfig(config))
        h.deliverAll()
        #expect(h.transmittedKinds == ["config"])
    }

    /// The config is dropped after its attempts; the next status names the new revision, the watch polls
    /// with its old one, and the config goes again.
    @Test func aLostConfigIsRecoveredByThePoll() {
        var h = Harness.ready()
        var config = Fixture.config
        config.complicationLabels = true
        h.send(.setConfig(config))
        for _ in 0..<3 {
            guard let send = h.inFlight else { break }
            h.send(.sendCompleted(send: send, .transientFailure("timeout")))
            h.advance(60)
        }
        #expect(h.state.queued.isEmpty)
        #expect(h.state.telemetry.dropped == 1)
        h.effects = []
        h.send(.received(Fixture.poll(revision: Fixture.config.revision)))
        // The last try stalled; the next send waits for it.
        for _ in 0..<Int(h.configuration.stalledSendHold) where h.inFlight == nil { h.advance(1) }
        h.deliverAll()
        #expect(h.transmittedKinds == ["config", "status"])
    }

    @Test func historyIsSentOnlyWhenAsked() {
        var h = Harness.ready()
        h.send(.received(Fixture.poll(revision: Fixture.config.revision, history: true)))
        #expect(h.hostRequests.contains(.history))
        h.send(.setHistory(GoldenFixtures.history))
        h.deliverAll()
        #expect(h.transmittedKinds == ["status", "history"])
    }
}

@Suite struct OutboxTests {
    /// A bolus outcome never waits behind a status, and a status pushed on a change is the same message as
    /// a poll's reply: the newest one goes, once.
    @Test func resultsGoFirstAndStatusesCoalesce() {
        var h = Harness.ready()
        h.send(.setStatus(Fixture.status(GoldenFixtures.now + 1)))
        let first = h.inFlight
        h.send(.setStatus(Fixture.status(GoldenFixtures.now + 2)))
        h.send(.received(Fixture.poll(revision: Fixture.config.revision)))
        h.send(.sendResult(Fixture.outcome("r1", .delivering)))
        h.send(.setStatus(Fixture.status(GoldenFixtures.now + 3)))
        if let first { h.send(.sendCompleted(send: first, .delivered)) }
        h.deliverAll()
        #expect(h.transmittedKinds == ["status", "bolusOutcome", "status"])
        guard case .object(let o) = h.transmitted.last!, case .object(let p)? = o["payload"] else { return }
        #expect(p["sentAt"] == .int(GoldenFixtures.now + 3))
    }

    /// A newer outcome for the same request replaces one not yet sent; outcomes for different requests keep
    /// their order.
    @Test func resultsArePerRequestAndInOrder() {
        var h = Harness.ready()
        h.send(.setStatus(Fixture.status()))
        h.send(.sendResult(Fixture.outcome("a", .received)))
        h.send(.sendResult(Fixture.outcome("b", .received)))
        h.send(.sendResult(Fixture.outcome("a", .delivering)))
        h.send(.sendResult(Fixture.outcome("a", .delivered)))
        h.deliverAll()
        let outcomes: [String] = h.transmitted.compactMap {
            guard case .bolusOutcome(let p)? = Self.message($0) else { return nil }
            return "\(p.requestId):\(p.outcome.rawValue)"
        }
        #expect(outcomes == ["a:delivered", "b:received"])
    }

    /// A status set while one is in flight is still due once that send completes.
    @Test func aStatusChangedInFlightIsSentAfterwards() {
        var h = Harness.ready()
        h.send(.setStatus(Fixture.status(GoldenFixtures.now + 1)))
        let send = h.inFlight
        h.send(.setStatus(Fixture.status(GoldenFixtures.now + 2)))
        if let send { h.send(.sendCompleted(send: send, .delivered)) }
        #expect(h.inFlight != nil)
        h.deliverAll()
        #expect(h.transmittedKinds == ["status", "status"])
    }

    @Test func theResultQueueIsBounded() {
        var h = Harness.ready()
        h.send(.deviceStatus(.notConnected))
        for i in 0..<40 { h.send(.sendResult(Fixture.outcome("r\(i)", .failed))) }
        #expect(h.state.queued.count <= h.configuration.maxQueuedResults)
        #expect(h.state.telemetry.dropped == 40 - h.configuration.maxQueuedResults)
    }

    static func message(_ wire: WireValue) -> RemoteMessage? {
        if case .message(let m) = RemoteMessage.receive(wire) { return m }
        return nil
    }
}

@Suite struct InboundTests {
    @Test func requestsGoToTheHost() {
        var h = Harness.ready()
        for name in ["bolus-units", "cancel", "dismiss"] {
            h.send(.received(GoldenFixtures.fixtures.first { $0.name == name }!.wire))
        }
        #expect(h.hostRequests.count == 3)
        guard case .bolus? = h.hostRequests.first else {
            Issue.record("no bolus request")
            return
        }
    }

    /// A message from the watch shows it's connected and has the app, whatever the SDK last said.
    @Test func anInboundMessageArmsTheLink() {
        var h = Harness()
        h.send(.setStatus(Fixture.status()))
        h.send(.paired(true))
        h.send(.deviceStatus(.notConnected))
        h.send(.received(Fixture.poll(revision: nil)))
        #expect(h.state.isReady)
        #expect(h.transmittedKinds == ["status"])
    }

    /// The old watch app gets exactly one reply per message, in the form it shows.
    @Test func aVersionOneMessageGetsOneReply() {
        var h = Harness.ready()
        let v1 = GoldenFixtures.fixtures.first { $0.name == "v1-statusRead-from-watch" }!.wire
        h.send(.received(v1))
        h.send(.received(v1))
        h.deliverAll()
        #expect(h.transmittedKinds == ["statusRead", "statusRead"])
        #expect(h.hostRequests.isEmpty)
        #expect(h.state.telemetry.receivedLegacy == 2)
        let reply = GoldenFixtures.fixtures.first { $0.name == "v1-reply-to-statusRead" }!.wire
        #expect(h.transmitted.allSatisfy { $0 == reply })
    }

    /// A status goes out stamped with the time it's sent, not the time it was built: resent an hour later
    /// unchanged, its values must still read an hour older on the watch, which ages them from `sentAt`.
    @Test func aResentStatusIsStampedWhenItGoes() {
        var h = Harness.ready()
        let built = Fixture.status()
        h.send(.setStatus(built))
        h.deliverAll()
        h.epoch = built.sentAt + 3600
        h.send(.received(Fixture.poll(revision: nil)))
        h.deliverAll()
        guard case .message(.status(let resent))? = h.transmitted.last.map(RemoteMessage.receive) else {
            Issue.record("no status resent")
            return
        }
        #expect(resent.sentAt == built.sentAt + 3600)
        #expect(resent.glucose == built.glucose)
    }

    /// A cancel is never gated: the old watch app's is acted on, as well as answered. Nothing else from it is.
    @Test func aVersionOneCancelIsActedOn() {
        var h = Harness.ready()
        let cancel = WireValue.object([
            "version": .int(1), "kind": .string("cancelBolus"), "requestId": .string("old-1")
        ])
        h.send(.received(cancel))
        #expect(h.hostRequests == [.cancel(CancelPayload(requestId: "old-1", bolusRequestId: nil))])
        h.deliverAll()
        #expect(h.transmittedKinds == ["statusRead"])
    }

    @Test func versionOneRepliesAreBounded() {
        var h = Harness.ready()
        h.send(.deviceStatus(.notConnected))
        let v1 = GoldenFixtures.fixtures.first { $0.name == "v1-bolusRequest-from-watch" }!.wire
        for _ in 0..<20 {
            h.send(.received(v1))
            h.send(.deviceStatus(.notConnected))
        }
        let replies = h.state.queued.filter { if case .legacyReply = $0 { return true } else { return false } }
        #expect(replies.count <= h.configuration.maxQueuedLegacyReplies)
        #expect(h.state.telemetry.receivedLegacy == 20)
    }

    @Test func aNewerVersionGetsOneIncompatibleReply() {
        var h = Harness.ready()
        let v3 = WireValue.object(["version": .int(3), "kind": .string("hello")])
        h.send(.received(v3))
        h.send(.received(v3))
        h.deliverAll()
        #expect(h.transmittedKinds.filter { $0 == "incompatible" }.count <= 2)
        #expect(h.transmittedKinds.contains("incompatible"))
        #expect(h.hostRequests.isEmpty)
    }

    /// A bolus request that can't be read is answered, not left to time out on the watch.
    @Test func anUnreadableBolusIsAnsweredAsFailed() {
        var h = Harness.ready()
        h.send(
            .received(
                .object([
                    "version": .int(2), "kind": .string("bolus"),
                    "payload": .object(["requestId": .string("r1"), "mode": .string("units"), "mU": .double(2.5)])
                ])))
        #expect(h.hostRequests == [.unreadableBolus(requestId: "r1")])
        #expect(h.state.telemetry.receivedMalformed == 1)
    }

    /// The watch never sends phone messages; one that claims to is dropped.
    @Test func aPhoneKindFromTheWatchIsDropped() {
        var h = Harness.ready()
        h.send(.received(RemoteMessage.status(Fixture.status()).wire))
        #expect(h.hostRequests.isEmpty)
        #expect(h.transmitted.isEmpty)
        #expect(h.state.telemetry.receivedUnexpected == 1)
    }
}

/// The review's findings, each pinned.
@Suite struct ReducerReviewTests {
    /// Outcomes reach the link from more than one task; an older one queued after a newer one doesn't
    /// replace it.
    @Test func aQueuedOutcomeOnlyMovesForward() {
        var h = Harness.ready()
        h.send(.deviceStatus(.notConnected))
        h.send(.sendResult(Fixture.outcome("r1", .delivered)))
        h.send(.sendResult(Fixture.outcome("r1", .delivering)))
        h.send(.sendResult(Fixture.outcome("r1", .received)))
        h.send(.deviceStatus(.connected))
        h.send(.characteristicsDiscovered)
        h.deliverAll()
        let outcomes: [OutcomeToken] = h.transmitted.compactMap {
            guard case .bolusOutcome(let p)? = OutboxTests.message($0) else { return nil }
            return p.outcome
        }
        #expect(outcomes == [.delivered])
    }

    /// A dismiss result and a bolus outcome that share a request ID are both sent.
    @Test func outcomesAndDismissResultsHaveTheirOwnSlots() {
        var h = Harness.ready()
        h.send(.deviceStatus(.notConnected))
        h.send(.sendResult(Fixture.outcome("same", .delivered)))
        h.send(
            .sendResult(.dismissResult(DismissResultPayload(requestId: "same", alertId: "a", result: .cleared))))
        h.send(.deviceStatus(.connected))
        h.send(.characteristicsDiscovered)
        h.deliverAll()
        #expect(h.transmittedKinds.filter { $0 == "bolusOutcome" || $0 == "dismissResult" }.count == 2)
    }

    /// Over the cap, dismiss results go first, so a burst of them can't push out a bolus outcome.
    @Test func dismissResultsAreEvictedBeforeOutcomes() {
        var h = Harness.ready()
        h.send(.deviceStatus(.notConnected))
        h.send(.sendResult(Fixture.outcome("bolus", .unknown)))
        for i in 0..<40 {
            h.send(
                .sendResult(.dismissResult(DismissResultPayload(requestId: "d\(i)", alertId: "a", result: .cleared))))
        }
        #expect(h.state.queued.contains(.outcome(requestId: "bolus")))
    }

    /// A watch running the old app gets only the replies to its messages, not version 2 pushes, until it
    /// sends a version 2 message.
    @Test func aVersionOneWatchGetsNoVersionTwoPushes() {
        var h = Harness.ready()
        h.send(.received(GoldenFixtures.fixtures.first { $0.name == "v1-statusRead-from-watch" }!.wire))
        h.deliverAll()
        h.send(.setStatus(Fixture.status(GoldenFixtures.now + 9)))
        h.send(
            .setConfig(
                {
                    var c = Fixture.config
                    c.complicationLabels = true
                    return c
                }()))
        h.deliverAll()
        #expect(h.transmittedKinds == ["statusRead"])
        h.send(.received(Fixture.poll(revision: nil)))
        h.deliverAll()
        #expect(h.transmittedKinds == ["statusRead", "config", "status"])
    }
}
