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
/// no cloud. Its own `CBCentralManager` keeps it isolated from the pump.
///
/// EXPERIMENTAL / unreliable: unlike the G7 (a true broadcaster), a G5/G6 delivers glucose only
/// inside an *authenticated* session, and allows a limited number of BLE connections, so a passive
/// third central often receives nothing or is refused outright. Prefer Dexcom Share (cloud) or the
/// xDrip4iOS App Group as a robust failover; this source is best-effort.
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

    /// D-06: the ONE stable restore identifier used by the production instance
    /// (`GlucoseSourceRegistry.makeSelected()`). Textually stable — a literal, never a timestamp/UUID
    /// — so it survives relaunches unchanged (a requirement of CoreBluetooth state restoration).
    static let productionRestoreIdentifier = "com.fabolus.cgm.dexcom-g6-ble"

    /// Set at construction (nil for the ephemeral `CgmCredentialsView` "Test" instance,
    /// `productionRestoreIdentifier` for the one production instance — see `GlucoseSourceRegistry`).
    /// CoreBluetooth SIGABRTs (`-[CBCentralManager initWithDelegate:queue:options:]`) when the SAME
    /// restore-identifier string is used by more than one live manager in the process, which is
    /// exactly what happened when both the launch-selected source and the "test failover" button
    /// built a G6 source with the same hardcoded identifier (D-06). Scoping it to the production
    /// instance only — and reattaching via `willRestoreState` below — restores background failover
    /// without reintroducing that crash.
    private let restoreIdentifier: String?

    init(restoreIdentifier: String? = nil) {
        self.restoreIdentifier = restoreIdentifier
        super.init()
    }

    /// Read-only accessor for the construction-time restore-identifier scoping test (D-06) — no live
    /// `CBCentralManager` required.
    var restoreIdentifierForTesting: String? { restoreIdentifier }

    /// Sensor clock → wall clock anchor (D-08a). Set/refreshed whenever a `transmitterTimeRx`
    /// (opcode 0x25) is passively observed: `activationDate = now - currentTime`. A glucose frame's
    /// sensor-relative `timestamp` then converts via `activationDate.addingTimeInterval(timestamp)` —
    /// this is CGMBLEKit's own proven technique (ported per the RESEARCH re-check), not a per-message
    /// receipt-`Date()` stamp, which would read a delayed/batched frame as artificially fresh.
    ///
    /// **09.20-02 Task-1 sign-off (`reject-and-stable`, owner-authorized):** this anchor is held
    /// STABLE per-connection — refreshed ONLY on a fresh `transmitterTimeRx`, NOT reset on every
    /// glucose message the way `DexcomG7BLESource.handleGlucose` does. Confirmed as the deliberate,
    /// permanent design (was provisional in Plan 01); recorded as an UNVERIFIED-GUESS pending D-13
    /// on-device confirmation (`docs/UNVERIFIED-GUESSES.md` #9).
    private var activationDate: Date?

    /// Wall time this source began actively listening (set once, in `start()`) — backs the no-anchor
    /// bound below. A test drives `ingest(controlFrame:)` directly without ever calling `start()`
    /// (mirrors this file's own `ingest` test seam), so `setConnectedAtForTesting` lets it simulate
    /// "connected for N minutes with no anchor ever observed".
    private var connectedAt: Date?

    /// Beyond this many seconds of age, an anchored date is decode/anchor-arithmetic-wrong, not a
    /// genuinely old-but-real reading — ordinary staleness is `GlucoseFreshness`'s job (D-07, reused
    /// here, not duplicated). Deliberately generous (24h) so it never fires on real staleness; it only
    /// catches wildly wrong anchor math.
    static let implausibleAgeBound: TimeInterval = 24 * 3600

    /// No-anchor bound (Warning 1) — owner-adjustable, mirrors `GlucoseFreshness.staleAfter`'s
    /// `static var` pattern rather than a literal buried in `handle()`. UNVERIFIED-GUESS: the
    /// `transmitterTimeRx` (0x25) wire cadence was never established by the RESEARCH; default
    /// ≈10 min = 2 assumed wake cycles (`docs/UNVERIFIED-GUESSES.md` #10). Beyond this, with STILL no
    /// anchor ever observed, the source reports `.stale` rather than trusting any fallback-dated frame.
    static var noAnchorBound: TimeInterval = 10 * 60

    /// Optional Dexcom transmitter ID (6 chars). Used only to pick the right transmitter by its
    /// advertised name suffix when several Dexcom sensors are in range; passive reads need no auth.
    private var transmitterID: String { (GlucoseSourceConfig.string("dexcomg6.transmitterId") ?? "").uppercased() }

    func start() async {
        guard central == nil else { return }
        status = .searching
        connectedAt = Date()
        // D-06: pass CBCentralManagerOptionRestoreIdentifierKey ONLY when this instance was built
        // with a restore identifier (the production instance — see `GlucoseSourceRegistry`). The
        // ephemeral "Test" instance is built with `restoreIdentifier == nil` and gets no options at
        // all, so the two never share a restore-identifier string (the SIGABRT this used to hit).
        // Background relaunch then reattaches via `centralManager(_:willRestoreState:)` below, so the
        // production instance re-arms for overnight failover instead of losing state restoration
        // entirely.
        var options: [String: Any]?
        if let restoreIdentifier {
            options = [CBCentralManagerOptionRestoreIdentifierKey: restoreIdentifier]
        }
        central = CBCentralManager(delegate: self, queue: .main, options: options)
    }

    func stop() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        central?.stopScan()
        peripheral = nil
        status = .idle
        onChange?()
    }

    /// Decodes a raw control-characteristic frame and routes it by opcode: a `transmitterTimeRx`
    /// (0x25) refreshes the sensor-time anchor; a glucose frame (0x31/0x4f) is decoded and handled.
    /// Internal + MainActor so tests can drive the decode path directly, without CoreBluetooth. The
    /// CB delegate (`peripheral(_:didUpdateValueFor:)`) is a thin wrapper over this.
    func ingest(controlFrame data: Data) {
        guard !data.isEmpty else { return }
        if data.starts(with: .transmitterTimeRx) {
            // A corrupt/wrong-opcode time frame fails to decode and simply doesn't refresh the
            // anchor — it must NOT fall through to a `GlucoseRxMessage` attempt (opcode mismatch
            // would reject it anyway, but this keeps the routing explicit).
            if let time = TransmitterTimeRxMessage(data: data) {
                activationDate = Date(timeIntervalSinceNow: -TimeInterval(time.currentTime))
            }
            return
        }
        guard let msg = GlucoseRxMessage(data: data) else { return }
        handle(msg)
    }

    private func handle(_ msg: GlucoseRxMessage) {
        // D-08b physiologic-range gate (decode-time, Task-1 sign-off `reject-and-stable`): a
        // CRC-valid-but-out-of-[40,400]-or-unreliable frame is REJECTED, never clamped, and never
        // becomes `latest`.
        guard msg.hasPlausibleGlucose else { status = .connected; onChange?(); return }
        guard let activationDate else {
            // FAIL-CLOSED pre-anchor (D-08a/D-10, Warning 1 — finalized here): no sensor-time anchor
            // has ever been observed, so this frame's true age is unknowable. Do NOT fall back to
            // stamping `Date()` at receipt (that IS the hazard D-08a eliminates) and do NOT publish it
            // as `latest` — the trusted bolus-calc input. A run of un-anchored frames never accumulates
            // into a trusted reading (there is nothing here that could accumulate: this branch only
            // ever leaves `latest` untouched). Once the source has been listening longer than
            // `noAnchorBound` with STILL no anchor observed, flip to `.stale` so the UI stops implying
            // "still trying" forever; below the bound, stay `.connected` (matches Plan 01's behavior).
            if let connectedAt, Date().timeIntervalSince(connectedAt) > Self.noAnchorBound {
                status = .stale
            } else {
                status = .connected
            }
            onChange?()
            return
        }
        let date = activationDate.addingTimeInterval(TimeInterval(msg.glucose.timestamp))

        // Implausible-age rejection (D-08a): more than `futureSkewTolerance` in the future, or more
        // than `implausibleAgeBound` in the past, means decode/anchor arithmetic went wrong — not a
        // genuinely old-but-real reading (ordinary staleness stays GlucoseFreshness's job, D-07, not
        // duplicated here). Reject; `latest` stays unchanged.
        let elapsed = Date().timeIntervalSince(date)
        guard elapsed > -GlucoseFreshness.futureSkewTolerance, elapsed < Self.implausibleAgeBound else {
            status = .connected
            onChange?()
            return
        }

        // NOTE (09.20-02, owner review): a rate-of-change (Δmg/dL ÷ Δt) rejection gate was implemented
        // here and then REMOVED — no respected reference implementation rejects a CGM reading by
        // rate-of-change (CGMBLEKit gates only on CRC + hasReliableGlucose + range; Loop's rate-of-
        // change use is limited to Missed Meal Detection + trend display, never a rejection gate;
        // xDrip4iOS's `maxSlopeInMinutes` is graph-slope windowing, not a rejection gate). It was
        // ungrounded and risked rejecting a genuine fast excursion, failing over to pump-only when the
        // failover reading was in fact the more correct one. Delayed/batched frames are still caught by
        // the implausible-age gate above and by the existing GlucoseFreshness/CalcInputFreshness
        // staleness policy downstream (D-07) — not duplicated here.

        let sample = GlucoseSample(mgdl: msg.glucoseMgdl, date: date,
                                   trend: Self.trend(msg.trendDirection), sourceID: id)
        latest = sample
        var byBucket: [Int: GlucoseReading] = [:]
        for r in history + [sample.reading] { byBucket[Int(r.date.timeIntervalSince1970 / 300)] = r }
        let cutoff = Date().addingTimeInterval(-24 * 3600)
        history = byBucket.values.filter { $0.date >= cutoff }.sorted { $0.date < $1.date }
        status = .connected
        onChange?()
    }

    /// Test seam: overrides `connectedAt` directly, mirroring `TandemBackend`'s `set...ForTesting`
    /// pattern — lets a test simulate "connected for N minutes with no anchor ever observed" without a
    /// real timer.
    func setConnectedAtForTesting(_ date: Date) { connectedAt = date }

    // C8: `.flat` is a *reported* steady slope (|rate| < 1 mg/dL/min) and keeps its arrow; `nil` means
    // the transmitter sent the "unavailable" sentinel (0x7f) so `trendRateMgDlPerMin` is nil — no
    // trend reported, so we report no arrow, never a synthesized flat.
    private static func trend(_ d: G6TrendDirection?) -> GlucoseTrend? {
        switch d {
        case .downDownDown, .downDown: return .downDown
        case .down: return .down
        case .flat: return .flat
        case .up: return .up
        case .upUp, .upUpUp: return .upUp
        case nil: return nil
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
    /// D-06 completion: background relaunch reattachment, mirroring `faBolusCore/BLELink.swift`'s
    /// central-role `willRestoreState` — reattach the delegate on the restored peripheral (and
    /// re-issue `connect` if CoreBluetooth hasn't already re-established the link) so the production
    /// instance re-arms without waiting for a fresh scan. Only ever fires for the production instance
    /// (the Test instance is built with no restore identifier, so CoreBluetooth never restores state
    /// for it). Never touches the auth/control characteristics — read-only, same as every other path
    /// in this source (D-12a).
    nonisolated func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        // Pull the restored peripheral out here, same as `didDiscover`'s `advName` extraction above:
        // the non-Sendable `[String: Any]` dict itself must not cross into the main-actor closure.
        // `nonisolated(unsafe)` (an existing pattern in this codebase, e.g. `BolusPasscode.swift`) is
        // safe here: CoreBluetooth invokes this delegate callback on `queue: .main` (see `start()`),
        // so there is no actual concurrent access — only the strict-concurrency checker's Sendable
        // requirement on `[CBPeripheral]` (unmet because `CBPeripheral` predates Sendable) to satisfy.
        nonisolated(unsafe) let restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]
        MainActor.assumeIsolated {
            guard let restored = restoredPeripherals?.first else { return }
            peripheral = restored
            restored.delegate = self
            if restored.state != .connected { central.connect(restored) }
        }
    }

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
        let reason = error?.localizedDescription
        MainActor.assumeIsolated {
            self.peripheral = nil
            // Surface a real error instead of failing silently: a G6/G5 typically only talks to its
            // authenticated master (the Dexcom app), and allows a limited number of BLE connections,
            // so a passive third central is often refused. Keep retrying in case it frees up.
            status = .error(reason.map { "couldn't connect: \($0)" }
                            ?? "couldn't connect — the Dexcom app may hold the sensor's only session")
            onChange?()
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
                  characteristic.uuid == CGMServiceCharacteristicUUID.control.cbUUID else { return }
            ingest(controlFrame: data)
        }
    }
}
