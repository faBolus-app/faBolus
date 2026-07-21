import Foundation
@preconcurrency import CoreBluetooth
import faBolusCore
import DexcomG6Kit

/// Dexcom G5 / G6 / ONE **passive** BLE glucose source — the "Follow Dexcom-app" mode. The official
/// Dexcom app stays the master (it authenticates and owns the session); faBolus connects as a second
/// central and **passively reads** the glucose messages the transmitter broadcasts on the control
/// characteristic. It **never** writes the authentication or control characteristics, so it can't
/// disconnect the official app. Decodes with the vendored `DexcomG6Kit` (from LoopKit/CGMBLEKit, MIT).
///
/// Requires the official Dexcom app installed and connected (it keeps the session alive). Local,
/// no cloud. Its own `CBCentralManager` (distinct restore identifier) keeps it isolated from the pump.
@MainActor
final class DexcomG6BLESource: NSObject, GlucoseSource {
    let id = "dexcom-g6-ble"
    let priority = 100                       // local BLE outranks cloud sources
    private(set) var latest: GlucoseSample?
    private(set) var history: [GlucoseReading] = []
    private(set) var status: GlucoseSourceStatus = .idle
    var onChange: (@MainActor () -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?
    private static let restoreIdentifier = "com.fabolus.app.cgm.g6"

    /// Optional Dexcom transmitter ID (6 chars). Used only to pick the right transmitter by its
    /// advertised name suffix when several Dexcom sensors are in range; passive reads need no auth.
    private var transmitterID: String { (GlucoseSourceConfig.string("dexcomg6.transmitterId") ?? "").uppercased() }

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
        onChange?()
    }

    private func handle(_ msg: GlucoseRxMessage) {
        guard msg.hasReliableGlucose else { status = .connected; onChange?(); return }
        // Passive readings arrive in real time (~5 min), so stamp at receipt (the message timestamp
        // is transmitter-relative and would need the activation date to convert).
        let sample = GlucoseSample(mgdl: msg.glucoseMgdl, date: Date(),
                                   trend: Self.trend(msg.trendDirection), sourceID: id)
        latest = sample
        var byBucket: [Int: GlucoseReading] = [:]
        for r in history + [sample.reading] { byBucket[Int(r.date.timeIntervalSince1970 / 300)] = r }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        history = byBucket.values.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
        status = .connected
        onChange?()
    }

    private static func trend(_ d: G6TrendDirection?) -> GlucoseTrend {
        switch d {
        case .downDownDown, .downDown: return .downDown
        case .down: return .down
        case .flat, nil: return .flat
        case .up: return .up
        case .upUp, .upUpUp: return .upUp
        }
    }

    /// A Dexcom transmitter advertises as "DexcomXX" where XX is the last 2 chars of its ID.
    private func matches(_ peripheral: CBPeripheral, advName: String?) -> Bool {
        let id = transmitterID
        guard id.count >= 2 else { return true }   // no ID configured → accept the first Dexcom
        let name = (advName ?? peripheral.name ?? "").uppercased()
        return name.hasSuffix(String(id.suffix(2)))
    }
}

// CoreBluetooth callbacks run on `queue: .main`; `MainActor.assumeIsolated` hops into the main actor.
extension DexcomG6BLESource: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            guard central.state == .poweredOn else { status = .searching; onChange?(); return }
            if let existing = central.retrieveConnectedPeripherals(
                withServices: [TransmitterServiceUUID.cgmService.cbUUID]).first {
                peripheral = existing
                existing.delegate = self
                central.connect(existing)
            } else {
                central.scanForPeripherals(withServices: [TransmitterServiceUUID.advertisement.cbUUID])
            }
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                                    advertisementData: [String: Any], rssi RSSI: NSNumber) {
        // Pull the advertised name out here so the non-Sendable [String: Any] isn't sent into the
        // main-actor closure (Swift 6).
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        MainActor.assumeIsolated {
            guard self.peripheral == nil, matches(peripheral, advName: advName) else { return }
            self.peripheral = peripheral
            peripheral.delegate = self
            central.stopScan()
            central.connect(peripheral)
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        MainActor.assumeIsolated {
            peripheral.discoverServices([TransmitterServiceUUID.cgmService.cbUUID])
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            status = .searching; onChange?()
            central.connect(peripheral)   // auto-reconnect; the transmitter stays advertising
        }
    }

    nonisolated func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                                    error: Error?) {
        MainActor.assumeIsolated {
            self.peripheral = nil
            central.scanForPeripherals(withServices: [TransmitterServiceUUID.advertisement.cbUUID])
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        MainActor.assumeIsolated {
            guard let service = peripheral.services?.first(where: {
                $0.uuid == TransmitterServiceUUID.cgmService.cbUUID
            }) else { return }
            // Subscribe to the notify characteristics only — never authentication/control *writes*.
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
                peripheral.setNotifyValue(true, for: c)   // read-only: enable notifications, no writes
            }
        }
    }

    nonisolated func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                                error: Error?) {
        MainActor.assumeIsolated {
            guard let data = characteristic.value, !data.isEmpty,
                  characteristic.uuid == CGMServiceCharacteristicUUID.control.cbUUID,
                  let msg = GlucoseRxMessage(data: data) else { return }
            handle(msg)
        }
    }
}
