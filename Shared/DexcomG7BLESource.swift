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
    let connectionKind: GlucoseConnectionKind = .localBLE   // D-06
    private(set) var latest: GlucoseSample?
    private(set) var history: [GlucoseReading] = []
    private(set) var status: GlucoseSourceStatus = .idle
    var onChange: (@MainActor () -> Void)?

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?

    /// D-08: the ONE stable restore identifier used by the production instance
    /// (`GlucoseSourceRegistry.makeSelected()`). Textually stable — a literal, never a timestamp/UUID —
    /// so it survives relaunches unchanged (a requirement of CoreBluetooth state restoration).
    /// DISTINCT from every other restore id in the process: pump `com.fabolus.app.pump`, watch
    /// `com.fabolus.app.watch.pump`, BLELink `com.fabolus.ble.central`, G6
    /// `com.fabolus.cgm.dexcom-g6-ble` — no collision.
    static let productionRestoreIdentifier = "com.fabolus.cgm.dexcom-g7-ble"

    /// Set at construction (nil for the ephemeral `CgmCredentialsView` "Test" instance,
    /// `productionRestoreIdentifier` for the one production instance — see `GlucoseSourceRegistry`).
    /// CoreBluetooth SIGABRTs when the SAME restore-identifier string is used by more than one live
    /// manager in the process, so scoping it to the production instance only — and reattaching via
    /// `willRestoreState` below — restores background failover without reintroducing that crash (the
    /// same constraint `DexcomG6BLESource` solved, D-08).
    private let restoreIdentifier: String?

    init(restoreIdentifier: String? = nil) {
        self.restoreIdentifier = restoreIdentifier
        super.init()
    }

    /// Read-only accessor for the construction-time restore-identifier scoping test (D-08) — no live
    /// `CBCentralManager` required.
    var restoreIdentifierForTesting: String? { restoreIdentifier }

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
        // D-08: pass CBCentralManagerOptionRestoreIdentifierKey ONLY when this instance was built with
        // a restore identifier (the production instance — see `GlucoseSourceRegistry`). The ephemeral
        // "Test" instance is built with `restoreIdentifier == nil` and gets no options at all, so the
        // two never share a restore-identifier string (the SIGABRT G6 also solved). Background relaunch
        // then reattaches via `centralManager(_:willRestoreState:)` below, so the production instance
        // re-arms for overnight failover parity with G6 instead of getting no relaunch at all.
        var options: [String: Any]?
        if let restoreIdentifier {
            options = [CBCentralManagerOptionRestoreIdentifierKey: restoreIdentifier]
        }
        central = CBCentralManager(delegate: self, queue: .main, options: options)
    }

    func stop() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        central?.stopScan()
        // W-02 (D-14): reset the source-internal connection state to its pre-start baseline so a
        // later start() re-arms instead of being a permanent no-op (start() guards on `central == nil`).
        // Confined to lifecycle state — nil the central + peripheral, clear the sensor-time anchor
        // (so a fresh connection re-bootstraps it per D-02) and any pending backfill. Decode/anchor/gate
        // behavior is otherwise unchanged; `latest`/`history` are left as the last-known cached values.
        central = nil
        peripheral = nil
        anchorMessageTimestamp = nil
        anchorReceivedAt = nil
        pendingBackfill = []
        status = .idle
        notify()
    }

    private func notify() { onChange?() }

    /// Read-only lifecycle-state accessors for the W-02 stop()/re-arm test (D-14). `isArmedForTesting`
    /// reflects whether a live central exists (set by `start()`); `anchorIsSetForTesting` reflects the
    /// sensor-time anchor — both must reset on `stop()` so a later `start()` is not a permanent no-op.
    var isArmedForTesting: Bool { central != nil }
    var anchorIsSetForTesting: Bool { anchorMessageTimestamp != nil || anchorReceivedAt != nil }

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
        // D-03: require reliability AND physiologic range FIRST, before any anchor math — an unreliable,
        // absent, or out-of-[40,400] glucose frame never anchors or publishes (decode-time reject,
        // defense-in-depth alongside the GlucoseSample construction gate below).
        guard let mgdl = msg.glucose, msg.hasPlausibleGlucose else {
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
        // D-05 construction gate (belt-and-suspenders with the decode gate above): route through the
        // failable GlucoseSample, and derive history from that SAME gated sample's `.reading` — never a
        // raw GlucoseReading(...) from the decoded value (Pitfall 1).
        guard let sample = GlucoseSample(mgdl: Int(mgdl), date: date,
                                         trend: Self.trend(msg.trendDirection), sourceID: id) else {
            status = .connected
            notify()
            return
        }
        latest = sample
        merge([sample.reading])
        drainPendingBackfill()
        status = .connected
        notify()
    }

    private func handleBackfill(_ msg: G7BackfillMessage) {
        // D-03/Pitfall 1: gate the history/backfill path on the SAME decode-time range check, and derive
        // the charted reading from a gated GlucoseSample's `.reading` — never a raw GlucoseReading(...)
        // from the decoded value, so backfilled chart history is gated exactly like `latest`.
        guard let mgdl = msg.glucose, msg.hasPlausibleGlucose else { return }
        if let date = wallTime(forSensor: msg.timestamp) {
            guard let sample = GlucoseSample(mgdl: Int(mgdl), date: date, sourceID: id) else { return }
            merge([sample.reading])
            notify()
        } else {
            pendingBackfill.append(msg)   // no wall anchor yet; convert once a live message lands
        }
    }

    private func drainPendingBackfill() {
        guard !pendingBackfill.isEmpty else { return }
        let readings = pendingBackfill.compactMap { m -> GlucoseReading? in
            guard let g = m.glucose, m.hasPlausibleGlucose, let d = wallTime(forSensor: m.timestamp),
                  let sample = GlucoseSample(mgdl: Int(g), date: d, sourceID: id)
            else { return nil }
            return sample.reading
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
    /// D-08 completion: background relaunch reattachment, mirroring `DexcomG6BLESource`'s
    /// `willRestoreState` — reattach the delegate on the restored peripheral (and re-issue `connect`
    /// if CoreBluetooth hasn't already re-established the link) so the production instance re-arms
    /// without waiting for a fresh scan. Only ever fires for the production instance (the Test instance
    /// is built with no restore identifier, so CoreBluetooth never restores state for it). Never
    /// touches the auth/control characteristics — read-only, same as every other path here (D-12a).
    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // Pull the restored peripheral out here, same as `didDiscover`'s `advName` extraction: the
        // non-Sendable `[String: Any]` dict itself must not cross into the main-actor closure.
        // `nonisolated(unsafe)` is safe here — CoreBluetooth invokes this delegate on `queue: .main`
        // (see `start()`), so there is no actual concurrent access, only the strict-concurrency
        // checker's Sendable requirement on `[CBPeripheral]` (unmet because `CBPeripheral` predates
        // Sendable) to satisfy (same pattern as `DexcomG6BLESource`).
        nonisolated(unsafe) let restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]
        MainActor.assumeIsolated {
            guard let restored = restoredPeripherals?.first else { return }
            peripheral = restored
            restored.delegate = self
            if restored.state == .connected {
                // Force fresh discovery ourselves (mirror G6's H-01 fix): a relaunched process has a
                // brand-new source instance with no in-memory record of previously-discovered
                // characteristics or notify subscriptions — CoreBluetooth's restoration covers the
                // peripheral object + raw link state, not this fresh delegate's own subscriptions.
                // Passive read-only (D-12a): only discoverServices → discoverCharacteristics →
                // setNotifyValue follow from this, never a characteristic write.
                restored.discoverServices([SensorServiceUUID.cgmService.cbUUID])
            } else {
                central.connect(restored)
            }
        }
    }

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
