import DexcomBLE
import Foundation
import Testing

@testable import DexcomG6

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

@Suite("G6 replay of recorded sessions")
struct G6ReplayTests {
    @Test("a scanned transmitter: one reading dated by the transmitter's clock, then a reconnect")
    func liveSession() throws {
        var observer = G6Observer()
        let replay = try fixture("g6-session").replay(into: &observer, from: t0)
        let tx = try #require(UUID(uuidString: "5D3C2A10-7E4B-4C61-9F2A-8B1C0D3E4F50"))

        #expect(
            replay.commands == [
                .lookUp(known: nil, delay: 0), .scan, .stopScan, .connect(tx, delay: 0), .listen(tx, .authentication),
                .listen(tx, .control), .listen(tx, .backfill), .connect(tx, delay: 2), .listen(tx, .authentication),
                .listen(tx, .control), .connect(tx, delay: 2)
            ])
        // Measured 304 s before the clock reply that arrived at 213.6 s.
        #expect(
            replay.readings == [
                DexcomReading(
                    glucose: 130, measuredAt: t0.addingTimeInterval(213.6 - 304), trendRate: -1.0, isBackfill: false)
            ])
        #expect(observer.peripheralID == tx)
        #expect(replay.statuses.last == .reading)
    }

    @Test("a known ID, the transmitter already connected by the Dexcom app, and its backfill")
    func backfillSession() throws {
        var observer = G6Observer(transmitterID: "8g1234")
        let replay = try fixture("g6-backfill").replay(into: &observer, from: t0)
        let tx = try #require(UUID(uuidString: "9B8A7C6D-5E4F-4A3B-8C2D-1E0F9A8B7C6D"))

        #expect(
            replay.commands.first(where: { if case .connect = $0 { true } else { false } }) == .connect(tx, delay: 0))
        let clock = t0.addingTimeInterval(1.2)
        #expect(
            replay.readings == [
                DexcomReading(glucose: 95, measuredAt: clock, trendRate: 0, isBackfill: false),
                DexcomReading(
                    glucose: 92, measuredAt: clock.addingTimeInterval(-1200), trendRate: -0.2, isBackfill: true),
                DexcomReading(
                    glucose: 93, measuredAt: clock.addingTimeInterval(-900), trendRate: -0.1, isBackfill: true),
                DexcomReading(glucose: 94, measuredAt: clock.addingTimeInterval(-600), trendRate: 0, isBackfill: true),
                DexcomReading(glucose: 93, measuredAt: clock.addingTimeInterval(-300), trendRate: 0, isBackfill: true)
            ])
    }
}

@Suite("G6 passive observer")
struct G6ObserverTests {
    let tx = DexcomPeripheral(id: UUID(), name: "Dexcom4B")
    let time = hex("2500beb24d00f22d4d000100000083c0")
    let glucose = hex("3100000000008eb14d00820006f6a038")

    /// An observer started, Bluetooth on, connected to `tx` and ready.
    func connected(_ observer: inout G6Observer, at now: Date = t0) {
        _ = observer.start(now: now)
        _ = observer.handle(.bluetooth(.poweredOn), now: now)
        _ = observer.handle(.found(known: nil, systemConnected: [tx]), now: now)
        _ = observer.handle(.connected(tx), now: now)
        _ = observer.handle(.ready(tx), now: now)
    }

    @Test("control notifications wait for the Dexcom app's authenticated, bonded reply")
    func controlWaitsForAuthentication() {
        var observer = G6Observer()
        connected(&observer)
        #expect(observer.handle(.value(tx, .authentication, hex("050001")), now: t0).commands.isEmpty)
        #expect(observer.handle(.value(tx, .authentication, hex("050100")), now: t0).commands.isEmpty)
        #expect(
            observer.handle(.value(tx, .authentication, hex("050101")), now: t0).commands == [.listen(tx.id, .control)])
        #expect(observer.handle(.value(tx, .authentication, hex("050101")), now: t0).commands.isEmpty)
    }

    @Test("a reading before the transmitter's clock reply is not used")
    func noReadingWithoutClock() {
        var observer = G6Observer()
        connected(&observer)
        _ = observer.handle(.value(tx, .authentication, hex("050101")), now: t0)
        #expect(observer.handle(.value(tx, .control, glucose), now: t0).readings.isEmpty)
        #expect(observer.status(now: t0) == .problem(.notReady("waiting for the transmitter's clock")))
    }

    @Test("after a relaunch, the remembered transmitter's clock dates a reading before any clock reply")
    func rememberedActivationDate() {
        let activation = t0.addingTimeInterval(-5_092_030)
        var observer = G6Observer(peripheralID: tx.id, activationDate: activation)
        connected(&observer)
        _ = observer.handle(.value(tx, .authentication, hex("050101")), now: t0)
        let readings = observer.handle(.value(tx, .control, glucose), now: t0).readings
        #expect(readings.map(\.measuredAt) == [activation.addingTimeInterval(5_091_726)])
        _ = observer.handle(.value(tx, .control, time), now: t0.addingTimeInterval(10))
        #expect(observer.memory.activationDate == t0.addingTimeInterval(10 - 5_092_030))
    }

    @Test("a different transmitter signing in forgets the remembered clock")
    func otherTransmitterForgetsClock() {
        var observer = G6Observer(peripheralID: UUID(), activationDate: t0.addingTimeInterval(-1_000_000))
        connected(&observer)
        _ = observer.handle(.value(tx, .authentication, hex("050101")), now: t0)
        #expect(observer.memory == DexcomMemory(peripheralID: tx.id, activationDate: nil))
        #expect(observer.handle(.value(tx, .control, glucose), now: t0).readings.isEmpty)
    }

    @Test("an unreliable calibration state gives no reading and says why")
    func warmupGivesNoReading() {
        var observer = G6Observer()
        connected(&observer)
        _ = observer.handle(.value(tx, .control, time), now: t0)
        let warmup = hex("3100000000008eb14d00820002f664f4")
        #expect(observer.handle(.value(tx, .control, warmup), now: t0).readings.isEmpty)
        #expect(observer.status(now: t0) == .problem(.notReady("warmup")))
        #expect(observer.handle(.value(tx, .control, glucose), now: t0).readings.count == 1)
        #expect(observer.status(now: t0) == .reading)
    }

    @Test("LOW (39) is passed on for the caller to treat as below range; a corrupt frame is dropped")
    func lowAndCorrupt() {
        var observer = G6Observer()
        connected(&observer)
        _ = observer.handle(.value(tx, .control, time), now: t0)
        let low = observer.handle(.value(tx, .control, hex("3100000000008eb14d00270006f6936e")), now: t0)
        #expect(low.readings.map(\.glucose) == [39])
        #expect(
            observer.handle(.value(tx, .control, hex("3100000000008eb14d00270006f6936f")), now: t0).readings.isEmpty)
    }

    @Test("values from a peripheral other than the followed one are ignored")
    func strayPeripheralIgnored() {
        var observer = G6Observer()
        connected(&observer)
        let stray = DexcomPeripheral(id: UUID(), name: "Dexcom4B")
        #expect(observer.handle(.value(stray, .authentication, hex("050101")), now: t0).commands.isEmpty)
    }

    @Test("with an ID, only the transmitter whose name ends in its last two characters is connected")
    func transmitterIDMatching() {
        var observer = G6Observer(transmitterID: "8G12AB")
        _ = observer.start(now: t0)
        _ = observer.handle(.bluetooth(.poweredOn), now: t0)
        _ = observer.handle(.found(known: nil, systemConnected: []), now: t0)
        let wrong = DexcomPeripheral(id: UUID(), name: "Dexcom4B")
        let right = DexcomPeripheral(id: UUID(), name: "DexcomAB")
        #expect(observer.handle(.discovered(wrong), now: t0).commands.isEmpty)
        #expect(observer.handle(.discovered(right), now: t0).commands == [.stopScan, .connect(right.id, delay: 0)])
    }

    @Test("with no ID, any Dexcom transmitter, but nothing else")
    func noIDMatching() {
        var observer = G6Observer()
        _ = observer.start(now: t0)
        _ = observer.handle(.bluetooth(.poweredOn), now: t0)
        #expect(observer.handle(.discovered(DexcomPeripheral(id: UUID(), name: "DXCM12")), now: t0).commands.isEmpty)
        #expect(observer.handle(.discovered(DexcomPeripheral(id: UUID(), name: nil)), now: t0).commands.isEmpty)
        #expect(observer.handle(.discovered(tx), now: t0).commands == [.stopScan, .connect(tx.id, delay: 0)])
    }

    @Test("the remembered transmitter comes first, then one the system has connected, else a scan")
    func lookUpOrder() {
        let known = DexcomPeripheral(id: UUID(), name: "Dexcom4B")
        var observer = G6Observer(peripheralID: known.id)
        _ = observer.start(now: t0)
        #expect(observer.handle(.bluetooth(.poweredOn), now: t0).commands == [.lookUp(known: known.id, delay: 0)])
        #expect(
            observer.handle(.found(known: known, systemConnected: [tx]), now: t0).commands == [
                .stopScan, .connect(known.id, delay: 0)
            ])

        var fresh = G6Observer()
        _ = fresh.start(now: t0)
        _ = fresh.handle(.bluetooth(.poweredOn), now: t0)
        #expect(fresh.handle(.found(known: nil, systemConnected: []), now: t0).commands == [.scan])
    }

    @Test("after the transmitter closes the link, ask to connect again after 2 s")
    func reconnectAfterDisconnect() {
        var observer = G6Observer()
        connected(&observer)
        _ = observer.handle(.value(tx, .authentication, hex("050101")), now: t0)
        #expect(observer.handle(.disconnected(tx, .remote), now: t0).commands == [.connect(tx.id, delay: 2)])
        #expect(observer.status(now: t0) == .searching)
    }

    @Test("repeated connection failures back off, up to a minute")
    func failureBackoff() {
        var observer = G6Observer()
        _ = observer.start(now: t0)
        _ = observer.handle(.bluetooth(.poweredOn), now: t0)
        _ = observer.handle(.discovered(tx), now: t0)
        let delays = (0..<8).map { _ -> TimeInterval? in
            guard case .connect(_, let delay) = observer.handle(.failedToConnect(tx, "busy"), now: t0).commands.first
            else { return nil }
            return delay
        }
        #expect(delays == [2, 4, 8, 16, 32, 60, 60, 60])
        _ = observer.handle(.connected(tx), now: t0)
        _ = observer.handle(.disconnected(tx, .remote), now: t0)
        guard case .connect(_, let delay) = observer.handle(.failedToConnect(tx, "busy"), now: t0).commands.first
        else { return #expect(Bool(false)) }
        #expect(delay == 2)
    }

    @Test("two connections the Dexcom app never signed in on: the app says the Dexcom app isn't connected")
    func dexcomAppNotConnected() {
        let known = DexcomPeripheral(id: UUID(), name: "Dexcom4B")
        var observer = G6Observer(peripheralID: known.id)
        _ = observer.start(now: t0)
        _ = observer.handle(.bluetooth(.poweredOn), now: t0)
        _ = observer.handle(.found(known: known, systemConnected: []), now: t0)
        for _ in 0..<2 {
            _ = observer.handle(.connected(known), now: t0)
            _ = observer.handle(.ready(known), now: t0)
            _ = observer.handle(.disconnected(known, .remote), now: t0)
        }
        #expect(observer.status(now: t0) == .problem(.dexcomAppNotConnected))
        _ = observer.handle(.connected(known), now: t0)
        _ = observer.handle(.value(known, .authentication, hex("050101")), now: t0)
        #expect(observer.status(now: t0) == .waiting)
    }

    @Test("with no ID, a scanned transmitter that never signs in is skipped for another")
    func strangerSkipped() {
        var observer = G6Observer()
        _ = observer.start(now: t0)
        _ = observer.handle(.bluetooth(.poweredOn), now: t0)
        _ = observer.handle(.discovered(tx), now: t0)
        _ = observer.handle(.connected(tx), now: t0)
        #expect(observer.handle(.disconnected(tx, .remote), now: t0).commands == [.connect(tx.id, delay: 2)])
        _ = observer.handle(.connected(tx), now: t0)
        #expect(observer.handle(.disconnected(tx, .remote), now: t0).commands == [.lookUp(known: nil, delay: 2)])
        #expect(observer.handle(.found(known: nil, systemConnected: [tx]), now: t0).commands == [.scan])
        #expect(observer.handle(.discovered(tx), now: t0).commands.isEmpty)
    }

    @Test("nothing for 11 minutes: not found; Bluetooth off and not allowed say so")
    func whyItCantConnect() {
        var observer = G6Observer()
        _ = observer.start(now: t0)
        #expect(observer.status(now: t0) == .searching)
        _ = observer.handle(.bluetooth(.poweredOff), now: t0)
        #expect(observer.status(now: t0) == .problem(.bluetoothOff))
        _ = observer.handle(.bluetooth(.unauthorized), now: t0)
        #expect(observer.status(now: t0) == .problem(.bluetoothNotAllowed))
        _ = observer.handle(.bluetooth(.poweredOn), now: t0)
        #expect(observer.status(now: t0.addingTimeInterval(10 * 60)) == .searching)
        #expect(observer.status(now: t0.addingTimeInterval(11 * 60 + 1)) == .problem(.notFound))
    }

    @Test("a connection error is the reason when nothing connects")
    func connectionErrorReported() {
        var observer = G6Observer()
        _ = observer.start(now: t0)
        _ = observer.handle(.bluetooth(.poweredOn), now: t0)
        _ = observer.handle(.discovered(tx), now: t0)
        _ = observer.handle(.failedToConnect(tx, "Peer removed pairing information"), now: t0)
        #expect(
            observer.status(now: t0.addingTimeInterval(12 * 60))
                == .problem(.connectionFailed("Peer removed pairing information")))
    }

    @Test("a request waiting past the limit keeps waiting while a scan looks for a replacement")
    func tickScansBesideTheRequest() {
        let known = DexcomPeripheral(id: UUID(), name: "Dexcom4B")
        var observer = G6Observer(transmitterID: "8G124B", peripheralID: known.id)
        _ = observer.start(now: t0)
        _ = observer.handle(.bluetooth(.poweredOn), now: t0)
        _ = observer.handle(.found(known: known, systemConnected: []), now: t0)
        let replacement = DexcomPeripheral(id: UUID(), name: "Dexcom4B")
        #expect(observer.handle(.discovered(replacement), now: t0).commands.isEmpty)
        #expect(observer.handle(.tick, now: t0.addingTimeInterval(5 * 60)).commands.isEmpty)
        #expect(observer.handle(.tick, now: t0.addingTimeInterval(12 * 60)).commands == [.scan])
        #expect(observer.handle(.tick, now: t0.addingTimeInterval(13 * 60)).commands.isEmpty)
        #expect(observer.peripheralID == known.id)
        #expect(
            observer.handle(.discovered(replacement), now: t0).commands == [
                .stopScan, .cancel(known.id), .connect(replacement.id, delay: 0)
            ])
    }

    @Test("if the remembered transmitter answers first, the extra scan stops")
    func tickScanStopsOnReconnect() {
        let known = DexcomPeripheral(id: UUID(), name: "Dexcom4B")
        var observer = G6Observer(peripheralID: known.id)
        _ = observer.start(now: t0)
        _ = observer.handle(.bluetooth(.poweredOn), now: t0)
        _ = observer.handle(.found(known: known, systemConnected: []), now: t0)
        _ = observer.handle(.tick, now: t0.addingTimeInterval(12 * 60))
        #expect(observer.handle(.connected(known), now: t0).commands == [.stopScan])
    }

    @Test("a restored transmitter with no name is still the remembered one, and is read")
    func restoredWithoutName() {
        let known = DexcomPeripheral(id: UUID(), name: nil)
        var observer = G6Observer(peripheralID: known.id)
        _ = observer.start(now: t0)
        _ = observer.handle(.restored([known]), now: t0)
        _ = observer.handle(.bluetooth(.poweredOn), now: t0)
        _ = observer.handle(.connected(known), now: t0)
        #expect(observer.handle(.ready(known), now: t0).commands == [.listen(known.id, .authentication)])
    }

    @Test("a connection that drops before it was marked connected still asks to reconnect")
    func disconnectWhileNotConnected() {
        var observer = G6Observer()
        _ = observer.start(now: t0)
        _ = observer.handle(.bluetooth(.poweredOn), now: t0)
        _ = observer.handle(.discovered(tx), now: t0)
        #expect(observer.handle(.disconnected(tx, .remote), now: t0).commands == [.connect(tx.id, delay: 2)])
    }

    @Test("changing the ID lets go of a transmitter that no longer matches")
    func changeTransmitterID() {
        var observer = G6Observer()
        connected(&observer)
        #expect(observer.setTransmitterID("8G124B", now: t0).isEmpty)
        #expect(observer.setTransmitterID("8G12CD", now: t0) == [.cancel(tx.id), .lookUp(known: nil, delay: 0)])
        #expect(observer.transmitterID == "8G12CD")
        #expect(observer.setTransmitterID("bad", now: t0) == [])
        #expect(observer.transmitterID == nil)
    }

    @Test("a backfill whose CRC doesn't match the reply is not used")
    func backfillCRCMismatch() {
        var observer = G6Observer()
        connected(&observer)
        _ = observer.handle(.value(tx, .control, hex("2500ed6e0e00a0bb0d00010000002794")), now: t0)
        _ = observer.handle(.value(tx, .backfill, hex("0180440c00003d6a0e005c0007fe696b0e005d00")), now: t0)
        _ = observer.handle(.value(tx, .backfill, hex("028007ff956c0e005e000700c16d0e005d000701")), now: t0)
        #expect(
            observer.handle(.value(tx, .control, hex("510001023d6a0e00c16d0e00280000005b1a9154")), now: t0)
                .readings.isEmpty)
    }

    @Test("stopped: events change nothing, and stopping cancels the connection")
    func stopped() {
        var observer = G6Observer()
        connected(&observer)
        #expect(observer.stop() == [.stopScan, .cancel(tx.id)])
        #expect(observer.handle(.bluetooth(.poweredOn), now: t0).commands.isEmpty)
        #expect(observer.status(now: t0) == .stopped)
    }
}

@Suite("G6 transmitter ID")
struct G6TransmitterIDTests {
    @Test func normalizes() {
        #expect(G6TransmitterID.normalized(" 8g12ab\n") == "8G12AB")
        #expect(G6TransmitterID.normalized("8G12AB\u{0}\u{0}\u{0}") == "8G12AB")
        #expect(G6TransmitterID.normalized("8G12A") == nil)
        #expect(G6TransmitterID.normalized("8G12AB7") == nil)
        #expect(G6TransmitterID.normalized("8G-2AB") == nil)
        #expect(G6TransmitterID.normalized("") == nil)
        #expect(G6TransmitterID.normalized(nil) == nil)
    }

    @Test("an ID typed in settings wins over the pump's")
    func enteredWins() {
        #expect(G6TransmitterID.preferred(entered: "8G0001", fromPump: "8G0002") == "8G0001")
        #expect(G6TransmitterID.preferred(entered: nil, fromPump: "8G0002\u{0}") == "8G0002")
        #expect(G6TransmitterID.preferred(entered: "junk", fromPump: "8G0002") == "8G0002")
        #expect(G6TransmitterID.preferred(entered: nil, fromPump: nil) == nil)
    }
}
