import Foundation
import PumpScript
import TandemBLE
import TandemLink
import Testing

/// The scripted radio keeps TandemKit's delayed connect honest: a test that relies on it would otherwise see
/// a link come up at once, or never.
@MainActor
@Suite struct ScriptedTransportTests {
    private func radio() -> (ScriptedTransport, ScriptClock, () -> [LinkInput]) {
        let clock = ScriptClock()
        let transport = ScriptedTransport(pump: ScriptedPump(clock: clock))
        var reports: [LinkInput] = []
        transport.report = { reports.append($0) }
        return (transport, clock, { reports })
    }

    private func connected(_ reports: [LinkInput]) -> Bool {
        reports.contains { if case .connected = $0 { true } else { false } }
    }

    @Test func aDelayedConnectCompletesOnlyAfterItsDelay() {
        let (transport, clock, reports) = radio()
        transport.perform(.delayedConnect(ScriptedPump.peripheralID, startDelay: 3))
        clock.advance(by: 2.9)
        #expect(!connected(reports()))
        clock.advance(by: 0.2)
        #expect(connected(reports()))
    }

    @Test func aCancelledDelayedConnectNeverCompletes() {
        let (transport, clock, reports) = radio()
        transport.perform(.delayedConnect(ScriptedPump.peripheralID, startDelay: 3))
        transport.perform(.cancelPendingConnect(ScriptedPump.peripheralID))
        clock.advance(by: 10)
        #expect(!connected(reports()))
    }

    @Test func aPlainConnectReplacesTheDelay() {
        let (transport, _, reports) = radio()
        transport.perform(.delayedConnect(ScriptedPump.peripheralID, startDelay: 30))
        transport.perform(.connect(ScriptedPump.peripheralID))
        #expect(connected(reports()))
    }
}
