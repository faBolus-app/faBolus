import Foundation
import Testing

@testable import DexcomBLE

@Suite("Dexcom session log")
struct DexcomSessionLogTests {
    @Test("a written log reads back as the same events")
    func roundTrip() throws {
        let tx = DexcomPeripheral(id: UUID(), name: "Dexcom 4B")
        let other = DexcomPeripheral(id: UUID(), name: nil)
        let events: [DexcomEvent] = [
            .bluetooth(.poweredOn), .restored([tx]), .found(known: nil, systemConnected: [tx, other]),
            .found(known: tx, systemConnected: []), .discovered(other), .connected(tx), .ready(tx),
            .setupFailed(tx, "no CGM service"), .value(tx, .authentication, Data([0x05, 0x01, 0x01])),
            .disconnected(tx, .remote), .disconnected(tx, .local), .disconnected(tx, .error("Connection timed out")),
            .failedToConnect(tx, nil), .failedToConnect(tx, "busy"), .tick
        ]
        var log = DexcomSessionLog()
        for (index, event) in events.enumerated() { log.append(event, at: Double(index) * 1.5) }
        let parsed = try DexcomSessionLog(parsing: log.text)
        #expect(parsed.entries == log.entries)
    }

    @Test("an unknown peripheral or event is an error naming the line")
    func badLines() {
        #expect(throws: DexcomSessionLog.ParseError.badLine(2, "1 connected nobody")) {
            try DexcomSessionLog(parsing: "# header\n1 connected nobody\n")
        }
        #expect(throws: DexcomSessionLog.ParseError.badLine(1, "1 explode")) {
            try DexcomSessionLog(parsing: "1 explode")
        }
    }
}

@Suite("Dexcom link status")
struct DexcomLinkTrackerTests {
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a reading ages out of 'reading' after one cycle and a margin")
    func readingAgesOut() {
        var link = DexcomLinkTracker()
        link.start(now: t0)
        link.setBluetooth(.poweredOn)
        link.didConnect(now: t0)
        link.didSignIn(now: t0)
        link.didRead(now: t0)
        #expect(link.status(now: t0.addingTimeInterval(6 * 60)) == .reading)
        #expect(link.status(now: t0.addingTimeInterval(6 * 60 + 1)) == .waiting)
        link.didDisconnect(now: t0.addingTimeInterval(7 * 60), .remote)
        #expect(link.status(now: t0.addingTimeInterval(7 * 60)) == .searching)
        #expect(link.status(now: t0.addingTimeInterval(18 * 60 + 1)) == .problem(.notFound))
    }

    @Test("a sensor problem outranks waiting, and a reading clears it")
    func notReadyClears() {
        var link = DexcomLinkTracker()
        link.start(now: t0)
        link.setBluetooth(.poweredOn)
        link.didSignIn(now: t0)
        link.sensorNotReady("warmup")
        #expect(link.status(now: t0) == .problem(.notReady("warmup")))
        link.didRead(now: t0)
        #expect(link.status(now: t0) == .reading)
    }
}
