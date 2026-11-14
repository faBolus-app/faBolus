import Foundation
import RemoteProtocol
import Testing

@testable import WatchLink

/// Lost, slow, duplicated and reordered sends and every Connect IQ send error: the link recovers, never
/// retries without end, and never stays stuck.
@Suite struct FaultInjectionTests {
    /// Connect IQ's failure results that aren't permanent, as `GarminTransport` reports them.
    static let transient = [
        "Failure_Unknown", "Failure_InternalError", "Failure_DeviceNotAvailable", "Failure_DeviceIsBusy",
        "Failure_Timeout", "Failure_MaxRetries", "Failure_PromptNotDisplayed", "Failure_AppAlreadyRunning"
    ]

    @Test(arguments: transient)
    func aTransientFailureRetriesWithBackoffThenDrops(_ reason: String) {
        var h = Harness.ready()
        h.send(.sendResult(Fixture.outcome("r1", .delivered)))
        var tries = 0
        while let send = h.inFlight {
            tries += 1
            h.send(.sendCompleted(send: send, .transientFailure(reason)))
            #expect(h.state.phase == .backingOff)
            #expect(h.inFlight == nil)
            h.advance((h.state.backoffUntil ?? h.now) - h.now)
            #expect(tries <= 3)
        }
        #expect(tries == 3)
        #expect(h.state.queued.isEmpty)
        #expect(h.state.phase == .reachable)
        #expect(h.state.telemetry.dropped == 1)
    }

    @Test func backoffGrowsAndResetsOnSuccess() {
        var h = Harness.ready()
        h.send(.setStatus(Fixture.status()))
        var waits: [LinkSeconds] = []
        for _ in 0..<2 {
            guard let send = h.inFlight else { break }
            h.send(.sendCompleted(send: send, .transientFailure("busy")))
            waits.append((h.state.backoffUntil ?? h.now) - h.now)
            h.advance(waits.last ?? 0)
        }
        #expect(waits == [2, 4])
        h.deliverAll()
        h.send(.setStatus(Fixture.status()))
        if let send = h.inFlight { h.send(.sendCompleted(send: send, .transientFailure("busy"))) }
        #expect((h.state.backoffUntil ?? h.now) - h.now == 2)
    }

    /// The app isn't on the watch: nothing more is sent, and nothing probes until the watch reconnects or
    /// the phone app comes back to the foreground.
    @Test func appNotFoundStopsSendingUntilTheAppIsBack() {
        var h = Harness.ready()
        h.send(.setStatus(Fixture.status()))
        guard let send = h.inFlight else {
            Issue.record("nothing sent")
            return
        }
        h.send(.sendCompleted(send: send, .appNotFound))
        #expect(h.state.phase == .appNotInstalled)
        h.effects = []
        h.send(.setStatus(Fixture.status()))
        h.advance(3600)
        #expect(h.transmitted.isEmpty)
        #expect(h.probes == 0)

        h.send(.appActive(true))
        #expect(h.probes == 1)
        h.send(.appStatus(installed: true, probe: h.state.probe))
        #expect(h.state.phase == .awaitingReply)
        h.deliverAll()
        #expect(h.transmittedKinds == ["config", "status"])
    }

    @Test func aProbeSayingNotInstalledWaitsForTheUser() {
        var h = Harness()
        h.send(.paired(true))
        h.send(.deviceStatus(.connected))
        h.send(.appStatus(installed: false, probe: h.state.probe))
        #expect(h.state.phase == .appNotInstalled)
        h.effects = []
        h.advance(3600)
        #expect(h.probes == 0)
        h.send(.deviceStatus(.notConnected))
        h.send(.deviceStatus(.connected))
        #expect(h.probes == 1)
    }

    /// A message the watch can never take is dropped at once, and the next goes without waiting.
    @Test(arguments: ["unsupported type", "insufficient memory"])
    func anUndeliverableMessageIsDroppedAtOnce(_ reason: String) {
        var h = Harness.ready()
        h.send(.setHistory(GoldenFixtures.history))
        h.send(.setStatus(Fixture.status()))
        guard let send = h.inFlight else { return }
        h.send(.sendCompleted(send: send, .undeliverable(reason)))
        #expect(h.state.backoffUntil == nil)
        #expect(h.inFlight != nil)
        h.deliverAll()
        #expect(h.state.queued.isEmpty)
        #expect(h.state.telemetry.undeliverable == 1)
    }

    /// No completion at all: the watchdog gives up after the no-progress window and the message is
    /// retried after a backoff.
    /// A send with no completion is a stall. The SDK may still hold it, so the next send waits for its
    /// completion, up to `stalledSendHold`, rather than queue behind it: sending on top of a transfer
    /// still in the SDK is what turned slow sends into a pile of them.
    @Test func aLostCompletionIsAStall() {
        var h = Harness.ready()
        h.send(.setStatus(Fixture.status()))
        #expect(h.state.phase == .awaitingReply)
        h.advance(8)
        #expect(h.state.telemetry.stalls == 1)
        #expect(h.state.phase == .backingOff)
        h.advance(2)
        #expect(h.inFlight == nil)
        // Until the stalled send is `stalledSendHold` old.
        h.advance(h.configuration.stalledSendHold - 10 - 0.5)
        #expect(h.inFlight == nil)
        h.advance(1)
        #expect(h.state.phase == .awaitingReply)
    }

    /// Progress keeps a slow transfer alive, but only up to the hard ceiling.
    @Test func progressExtendsTheWatchdogUpToTheCeiling() {
        var h = Harness.ready()
        h.send(.setHistory(GoldenFixtures.history))
        let send = h.inFlight ?? -1
        for _ in 0..<7 {
            h.advance(7)
            h.send(.sendProgress(send: send))
        }
        #expect(h.state.telemetry.stalls == 0)
        h.advance(7)
        h.send(.sendProgress(send: send))
        h.advance(7)
        #expect(h.state.telemetry.stalls == 1)
        // Cut off while still moving, it's still with the SDK: the next send waits for it.
        #expect(h.inFlight == nil)
        // The last progress was 7 s before the stall.
        #expect(h.state.stalledHoldUntil == h.now - 7 + h.configuration.stalledSendHold)
    }

    /// A completion that arrives after the watchdog gave up is counted, breaks the run of stalls and ends
    /// the wait for it. One that says delivered settles the message, so it isn't sent again.
    @Test func aLateCompletionIsCountedAndSettlesTheMessage() {
        var h = Harness.ready()
        h.send(.setStatus(Fixture.status()))
        let first = h.inFlight ?? -1
        h.advance(8)
        h.advance(2)
        h.send(.sendCompleted(send: first, .delivered))
        #expect(h.state.telemetry.lateCompletions == 1)
        #expect(h.state.telemetry.lateDeliveries == 1)
        #expect(h.state.stallStreak == 0)
        #expect(h.inFlight == nil)
        #expect(h.state.queued.isEmpty)
        #expect(h.state.phase == .reachable)
        h.advance(120)
        #expect(h.transmittedKinds == ["status"])
    }

    /// A late failure ends the wait too, and the message goes again.
    @Test func aLateFailureEndsTheWaitAndTheMessageGoesAgain() {
        var h = Harness.ready()
        h.send(.setStatus(Fixture.status()))
        let first = h.inFlight ?? -1
        h.advance(10)
        h.send(.sendCompleted(send: first, .transientFailure("timeout")))
        #expect(h.state.telemetry.lateDeliveries == 0)
        h.advance(1)
        #expect(h.transmittedKinds == ["status", "status"])
    }

    /// A late delivery of content since replaced settles nothing: the newer content still goes.
    @Test func aLateDeliveryOfOlderContentLeavesTheNewer() {
        var h = Harness.ready()
        h.send(.setStatus(Fixture.status()))
        let first = h.inFlight ?? -1
        h.advance(8)
        h.send(.setStatus(Fixture.status(GoldenFixtures.now + 60)))
        h.send(.sendCompleted(send: first, .delivered))
        h.advance(3)
        #expect(h.transmittedKinds == ["status", "status"])
    }

    /// A send stalled on a connection that has since dropped doesn't hold up the next one: the reconnected
    /// watch gets the config and status at once.
    @Test func aReconnectDoesntWaitForASendStalledBeforeIt() {
        var h = Harness.ready()
        h.send(.setStatus(Fixture.status()))
        h.advance(8)
        #expect(h.state.stalledHoldUntil != nil)
        h.send(.deviceStatus(.notConnected))
        h.advance(1)
        h.send(.deviceStatus(.connected))
        h.send(.characteristicsDiscovered)
        #expect(h.state.stalledHoldUntil == nil)
        h.deliverAll()
        #expect(h.transmittedKinds == ["status", "config", "status"])
    }

    /// Stalled sends the SDK never answers don't pile up: at most one goes per `stalledSendHold`, and the
    /// ones kept for a late answer are capped.
    @Test func unansweredSendsGoAtMostOncePerHold() {
        var h = Harness.ready()
        // So the hold, not a rebuilt registration waiting on its probe, is what spaces the sends.
        h.configuration.stallsBeforeReregister = .max
        let before = h.state.telemetry.transmits
        for i in 0..<20 {
            h.send(.setStatus(Fixture.status(GoldenFixtures.now + i)))
            h.advance(30)
        }
        let span = 20 * 30.0
        #expect(Double(h.state.telemetry.transmits - before) <= span / h.configuration.stalledSendHold + 1)
        #expect(h.state.stalled.count <= h.configuration.maxStalledKept)
    }

    /// Three stalls in a row rebuild the registration, at most once per interval, and the rebuilt one has
    /// to show it's ready before anything more goes.
    @Test func repeatedStallsReregisterAtABoundedRate() {
        var h = Harness.ready()
        h.send(.setStatus(Fixture.status()))
        var reregisters = 0
        for _ in 0..<40 {
            h.advance(10)
            reregisters = h.effects.filter { $0 == .reregister }.count
            if !h.state.shownReady,
                let probe = h.effects.last(where: {
                    if case .probeAppStatus = $0 { return true } else { return false }
                }), case .probeAppStatus(let p) = probe
            {
                h.send(.appStatus(installed: true, probe: p))
            }
            h.send(.setStatus(Fixture.status()))
        }
        // 400 s of silence: at most one rebuild per 30 s, and far fewer in practice.
        #expect(reregisters >= 1)
        #expect(reregisters <= 400 / 30)
        #expect(h.state.telemetry.reregistrations == reregisters)
    }

    /// The app was suspended mid-send; on resume the completion and the overdue watchdog arrive together.
    /// The completion wins: the message was delivered.
    @Test func aCompletionAfterSuspensionIsNotAStall() {
        var h = Harness.ready()
        h.send(.setStatus(Fixture.status()))
        let send = h.inFlight ?? -1
        h.now += 600
        h.send(.sendCompleted(send: send, .delivered))
        #expect(h.state.telemetry.stalls == 0)
        #expect(h.state.telemetry.delivered >= 1)
        #expect(h.state.phase == .reachable)
    }

    /// Any other input after a suspension catches up on the overdue watchdog first.
    @Test func otherInputsCatchUpAfterSuspension() {
        var h = Harness.ready()
        h.send(.setStatus(Fixture.status()))
        h.now += 600
        h.send(.received(Fixture.poll(revision: Fixture.config.revision)))
        #expect(h.state.telemetry.stalls == 1)
        #expect(h.state.phase == .backingOff)
    }

    /// A flapping watch: each reconnect sends the config and a status once, probing stays bounded, and the
    /// link ends ready.
    @Test func flappingRecovers() {
        var h = Harness.ready()
        for _ in 0..<50 {
            h.send(.deviceStatus(.notConnected))
            h.advance(1)
            h.send(.deviceStatus(.connected))
            h.send(.characteristicsDiscovered)
            h.deliverAll()
            h.advance(1)
        }
        #expect(h.state.phase == .reachable)
        #expect(h.transmittedKinds.filter { $0 == "config" }.count == 50)
        #expect(h.probes <= 50)
    }

    /// The device events arrive out of order: "not connected" lands after the discovery that followed it.
    /// The next message from the watch arms the link again.
    @Test func reorderedDeviceEventsDontStrandTheLink() {
        var h = Harness.ready()
        h.send(.characteristicsDiscovered)
        h.send(.deviceStatus(.notConnected))
        #expect(h.state.phase == .unreachable)
        h.send(.received(Fixture.poll(revision: Fixture.config.revision)))
        #expect(h.state.isReady)
    }

    @Test func bluetoothOffAndOnRecovers() {
        var h = Harness.ready()
        h.send(.deviceStatus(.bluetoothOff))
        h.send(.setStatus(Fixture.status()))
        h.advance(600)
        #expect(h.transmitted.isEmpty)
        h.send(.deviceStatus(.connected))
        h.send(.characteristicsDiscovered)
        h.deliverAll()
        #expect(h.transmittedKinds == ["config", "status"])
    }

    /// Duplicated polls and duplicated results: each status and result goes at most once per change.
    @Test func duplicatesDontMultiplySends() {
        var h = Harness.ready()
        let poll = Fixture.poll(revision: Fixture.config.revision, awaiting: "r1")
        for _ in 0..<10 { h.send(.received(poll)) }
        for _ in 0..<10 { h.send(.sendResult(Fixture.outcome("r1", .delivered))) }
        h.deliverAll()
        #expect(h.transmittedKinds.filter { $0 == "bolusOutcome" }.count <= 2)
        #expect(h.transmittedKinds.filter { $0 == "status" }.count <= 2)
    }

    /// Random faults for a long time, then a well-behaved watch: every queue drains, nothing is left in
    /// flight, and no step left a deadline already due.
    @Test(arguments: 0..<40)
    func randomFaultsEndRecovered(_ seed: Int) {
        var rng = SeededRandom(seed: UInt64(seed + 1))
        var h = Harness()
        h.send(.setConfig(Fixture.config))
        h.send(.paired(true))
        let results: [WatchSendResult] = [
            .delivered, .delivered, .transientFailure("busy"), .appNotFound, .undeliverable("memory")
        ]
        for step in 0..<300 {
            switch rng.next() % 12 {
            case 0: h.send(.deviceStatus([.connected, .notConnected, .bluetoothOff].randomElement(using: &rng)!))
            case 1: h.send(.characteristicsDiscovered)
            case 2: h.send(.setStatus(Fixture.status(GoldenFixtures.now + step)))
            case 3: h.send(.sendResult(Fixture.outcome("r\(rng.next() % 5)", .delivered)))
            case 4: h.send(.received(Fixture.poll(revision: rng.next() % 2 == 0 ? nil : Fixture.config.revision)))
            case 5: if let s = h.inFlight { h.send(.sendCompleted(send: s, results.randomElement(using: &rng)!)) }
            case 6: if let s = h.inFlight { h.send(.sendProgress(send: s)) }
            case 7: h.send(.sendCompleted(send: Int(rng.next() % 50), .delivered))
            case 8: h.send(.appStatus(installed: [true, false, nil].randomElement(using: &rng)!, probe: h.state.probe))
            case 9: h.send(.appActive(rng.next() % 2 == 0))
            case 10: h.advance(Double(rng.next() % 90))
            default: h.now += Double(rng.next() % 900)  // suspended: no ticks
            }
        }
        // Now the watch and the SDK behave: every send completes, probes are answered, and the watch polls
        // every 15 s while its app is open.
        h.send(.appActive(true))
        h.send(.deviceStatus(.connected))
        for round in 0..<200 {
            if round % 15 == 0 { h.send(.received(Fixture.poll(revision: Fixture.config.revision))) }
            if h.state.probeOutstanding { h.send(.appStatus(installed: true, probe: h.state.probe)) }
            if let s = h.inFlight {
                h.send(.sendCompleted(send: s, .delivered))
            } else if !h.state.queued.isEmpty {
                h.advance(1)
            } else {
                break
            }
        }
        #expect(h.state.queued.isEmpty, "seed \(seed)")
        #expect(h.state.inFlight == nil, "seed \(seed)")
        #expect(h.state.phase == .reachable, "seed \(seed)")
    }
}

/// SplitMix64, so the random scenarios are the same on every run.
struct SeededRandom: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
