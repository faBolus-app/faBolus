import Foundation
import RemoteProtocol
import Testing

@testable import WatchLink

/// The driver: one input at a time, effects performed, one timer for the next deadline.
@MainActor
@Suite struct WatchLinkDriverTests {
    func make() -> (WatchLink, FakeTransport, ManualClock) {
        let transport = FakeTransport()
        let clock = ManualClock()
        let link = WatchLink(transport: transport, clock: clock, jitter: { 0 })
        link.start()
        return (link, transport, clock)
    }

    func connect(_ transport: FakeTransport) {
        transport.emit(.paired(true))
        transport.emit(.deviceStatus(.connected))
        transport.emit(.characteristicsDiscovered)
    }

    @Test func itSendsAndRetriesOnItsOwnTimer() {
        let (link, transport, clock) = make()
        link.submit(.setConfig(Fixture.config))
        connect(transport)
        #expect(transport.kinds == ["config"])
        // The completion never comes: the watchdog fires on the clock, then the wait for the stalled send,
        // then a resend.
        clock.advance(8)
        #expect(link.state.phase == .backingOff)
        clock.advance(2)
        #expect(transport.kinds == ["config"])
        clock.advance(WatchLinkConfiguration().stalledSendHold - 10)
        #expect(transport.kinds == ["config", "config"])
        transport.emit(.sendCompleted(send: transport.sent.last!.send, .delivered))
        #expect(link.state.phase == .reachable)
        #expect(clock.pending == 0)
    }

    /// A transport that completes inside `transmit` re-enters the link; the input waits its turn instead.
    @Test func aSynchronousCompletionIsQueuedNotReentered() {
        let (link, transport, _) = make()
        transport.completeImmediately = .delivered
        link.submit(.setConfig(Fixture.config))
        link.submit(.setStatus(Fixture.status()))
        link.submit(.sendResult(Fixture.outcome("r1", .delivered)))
        connect(transport)
        #expect(transport.kinds == ["bolusOutcome", "config", "status"])
        #expect(link.state.phase == .reachable)
        #expect(link.state.queued.isEmpty)
    }

    /// Suspended, nothing fires; the timers that came due fire on resume, and the link isn't stuck.
    @Test func suspensionAndResume() {
        let (link, transport, clock) = make()
        link.submit(.setStatus(Fixture.status()))
        connect(transport)
        clock.suspended = true
        clock.advance(600)
        #expect(transport.sent.count == 1)
        clock.resume()
        clock.advance(3)
        #expect(transport.sent.count == 2)
        transport.emit(.sendCompleted(send: transport.sent.last!.send, .delivered))
        #expect(link.state.phase == .reachable)
    }

    @Test func hostRequestsArriveInOrder() async {
        let (link, transport, _) = make()
        connect(transport)
        for name in ["bolus-units", "cancel"] {
            transport.emit(.received(GoldenFixtures.fixtures.first { $0.name == name }!.wire))
        }
        var iterator = link.hostRequests.makeAsyncIterator()
        guard case .bolus? = await iterator.next(), case .cancel? = await iterator.next() else {
            Issue.record("requests out of order")
            return
        }
    }

    /// With nothing to do, no timer is armed.
    @Test func anIdleLinkHasNoTimer() {
        let (link, transport, clock) = make()
        connect(transport)
        #expect(link.state.phase == .reachable)
        #expect(clock.pending == 0)
    }
}
