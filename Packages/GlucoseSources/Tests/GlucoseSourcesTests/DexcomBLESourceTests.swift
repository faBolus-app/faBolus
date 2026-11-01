import DexcomBLE
import DexcomG6
import DexcomG7
import Foundation
import Testing
import faBolusCore
import os

@testable import GlucoseSources

/// Records what the source asks of the radio.
final class RecordingTransport: DexcomTransport {
    private let log = OSAllocatedUnfairLock<[String]>(initialState: [])
    private let sent = OSAllocatedUnfairLock<[DexcomCommand]>(initialState: [])
    var calls: [String] { log.withLock { $0 } }
    var commands: [DexcomCommand] { sent.withLock { $0 } }
    func start() { log.withLock { $0.append("start") } }
    func stop() { log.withLock { $0.append("stop") } }
    func perform(_ commands: [DexcomCommand]) { sent.withLock { $0 += commands } }
}

/// A recorded session from the DexcomBLE package's fixtures.
func dexcomFixture(_ path: String) throws -> DexcomSessionLog {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("../../../DexcomBLE/\(path)").standardized
    return try DexcomSessionLog(parsing: String(contentsOf: url, encoding: .utf8))
}

@Suite("Direct-Bluetooth sources")
struct DexcomBLESourceTests {
    func g6Source(clock: TestClock, transport: RecordingTransport, memory: OSAllocatedUnfairLock<[DexcomMemory]>? = nil)
        -> DexcomBLESource<G6Observer>
    {
        DexcomBLESource(
            id: GlucoseSourceRegistry.g6ID, observer: G6Observer(), makeTransport: { _ in transport },
            remember: { m in memory?.withLock { $0.append(m) } }, clock: clock.function,
            sleep: RecordingSleep().function)
    }

    /// Replays a recorded session through a source, entry by entry, on the source's clock.
    func replay<Observer>(_ log: DexcomSessionLog, through source: DexcomBLESource<Observer>, clock: TestClock) async {
        var last: TimeInterval = log.entries.first?.offset ?? 0
        for entry in log.entries {
            clock.advance(entry.offset - last)
            last = entry.offset
            await source.handle(entry.event)
        }
    }

    @Test("G6 recorded session: one reading as a sample with Dexcom's arrow, remembered transmitter")
    func g6Replay() async throws {
        let clock = TestClock(t0)
        let transport = RecordingTransport()
        let memory = OSAllocatedUnfairLock<[DexcomMemory]>(initialState: [])
        let source = g6Source(clock: clock, transport: transport, memory: memory)
        await source.start()
        await replay(try dexcomFixture("G6/Tests/Fixtures/g6-session.log"), through: source, clock: clock)

        let state = await source.state
        #expect(state.latest?.mgdl == 130)
        #expect(state.latest?.date == t0.addingTimeInterval(213.6 - 304))
        #expect(state.latest?.trend == .falling)  // -1.0 mg/dL/min, Dexcom's 45° down
        #expect(state.latest?.sourceID == "dexcom-g6")
        #expect(transport.calls == ["start"])
        #expect(
            transport.commands.contains(.listen(UUID(uuidString: "5D3C2A10-7E4B-4C61-9F2A-8B1C0D3E4F50")!, .control)))
        let remembered = memory.withLock { $0.last }
        #expect(remembered?.peripheralID == UUID(uuidString: "5D3C2A10-7E4B-4C61-9F2A-8B1C0D3E4F50"))
        #expect(remembered?.activationDate == t0.addingTimeInterval(213.6 - 5_092_030))
    }

    @Test("the source records its session as a log that replays to the same events")
    func recordsItsSession() async throws {
        let clock = TestClock(t0)
        let source = g6Source(clock: clock, transport: RecordingTransport())
        await source.start()
        let fixture = try dexcomFixture("G6/Tests/Fixtures/g6-session.log")
        await replay(fixture, through: source, clock: clock)
        let recorded = try DexcomSessionLog(parsing: await source.sessionRecording())
        #expect(recorded.entries.map(\.event) == fixture.entries.map(\.event))
        let start = fixture.entries.first?.offset ?? 0
        #expect(recorded.entries.map(\.offset) == fixture.entries.map { $0.offset - start })
    }

    @Test("G6 backfill fills the history behind the latest reading")
    func g6Backfill() async throws {
        let clock = TestClock(t0)
        let source = DexcomBLESource(
            id: GlucoseSourceRegistry.g6ID, observer: G6Observer(transmitterID: "8G1234"),
            makeTransport: { _ in RecordingTransport() }, clock: clock.function, sleep: RecordingSleep().function)
        await source.start()
        await replay(try dexcomFixture("G6/Tests/Fixtures/g6-backfill.log"), through: source, clock: clock)
        let state = await source.state
        #expect(state.latest?.mgdl == 95)
        #expect(state.history.map(\.mgdl) == [92, 93, 94, 93, 95])
    }

    @Test("G7 recorded session: nine readings, a backfill, then the expired sensor said as the reason")
    func g7Replay() async throws {
        let clock = TestClock(t0)
        let memory = OSAllocatedUnfairLock<[DexcomMemory]>(initialState: [])
        let source = DexcomBLESource(
            id: GlucoseSourceRegistry.g7ID, observer: G7Observer(), makeTransport: { _ in RecordingTransport() },
            remember: { m in memory.withLock { $0.append(m) } }, clock: clock.function, sleep: RecordingSleep().function
        )
        await source.start()
        let log = try dexcomFixture("G7/Tests/Fixtures/g7-session.log")
        await replay(log, through: source, clock: clock)
        let state = await source.state
        #expect(state.latest?.mgdl == 95)
        #expect(state.history.count == 10)
        #expect(state.status == .unavailable(.sensorNotReady("expired")))
        #expect(memory.withLock { $0.last?.sensorName } == "DXCM15")
    }

    @Test("when G6 can't read, the status says why")
    func g6SaysWhy() async {
        let clock = TestClock(t0)
        let source = g6Source(clock: clock, transport: RecordingTransport())
        await source.start()
        #expect(await source.state.status == .searching)
        await source.handle(.bluetooth(.poweredOff))
        #expect(await source.state.status == .unavailable(.bluetoothOff))
        await source.handle(.bluetooth(.unauthorized))
        #expect(await source.state.status == .unavailable(.bluetoothNotAllowed))
        await source.handle(.bluetooth(.poweredOn))
        let tx = DexcomPeripheral(id: UUID(), name: "Dexcom4B")
        await source.handle(.found(known: nil, systemConnected: [tx]))
        for _ in 0..<2 {
            await source.handle(.connected(tx))
            await source.handle(.ready(tx))
            await source.handle(.disconnected(tx, .remote))
        }
        let status = await source.state.status
        #expect(status == .unavailable(.dexcomAppNotConnected))
        if case .unavailable(let problem) = status { #expect(problem.message.contains("Open the Dexcom app")) }
        clock.advance(12 * 60)
        await source.handle(.tick)
        #expect(await source.state.status == .unavailable(.dexcomAppNotConnected))
    }

    @Test("nothing found for 11 minutes: the status says no transmitter was found")
    func g6NotFound() async {
        let clock = TestClock(t0)
        let source = g6Source(clock: clock, transport: RecordingTransport())
        await source.start()
        await source.handle(.bluetooth(.poweredOn))
        await source.handle(.found(known: nil, systemConnected: []))
        clock.advance(11 * 60 + 1)
        #expect(await source.state.status == .unavailable(.sensorNotFound))
    }

    @Test("a LOW reading is reported apart, never as the latest reading")
    func lowReading() async {
        let clock = TestClock(t0)
        let source = g6Source(clock: clock, transport: RecordingTransport())
        await source.start()
        let tx = DexcomPeripheral(id: UUID(), name: "Dexcom4B")
        for event: DexcomEvent in [
            .bluetooth(.poweredOn), .found(known: nil, systemConnected: [tx]), .connected(tx), .ready(tx),
            .value(tx, .authentication, Data([0x05, 0x01, 0x01])),
            .value(tx, .control, hex("2500beb24d00f22d4d000100000083c0")),
            .value(tx, .control, hex("3100000000008eb14d00270006f6936e"))
        ] {
            await source.handle(event)
        }
        let state = await source.state
        #expect(state.latest == nil)
        #expect(state.belowRangeAt == t0.addingTimeInterval(-304))
    }

    @Test("stop stops the radio and drops later events; start again reuses the same central")
    func stopAndRestart() async {
        let clock = TestClock(t0)
        let transport = RecordingTransport()
        let builds = OSAllocatedUnfairLock(initialState: 0)
        let source = DexcomBLESource(
            id: GlucoseSourceRegistry.g6ID, observer: G6Observer(),
            makeTransport: { _ in
                builds.withLock { $0 += 1 }
                return transport
            }, clock: clock.function, sleep: RecordingSleep().function)
        await source.start()
        await source.stop()
        #expect(await source.state.status == .idle)
        await source.handle(.bluetooth(.poweredOn))
        #expect(!transport.commands.contains(.lookUp(known: nil, delay: 0)))
        await source.start()
        #expect(builds.withLock { $0 } == 1)
        #expect(transport.calls == ["start", "stop", "start"])
    }

    @Test("a G6 transmitter ID typed in settings wins over the pump's, and a mismatch lets the transmitter go")
    func transmitterIDFromPump() async {
        let clock = TestClock(t0)
        let transport = RecordingTransport()
        let source = g6Source(clock: clock, transport: transport)
        await source.start()
        let tx = DexcomPeripheral(id: UUID(), name: "Dexcom4B")
        await source.handle(.bluetooth(.poweredOn))
        await source.handle(.found(known: nil, systemConnected: [tx]))
        await source.handle(.connected(tx))
        await source.setTransmitterID(entered: nil, fromPump: "8G124B\u{0}")
        #expect(!transport.commands.contains(.cancel(tx.id)))
        await source.setTransmitterID(entered: "8G12CD", fromPump: "8G124B")
        #expect(transport.commands.contains(.cancel(tx.id)))
    }
}
