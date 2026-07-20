import Foundation
import CoreBluetooth
import faBolusCore
import G7SensorKit

/// Dexcom G7 / ONE+ **passive** BLE glucose source — a read-only failover feed that listens to the
/// sensor's unencrypted 5-minute broadcast alongside the official Dexcom app and the pump. It scans
/// for the G7 service, subscribes to the control (glucose) + backfill (history) characteristics, and
/// decodes them with the vendored `G7SensorKit`. It **never** writes to the authentication or control
/// characteristics — sending auth would seize the session and disconnect the official app. Its own
/// `CBCentralManager` (distinct restore identifier) keeps it isolated from the pump connection.
@MainActor
final class DexcomG7BLESource: NSObject, GlucoseSource {
    let id = "dexcom-g7-ble"
    let priority = 100                       // local BLE outranks cloud sources
    private(set) var latest: GlucoseSample?
    private(set) var history: [GlucoseReading] = []
    private(set) var status: GlucoseSourceStatus = .idle
    var onChange: (@MainActor () -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private static let restoreIdentifier = "com.fabolus.app.cgm"

    // Sensor clock → wall clock. G7 timestamps are "seconds since pairing"; we anchor them to the
    // wall time a live message arrived: wall(s) = receivedAt + (s - messageTimestamp).
    private var anchorMessageTimestamp: UInt32?
    private var anchorReceivedAt: Date?
    private var pendingBackfill: [G7BackfillMessage] = []

    func start() async {
        guard central == nil else { return }
        status = .searching
        central = CBCentralManager(delegate: self, queue: .main,
                                   options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier])
    }

    func stop() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        central?.stopScan()
        peripheral = nil
        status = .idle
        notify()
    }

    private func notify() { onChange?() }

    // MARK: Decoding → GlucoseSample

    private func wallTime(forSensor ts: UInt32) -> Date? {
        guard let anchorTs = anchorMessageTimestamp, let anchorAt = anchorReceivedAt else { return nil }
        return anchorAt.addingTimeInterval(Double(Int64(ts) - Int64(anchorTs)))
    }

    private func handleGlucose(_ msg: G7GlucoseMessage) {
        anchorMessageTimestamp = msg.messageTimestamp
        anchorReceivedAt = Date()
        guard let mgdl = msg.glucose, msg.hasReliableGlucose,
              let date = wallTime(forSensor: msg.glucoseTimestamp) else {
            status = .connected
            notify()
            return
        }
        latest = GlucoseSample(mgdl: Int(mgdl), date: date,
                               trend: Self.trend(msg.trendDirection), sourceID: id)
        merge([GlucoseReading(date: date, mgdl: Int(mgdl))])
        drainPendingBackfill()
        status = .connected
        notify()
    }

    private func handleBackfill(_ msg: G7BackfillMessage) {
        guard let mgdl = msg.glucose, msg.hasReliableGlucose else { return }
        if let date = wallTime(forSensor: msg.timestamp) {
            merge([GlucoseReading(date: date, mgdl: Int(mgdl))])
            notify()
        } else {
            pendingBackfill.append(msg)   // no wall anchor yet; convert once a live message lands
        }
    }

    private func drainPendingBackfill() {
        guard !pendingBackfill.isEmpty else { return }
        let readings = pendingBackfill.compactMap { m -> GlucoseReading? in
            guard let g = m.glucose, m.hasReliableGlucose, let d = wallTime(forSensor: m.timestamp)
            else { return nil }
            return GlucoseReading(date: d, mgdl: Int(g))
        }
        pendingBackfill.removeAll()
        merge(readings)
    }

    /// Add readings, keep the last 24 h deduped into 5-minute buckets, newest last.
    private func merge(_ readings: [GlucoseReading]) {
        var byBucket: [Int: GlucoseReading] = [:]
        for r in history + readings { byBucket[Int(r.date.timeIntervalSince1970 / 300)] = r }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        history = byBucket.values.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
    }

    private static func trend(_ d: G7TrendDirection?) -> GlucoseTrend {
        switch d {
        case .downDownDown, .downDown: return .downDown
        case .down: return .down
        case .flat, nil: return .flat
        case .up: return .up
        case .upUp, .upUpUp: return .upUp
        }
    }
}

// CoreBluetooth delegate callbacks run on `queue: .main`, so `MainActor.assumeIsolated` hops into the
// main actor to touch our state — matching PumpX2BLE's `PumpBLEClient`.
extension DexcomG7BLESource: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            guard central.state == .poweredOn else { status = .searching; notify(); return }
            central.scanForPeripherals(withServices: [SensorServiceUUID.advertisement.cbUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        MainActor.assumeIsolated {
            if let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
               let p = restored.first {
                peripheral = p
                p.delegate = self
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        MainActor.assumeIsolated {
            // First G7 wins (multi-connection; the official app keeps its own link).
            guard self.peripheral == nil else { return }
            self.peripheral = peripheral
            peripheral.delegate = self
            central.stopScan()
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            peripheral.discoverServices([SensorServiceUUID.cgmService.cbUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            status = .searching
            notify()
            central.connect(peripheral)   // auto-reconnect; the sensor stays advertising
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            self.peripheral = nil
            central.scanForPeripherals(withServices: [SensorServiceUUID.advertisement.cbUUID])
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: {
                $0.uuid == SensorServiceUUID.cgmService.cbUUID
            }) else { return }
            // Subscribe to the notify characteristics only. Never authentication/control *writes*.
            peripheral.discoverCharacteristics([
                CGMServiceCharacteristicUUID.control.cbUUID,
                CGMServiceCharacteristicUUID.backfill.cbUUID,
                CGMServiceCharacteristicUUID.communication.cbUUID,
            ], for: service)
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                                error: Error?) {
        MainActor.assumeIsolated {
            for c in service.characteristics ?? [] where c.properties.contains(.notify) || c.properties.contains(.indicate) {
                peripheral.setNotifyValue(true, for: c)   // read-only: enabling notifications, no writes
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard let data = characteristic.value, !data.isEmpty else { return }
            switch characteristic.uuid {
            case CGMServiceCharacteristicUUID.control.cbUUID:
                if data.starts(with: .glucoseTx), let msg = G7GlucoseMessage(data: data) {
                    handleGlucose(msg)
                }
            case CGMServiceCharacteristicUUID.backfill.cbUUID:
                if let msg = G7BackfillMessage(data: data) { handleBackfill(msg) }
            default:
                break
            }
        }
    }
}
