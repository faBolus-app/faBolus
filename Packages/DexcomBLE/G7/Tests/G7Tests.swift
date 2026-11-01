import DexcomBLE
import Foundation
import Testing

@testable import DexcomG7

let t0 = Date(timeIntervalSince1970: 1_800_000_000)

//
//  The message tests are ported from G7SensorKit's G7GlucoseMessageTests (MIT), keeping their fixtures
//  and expectations. Copyright © 2022 LoopKit Authors.
//
@Suite("G7 messages (G7SensorKit fixtures)")
struct G7MessageTests {
    @Test func messageData() throws {
        let message = try #require(G7GlucoseMessage(data: hex("4e00c35501002601000106008a00060187000f")))
        #expect(message.glucose == 138)
        #expect(message.glucoseTimestamp == 87485)
        #expect(!message.glucoseIsDisplayOnly)
    }

    @Test func messageDataWithCalibration() throws {
        let message = try #require(G7GlucoseMessage(data: hex("4e000ec10d00c00b00010000680006fe63001f")))
        #expect(message.glucose == 104)
        #expect(message.glucoseTimestamp == 901_390)
        #expect(message.glucoseIsDisplayOnly)
    }

    @Test func lifecycle() throws {
        let messages = try [
            "4e00b6000000010000006600ffff017fffff00", "4e00cd000000030000010500ffff027fffff01",
            "4e00f90100000400000105009100027effff02", "4e00250300000500000105007d00027effff02",
            "4e0051040000060000010500650002dfffff02", "4e007d0500000700000105004e0002e7ffff02",
            "4e00ab060000080000010700540006f5ffff0e", "4e00d507000009000001050061000601ffff0e",
            "4e004d440e00d40b0001d46b650018036a000e"
        ].map { try #require(G7GlucoseMessage(data: hex($0))) }

        #expect(messages[0].glucose == nil)
        #expect(messages[1].glucose == nil)
        #expect(messages[2].glucose == 145)
        #expect(
            messages.map(\.algorithmState) == [
                .known(.stopped), .known(.warmup), .known(.warmup), .known(.warmup), .known(.warmup),
                .known(.warmup), .known(.ok), .known(.ok), .known(.expired)
            ])
        #expect(messages.map(\.sequence) == [1, 3, 4, 5, 6, 7, 8, 9, 3028])
        #expect(messages.map(\.glucoseTimestamp) == [80, 200, 500, 800, 1100, 1400, 1700, 2000, 907_385])
    }

    @Test func messageDataDetails() throws {
        let message = try #require(G7GlucoseMessage(data: hex("4e00a89c00008800000104008d0006038a000f")))
        #expect(message.glucose == 141)
        #expect(message.glucoseTimestamp == 40100)
        #expect(message.sequence == 136)
        #expect(message.age == 4)
        #expect(message.predicted == 138)
        #expect(message.trend == 0.3)
        #expect(message.algorithmState == .known(.ok))
        #expect(!message.glucoseIsDisplayOnly)
    }

    @Test func rates() throws {
        #expect(try #require(G7GlucoseMessage(data: hex("4e00c6cc0d00ca0b00010500610006fe5b000f"))).trend == -0.2)
        #expect(try #require(G7GlucoseMessage(data: hex("4e00c6cc0d00ca0b000105006100067f5b000f"))).trend == nil)
    }

    @Test func twoByteAge() throws {
        let message = try #require(G7GlucoseMessage(data: hex("4e00f9590200030200012a018f000610d9000f")))
        #expect(message.age == 298)
        #expect(message.messageTimestamp == 154_105)
        #expect(message.glucoseTimestamp == 153_807)
    }

    @Test func twoByteAgeOnExpiredSensor() throws {
        let message = try #require(G7GlucoseMessage(data: hex("4e004d440e00d40b0001d46b650018036a000e")))
        #expect(message.age == 27604)  // 7 hours after expiration
        #expect(message.messageTimestamp == 934_989)
        #expect(message.glucoseTimestamp == 907_385)
    }

    @Test("an age older than the session gives no timestamp instead of trapping")
    func ageOlderThanSession() throws {
        let message = try #require(G7GlucoseMessage(data: hex("4e00100000000100000111008d0006038a000f")))
        #expect(message.glucoseTimestamp == nil)
    }

    @Test func backfill() throws {
        let message = try #require(G7BackfillMessage(data: hex("cf5802008f00060f10")))
        #expect(message.timestamp == 153_807)
        #expect(message.glucose == 143)
        #expect(message.algorithmState == .known(.ok))
        #expect(!message.glucoseIsDisplayOnly)
        #expect(message.hasReliableGlucose)
    }

    @Test func backfillTimestampWithHighByte() throws {
        #expect(try #require(G7BackfillMessage(data: hex("f20e0d00ba00060ffb"))).timestamp == 855_794)
    }

    @Test func backfillCalibration() throws {
        #expect(try #require(G7BackfillMessage(data: hex("f63d00008500061efe"))).glucoseIsDisplayOnly)
    }
}

@Suite("G7 replay of a recorded session")
struct G7ReplayTests {
    @Test("readings dated by arrival minus the sensor's own age; a stranger's sensor dropped; expiry reported")
    func recordedSession() throws {
        var observer = G7Observer()
        let replay = try fixture("g7-session").replay(into: &observer, from: t0)
        let g7 = try #require(UUID(uuidString: "3C4D5E6F-7A8B-4C9D-8E0F-1A2B3C4D5E6F"))
        let stranger = try #require(UUID(uuidString: "7F6E5D4C-3B2A-4190-8F7E-6D5C4B3A2918"))

        // (arrival offset, age, mg/dL, trend) from the log.
        let live: [(TimeInterval, TimeInterval, UInt16, Double)] = [
            (0, 3, 106, 0.1), (301, 4, 101, -0.2), (600, 3, 98, -0.4), (900, 4, 100, -0.1), (1202, 5, 97, -0.3),
            (1502, 5, 97, -0.2), (1813, 16, 98, 0), (2101, 4, 96, -0.2), (2400, 3, 95, -0.2)
        ]
        var expected = live.map {
            DexcomReading(
                glucose: $0.2, measuredAt: t0.addingTimeInterval($0.0 - $0.1), trendRate: $0.3, isBackfill: false)
        }
        // Sensor time 855794 s, dated from the first message (sensor time 902888 s at offset 0).
        expected.insert(
            DexcomReading(
                glucose: 186, measuredAt: t0.addingTimeInterval(855_794 - 902_888), trendRate: -0.5, isBackfill: true),
            at: 1)
        #expect(replay.readings == expected)

        #expect(observer.sensorName == "DXCM15")
        #expect(observer.peripheralID == g7)
        #expect(replay.commands.contains(.connect(stranger, delay: 0)))
        #expect(!replay.commands.contains(.connect(stranger, delay: 2)))
        #expect(replay.commands.filter { $0 == .listen(g7, .control) }.count == 10)
        #expect(replay.statuses.last == .problem(.notReady("expired")))
    }
}

@Suite("G7 passive observer")
struct G7ObserverTests {
    let sensor = DexcomPeripheral(id: UUID(), name: "DXCM15")
    let reading = hex("4e00e8c60d00c50b000103006a0006016a000f")

    func connected(_ observer: inout G7Observer, _ peripheral: DexcomPeripheral) {
        _ = observer.handle(.discovered(peripheral), now: t0)
        _ = observer.handle(.connected(peripheral), now: t0)
        _ = observer.handle(.ready(peripheral), now: t0)
    }

    func started(sensorName: String? = nil) -> G7Observer {
        var observer = G7Observer(sensorName: sensorName)
        _ = observer.start(now: t0)
        _ = observer.handle(.bluetooth(.poweredOn), now: t0)
        _ = observer.handle(.found(known: nil, systemConnected: []), now: t0)
        return observer
    }

    @Test("G7 and ONE+ names are connected; G6 and others aren't")
    func names() {
        var observer = started()
        #expect(observer.handle(.discovered(sensor), now: t0).commands == [.connect(sensor.id, delay: 0)])
        let onePlus = DexcomPeripheral(id: UUID(), name: "DX02AB")
        #expect(observer.handle(.discovered(onePlus), now: t0).commands == [.connect(onePlus.id, delay: 0)])
        #expect(observer.handle(.discovered(DexcomPeripheral(id: UUID(), name: "Dexcom4B")), now: t0).commands.isEmpty)
        #expect(observer.handle(.discovered(sensor), now: t0).commands.isEmpty)
    }

    @Test("following a sensor: only names ending in its last two characters")
    func followedName() {
        var observer = started(sensorName: "DXCM15")
        #expect(observer.handle(.discovered(DexcomPeripheral(id: UUID(), name: "DXCMZZ")), now: t0).commands.isEmpty)
        #expect(observer.handle(.discovered(sensor), now: t0).commands == [.connect(sensor.id, delay: 0)])
        #expect(observer.handle(.connected(sensor), now: t0).commands == [.stopScan])
    }

    @Test("control waits for the Dexcom app's sign-in; no reading from an unauthenticated link")
    func controlWaitsForSignIn() {
        var observer = started()
        connected(&observer, sensor)
        #expect(observer.handle(.value(sensor, .authentication, hex("050001")), now: t0).commands.isEmpty)
        #expect(
            observer.handle(.value(sensor, .authentication, hex("050101")), now: t0).commands == [
                .listen(sensor.id, .control)
            ])
    }

    @Test("the first sensor to deliver a reading is followed and the others let go")
    func firstReadingFollows() {
        var observer = started()
        let other = DexcomPeripheral(id: UUID(), name: "DXCMZZ")
        connected(&observer, other)
        connected(&observer, sensor)
        _ = observer.handle(.value(sensor, .authentication, hex("050101")), now: t0)
        let observation = observer.handle(.value(sensor, .control, reading), now: t0)
        #expect(observation.commands == [.listen(sensor.id, .backfill), .stopScan, .cancel(other.id)])
        #expect(observation.readings.map(\.glucose) == [106])
        #expect(observer.sensorName == "DXCM15")
    }

    @Test("warm-up gives no reading and says why")
    func warmup() {
        var observer = started()
        connected(&observer, sensor)
        let warmup = hex("4e00f90100000400000105009100027effff02")
        #expect(observer.handle(.value(sensor, .control, warmup), now: t0).readings.isEmpty)
        #expect(observer.status(now: t0) == .problem(.notReady("warmup")))
    }

    @Test("a session that ended lets the sensor go and starts a scan for the next one")
    func sessionEnded() {
        var observer = started(sensorName: "DXCM15")
        connected(&observer, sensor)
        // The recorded expired message with its state byte set to 26 (session ended).
        let ended = hex("4e004d440e00d40b0001d46b65001a036a000e")
        let observation = observer.handle(.value(sensor, .control, ended), now: t0)
        #expect(observation.readings.isEmpty)
        #expect(observation.commands.contains(.scan))
        #expect(observer.sensorName == nil)
        #expect(observer.peripheralID == nil)
    }

    @Test("the followed sensor is reconnected after it closes the link; others are forgotten")
    func reconnect() {
        var observer = started(sensorName: "DXCM15")
        connected(&observer, sensor)
        #expect(observer.handle(.disconnected(sensor, .remote), now: t0).commands == [.connect(sensor.id, delay: 2)])
    }

    @Test("backfill buffered until the sensor says it's finished, dated from the latest message")
    func backfillFlush() {
        var observer = started()
        connected(&observer, sensor)
        _ = observer.handle(.value(sensor, .control, reading), now: t0)
        #expect(observer.handle(.value(sensor, .backfill, hex("f20e0d00ba00060ffb")), now: t0).readings.isEmpty)
        let flushed = observer.handle(.value(sensor, .control, hex("59")), now: t0).readings
        #expect(flushed.map(\.measuredAt) == [t0.addingTimeInterval(855_794 - 902_888)])
        #expect(flushed.map(\.isBackfill) == [true])
    }

    @Test("a disconnect flushes backfill that never got its finished message")
    func backfillOnDisconnect() {
        var observer = started()
        connected(&observer, sensor)
        _ = observer.handle(.value(sensor, .control, reading), now: t0)
        _ = observer.handle(.value(sensor, .backfill, hex("f20e0d00ba00060ffb")), now: t0)
        #expect(observer.handle(.disconnected(sensor, .remote), now: t0).readings.count == 1)
    }

    @Test("a restored followed sensor with no name is still followed")
    func restoredWithoutName() {
        let restored = DexcomPeripheral(id: UUID(), name: nil)
        var observer = G7Observer(sensorName: "DXCM15", peripheralID: restored.id)
        _ = observer.start(now: t0)
        _ = observer.handle(.restored([restored]), now: t0)
        _ = observer.handle(.bluetooth(.poweredOn), now: t0)
        _ = observer.handle(.connected(restored), now: t0)
        #expect(observer.handle(.ready(restored), now: t0).commands == [.listen(restored.id, .authentication)])
    }

    @Test("a followed sensor silent past the limit: other sensors are tried, and one that reads takes over")
    func replacedSensorFound() {
        var observer = started(sensorName: "DXCM15")
        connected(&observer, sensor)
        _ = observer.handle(.disconnected(sensor, .remote), now: t0)
        let fresh = DexcomPeripheral(id: UUID(), name: "DXCMQ7")
        #expect(observer.handle(.discovered(fresh), now: t0).commands.isEmpty)
        #expect(observer.handle(.tick, now: t0.addingTimeInterval(5 * 60)).commands.isEmpty)
        _ = observer.handle(.tick, now: t0.addingTimeInterval(12 * 60))
        #expect(observer.handle(.discovered(fresh), now: t0).commands == [.connect(fresh.id, delay: 0)])
        _ = observer.handle(.connected(fresh), now: t0)
        _ = observer.handle(.ready(fresh), now: t0)
        _ = observer.handle(.value(fresh, .authentication, hex("050101")), now: t0)
        let observation = observer.handle(.value(fresh, .control, reading), now: t0)
        #expect(observation.readings.map(\.glucose) == [106])
        #expect(observation.commands.contains(.cancel(sensor.id)))
        #expect(observer.sensorName == "DXCMQ7")
    }

    @Test("after Bluetooth is turned off and on, the followed sensor is asked to connect again")
    func bluetoothPowerCycle() {
        var observer = started(sensorName: "DXCM15")
        connected(&observer, sensor)
        _ = observer.handle(.value(sensor, .control, reading), now: t0)
        _ = observer.handle(.bluetooth(.poweredOff), now: t0)
        #expect(observer.handle(.bluetooth(.poweredOn), now: t0).commands == [.lookUp(known: sensor.id, delay: 0)])
        #expect(
            observer.handle(.found(known: sensor, systemConnected: []), now: t0).commands == [
                .connect(sensor.id, delay: 0), .scan
            ])
    }

    @Test("Bluetooth off is reported; stopping cancels every connection")
    func bluetoothAndStop() {
        var observer = started()
        connected(&observer, sensor)
        var stopping = observer
        #expect(stopping.stop() == [.stopScan, .cancel(sensor.id)])
        #expect(stopping.status(now: t0) == .stopped)
        _ = observer.handle(.bluetooth(.poweredOff), now: t0)
        #expect(observer.status(now: t0) == .problem(.bluetoothOff))
    }
}
