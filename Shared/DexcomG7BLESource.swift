import Foundation
@preconcurrency import CoreBluetooth
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

    // Sensor clock → wall clock. G7 timestamps are "seconds since pairing"; we anchor them to the
    // wall time a live message arrived: wall(s) = receivedAt + (s - messageTimestamp). Unlike G6, G7
    // has NO transmitterTimeRx-equivalent broadcast, so the glucose message itself carries the anchor
    // source. The anchor is bootstrapped ONCE per connection (from a near-real-time message) and then
    // held STABLE — never re-derived per glucose message (D-02, closing the A2 self-defeat).
    private var anchorMessageTimestamp: UInt32?
    private var anchorReceivedAt: Date?
    private var pendingBackfill: [G7BackfillMessage] = []

    /// Bootstrap-eligibility ceiling (D-02): only a message that itself claims to be near-real-time
    /// (small self-reported `age`) may establish the anchor. Once set, the anchor is held for the
    /// life of the connection object and NEVER reset per glucose message — that per-message reset IS
    /// the A2 self-defeat this closes. Owner/bench-adjustable (UNVERIFIED-GUESS, `docs/UNVERIFIED-GUESSES.md` #11a).
    static var anchorBootstrapMaxAge: UInt16 = 60          // seconds

    /// Absolute plausible ceiling on a frame's own self-reported `age`. Beyond this the frame is too
    /// stale-at-transmission to trust as a live reading (≈3 G7 wake cycles). Owner/bench-adjustable
    /// (UNVERIFIED-GUESS, `docs/UNVERIFIED-GUESSES.md` #11b).
    static var plausibleFrameAgeCeiling: UInt16 = 900      // seconds

    /// Mirrors `DexcomG6BLESource.implausibleAgeBound` — beyond this the anchored date is
    /// decode/anchor-arithmetic-wrong, not a genuinely old reading (ordinary staleness stays
    /// `GlucoseFreshness`'s job). Deliberately generous so it never fires on real staleness.
    static var implausibleAgeBound: TimeInterval = 24 * 3600

    func start() async {
        guard central == nil else { return }
        status = .searching
        // No restore identifier — see DexcomG6BLESource: a duplicate restore id (launch source +
        // test source) makes CBCentralManager.init assert. Passive failover needs no restoration.
        central = CBCentralManager(delegate: self, queue: .main)
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

    /// Internal testable ingest seam (mirrors `DexcomG6BLESource.ingest(controlFrame:)`): decodes a
    /// raw control-characteristic glucose frame and routes it to `handleGlucose`, so
    /// `DexcomG7BLESourceTests` can drive the anchor/decode path directly without CoreBluetooth. The
    /// CB delegate (`peripheral(_:didUpdateValueFor:)`) is a thin wrapper over this — it adds no
    /// characteristic write and does not change the discover/subscribe set (read-only, D-12a).
    func ingest(glucoseFrame data: Data) {
        guard data.starts(with: .glucoseTx), let msg = G7GlucoseMessage(data: data) else { return }
        handleGlucose(msg)
    }

    /// Internal testable ingest seam for backfill (history) frames — same seam family as
    /// `ingest(glucoseFrame:)` so backfill decode is also drivable without CoreBluetooth.
    func ingest(backfillFrame data: Data) {
        guard let msg = G7BackfillMessage(data: data) else { return }
        handleBackfill(msg)
    }

    private func wallTime(forSensor ts: UInt32) -> Date? {
        guard let anchorTs = anchorMessageTimestamp, let anchorAt = anchorReceivedAt else { return nil }
        return anchorAt.addingTimeInterval(Double(Int64(ts) - Int64(anchorTs)))
    }

    private func handleGlucose(_ msg: G7GlucoseMessage) {
        // Require reliability first — an unreliable/absent glucose frame never anchors or publishes.
        guard let mgdl = msg.glucose, msg.hasReliableGlucose else {
            status = .connected
            notify()
            return
        }
        // Bootstrap the anchor ONCE per connection, and ONLY from a message that itself claims to be
        // near-real-time (small self-reported age). If no anchor exists yet and this message is not
        // bootstrap-eligible, leave the source unanchored and publish nothing (fail-closed): an
        // un-anchored / implausibly-anchored G7 frame must never become `latest` (D-02).
        if anchorMessageTimestamp == nil || anchorReceivedAt == nil {
            guard msg.age <= Self.anchorBootstrapMaxAge else {
                status = .connected
                notify()
                return
            }
            anchorMessageTimestamp = msg.messageTimestamp
            anchorReceivedAt = Date()
        }
        // Once an anchor exists, DO NOT recompute it from the current message — convert the frame's
        // sensor-relative timestamp via the STABLE anchor. (Deliberately never refreshed even when a
        // later message validates cleanly: a message must never be able to re-legitimize itself —
        // that is the entire point of closing A2.)
        guard let date = wallTime(forSensor: msg.glucoseTimestamp) else {
            status = .connected
            notify()
            return
        }
        // Reject the computed sample if its anchored wall time is beyond the future-skew tolerance
        // (the delayed/batched-frame hazard A2 — sensor time far ahead of the stable anchor lands in
        // the FUTURE), older than the implausible-age bound (decode/anchor arithmetic wrong), or the
        // frame's own self-reported age exceeds the absolute plausible ceiling. A rejected frame
        // leaves `latest` unchanged.
        let elapsed = Date().timeIntervalSince(date)
        guard elapsed > -GlucoseFreshness.futureSkewTolerance,
              elapsed < Self.implausibleAgeBound,
              msg.age <= Self.plausibleFrameAgeCeiling else {
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

    // C8: `.flat` is a *reported* steady slope (|rate| < 1 mg/dL/min) and keeps its arrow; `nil` means
    // the sensor gave no trend rate at all (`G7TrendDirection(rate: nil)`), so we report no arrow —
    // never a synthesized flat.
    private static func trend(_ d: G7TrendDirection?) -> GlucoseTrend? {
        switch d {
        case .downDownDown, .downDown: return .downDown
        case .down: return .down
        case .flat: return .flat
        case .up: return .up
        case .upUp, .upUpUp: return .upUp
        case nil: return nil
        }
    }
}

// CoreBluetooth delegate callbacks run on `queue: .main`, so `MainActor.assumeIsolated` hops into the
// main actor to touch our state — matching TandemBLE's `PumpBLEClient`.
extension DexcomG7BLESource: CBCentralManagerDelegate, CBPeripheralDelegate {
    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            guard central.state == .poweredOn else { status = .searching; notify(); return }
            // Re-adopt an already-connected G7 (e.g. after iOS relaunched us via state restoration)
            // rather than scanning for one that isn't advertising; otherwise scan. Deriving the list
            // inside the main-actor closure keeps non-Sendable CB values from crossing isolation.
            if let existing = central.retrieveConnectedPeripherals(
                withServices: [SensorServiceUUID.cgmService.cbUUID]).first {
                peripheral = existing
                existing.delegate = self
                central.connect(existing)
            } else {
                central.scanForPeripherals(withServices: [SensorServiceUUID.advertisement.cbUUID])
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
                ingest(glucoseFrame: data)
            case CGMServiceCharacteristicUUID.backfill.cbUUID:
                ingest(backfillFrame: data)
            default:
                break
            }
        }
    }
}
