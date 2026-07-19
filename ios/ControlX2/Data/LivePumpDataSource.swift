import Foundation
import CoreBluetooth
import PumpX2Messages
import PumpX2Auth
import PumpX2BLE

/// Real pump data source over `PumpX2Kit`'s Core Bluetooth transport: scan → connect → JPAKE
/// pair → poll status; and a signed bolus flow (permission → initiate → status) matching the
/// bench harness that's validated on hardware. Read-only by default; `deliverBolus` briefly
/// raises the write policy to `.allowDelivery` for the signed sequence only.
///
/// Runs on a physical device only (the Simulator has no Bluetooth).
@MainActor
public final class LivePumpDataSource: NSObject, PumpDataSource {
    public private(set) var snapshot = PumpSnapshot()
    public private(set) var glucoseHistory: [GlucoseReading] = []
    public var onChange: (@MainActor () -> Void)?

    private let client = PumpBLEClient()
    private var coordinator: PairingCoordinator?
    private var pollTimer: Timer?

    /// 6-digit JPAKE pairing code (from the pump screen). Set before `connect()`.
    public var pairingCode: String = ""
    private var authenticationKey: [UInt8] = []
    private var signingTimestamp: UInt32 = 0
    private var currentBolusId: Int = 0
    private var isPaired: Bool { !authenticationKey.isEmpty }

    /// Latest bolus-calculator settings (carb ratio / ISF / target) for recommendBolus.
    private var calcSnapshot: BolusCalcDataSnapshotResponse?

    private static let food2 = 8   // manual units-only bolus type
    /// Anchor mapping the pump's clock to the phone's, so pump timestamps convert correctly
    /// regardless of the pump's timezone/epoch. Refreshed from TimeSinceReset.
    private var pumpTimeAnchor: (pump: UInt32, phone: Date)?

    // One-shot CGM history backfill (fills the chart gaps left when the app was disconnected).
    // Re-runs on each connect. `backfillRemaining` counts down all record types the pump streams,
    // not just CGM; readings are buffered until the stream ends, then aligned to the live axis.
    private var didBackfill = false
    private var backfillRemaining = 0
    private var backfillBuffer: [(pumpSec: UInt32, mgdl: Int)] = []
    /// Cap on records requested per connect. numberOfLogs is a single byte, so ≤255; the recent
    /// window is plenty to fill short disconnect gaps.
    private static let backfillRecords = 255

    // Continuations bridging the delegate callbacks to async/await for the signed flow.
    private var timeCont: CheckedContinuation<TimeSinceResetResponse, Error>?
    private var permissionCont: CheckedContinuation<BolusPermissionResponse, Error>?
    private var initiateCont: CheckedContinuation<InitiateBolusResponse, Error>?

    public var writePolicy: PumpBLEClient.WritePolicy {
        get { client.writePolicy } set { client.writePolicy = newValue }
    }

    public override init() {
        super.init()
        client.writePolicy = .readOnly
        client.delegate = self
    }

    // MARK: - PumpDataSource

    public func connect() async {
        snapshot.connection = .scanning; onChange?()
        client.startScan()
    }

    public func disconnect() {
        pollTimer?.invalidate(); pollTimer = nil
        client.disconnect()
    }

    public func recommendBolus(carbsGrams: Double, bgMgdl: Int?) async -> BolusRecommendation {
        var rec = BolusRecommendation()
        rec.carbsGrams = carbsGrams; rec.bgMgdl = bgMgdl; rec.iobUnits = snapshot.iobUnits
        if let s = calcSnapshot, s.carbRatio > 0 {
            let food = carbsGrams / s.carbRatioGramsPerUnit
            let correction = (bgMgdl != nil && s.isf > 0)
                ? max(0, Double(bgMgdl! - s.targetBg) / Double(s.isf) - snapshot.iobUnits) : 0
            rec.recommendedUnits = max(0, food + correction)
        } else {
            rec.recommendedUnits = max(0, carbsGrams / 10.0 - snapshot.iobUnits)
        }
        rec.recommendedUnits = (rec.recommendedUnits * 20).rounded() / 20   // 0.05 u steps
        return rec
    }

    /// Delivers a units-only (FOOD2) bolus via the validated signed path. Raises the write
    /// policy to `.allowDelivery` only for this call.
    public func deliverBolus(units: Double) async throws -> Double {
        guard snapshot.connection == .connected || snapshot.connection == .bolusing else { throw BolusError.notConnected }
        guard isPaired else { throw BolusError.pumpRejected("not paired") }
        guard units <= snapshot.maxBolusUnits, units <= Interlocks.absoluteMaxUnits else {
            throw BolusError.exceedsMax(min(snapshot.maxBolusUnits, Interlocks.absoluteMaxUnits))
        }
        let mu = UInt32((units * 1000).rounded())
        guard mu >= 50 else { throw BolusError.pumpRejected("below 0.05 u") }

        // Fresh signing timestamp (the pump validates the HMAC against its clock).
        let time: TimeSinceResetResponse = try await withCheckedThrowingContinuation { cont in
            timeCont = cont
            do { try client.send(TimeSinceResetRequest()) } catch { timeCont = nil; cont.resume(throwing: error) }
        }
        signingTimestamp = time.currentTime

        let previousPolicy = client.writePolicy
        client.writePolicy = .allowDelivery
        defer { client.writePolicy = previousPolicy }
        snapshot.connection = .bolusing; onChange?()

        let perm: BolusPermissionResponse = try await withCheckedThrowingContinuation { cont in
            permissionCont = cont
            do {
                try client.send(BolusPermissionRequest(), authenticationKey: authenticationKey,
                                pumpTimeSinceReset: signingTimestamp)
            } catch { permissionCont = nil; cont.resume(throwing: error) }
        }
        guard perm.granted else {
            snapshot.connection = .connected; onChange?()
            throw BolusError.pumpRejected("permission not granted (nack \(perm.nackReasonId))")
        }
        currentBolusId = perm.bolusId

        let ini: InitiateBolusResponse = try await withCheckedThrowingContinuation { cont in
            initiateCont = cont
            do {
                try client.send(
                    InitiateBolusRequest(totalVolume: mu, bolusID: perm.bolusId, bolusTypeBitmask: Self.food2),
                    authenticationKey: authenticationKey, pumpTimeSinceReset: signingTimestamp,
                    allowInsulinDelivery: true)
            } catch { initiateCont = nil; cont.resume(throwing: error) }
        }
        guard ini.accepted else {
            snapshot.connection = .connected; onChange?()
            throw BolusError.pumpRejected("initiate not accepted (status \(ini.status))")
        }

        snapshot.connection = .connected
        snapshot.lastBolusUnits = units
        snapshot.lastBolusDate = Date()
        snapshot.iobUnits += units
        onChange?()
        return units
    }

    public func cancelBolus() async {
        guard currentBolusId != 0 else { return }
        let previous = client.writePolicy
        client.writePolicy = .allowDelivery
        _ = try? client.send(CancelBolusRequest(bolusId: currentBolusId),
                             authenticationKey: authenticationKey, pumpTimeSinceReset: signingTimestamp)
        client.writePolicy = previous
        snapshot.connection = .connected; onChange?()
    }

    // MARK: - Helpers (tiered polling to spare phone + pump battery)

    private var pollTick = 0

    /// Fast-changing state (~60 s): IOB, glucose, reservoir, last bolus, battery.
    private func fastRead() {
        for r: Message in [ControlIQIOBRequest(), CurrentEgvGuiDataV2Request(),
                           InsulinStatusRequest(), LastBolusStatusV2Request(), CurrentBatteryV2Request()] {
            try? client.send(r)
        }
    }

    /// Slow/static settings (once per connect + every ~10 min): basal, calculator snapshot
    /// (carb ratio/ISF/target/max), and the pump-clock anchor.
    private func staticRead() {
        for r: Message in [CurrentBasalStatusRequest(), BolusCalcDataSnapshotRequest(), TimeSinceResetRequest()] {
            try? client.send(r)
        }
    }

    private func startPolling() {
        fastRead(); staticRead()
        pollTick = 0
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                self.fastRead()
                self.pollTick += 1
                if self.pollTick % 10 == 0 { self.staticRead() }   // refresh settings every ~10 min
            }
        }
    }

    /// Merge the buffered CGM history into the chart. Aligns the newest backfilled reading to
    /// ~now and spaces the rest by their true pump-clock deltas — robust to any pump
    /// timezone/epoch offset, and consistent with the live (`Date()`-stamped) readings.
    private func finalizeBackfill() {
        backfillRemaining = 0
        defer { backfillBuffer.removeAll(keepingCapacity: false) }
        guard let newest = backfillBuffer.map({ $0.pumpSec }).max() else { return }
        let now = Date()
        var merged = glucoseHistory
        for b in backfillBuffer {
            let date = now.addingTimeInterval(-Double(newest - b.pumpSec))
            merged.append(GlucoseReading(date: date, mgdl: b.mgdl))
        }
        merged.sort { $0.date < $1.date }
        // Drop near-duplicates: same value within ~150 s of the previously kept reading.
        var deduped: [GlucoseReading] = []
        for r in merged {
            if let last = deduped.last, last.mgdl == r.mgdl,
               r.date.timeIntervalSince(last.date) < 150 { continue }
            deduped.append(r)
        }
        if deduped.count > 288 { deduped.removeFirst(deduped.count - 288) }
        glucoseHistory = deduped
        onChange?()
    }
}

// PumpBLEClientDelegate is @MainActor; PumpBLEClient delivers all callbacks on the main actor.
extension LivePumpDataSource: PumpBLEClientDelegate {
    public func pumpClient(_ c: PumpBLEClient, didChange state: PumpBLEClient.State) {
        switch state {
        case .scanning: snapshot.connection = .scanning
        case .connecting, .discovering: snapshot.connection = .connecting
        case .ready: snapshot.connection = .connected
        case .disconnected, .idle:
            snapshot.connection = .disconnected
            // Re-backfill on the next connect so the gap from this disconnect gets filled.
            didBackfill = false; backfillRemaining = 0; backfillBuffer.removeAll()
        default: break
        }
        onChange?()
    }

    public func pumpClient(_ c: PumpBLEClient, didDiscover peripheral: CBPeripheral, rssi: Int) {
        c.connect(peripheral)
    }

    public func pumpClientDidBecomeReady(_ c: PumpBLEClient) {
        // Prefer resume (no code) when a prior pairing is saved; else full pair with the code.
        let coord: PairingCoordinator
        let isFullPairing: Bool
        if pairingCode.isEmpty, let stored = PairingStore.load() {
            coord = PairingCoordinator(resumeDerivedSecret: stored); isFullPairing = false
        } else if let full = try? PairingCoordinator(pairingCode: pairingCode), !pairingCode.isEmpty {
            coord = full; isFullPairing = true
        } else {
            startPolling(); return   // no code and no saved pairing — reads will be rejected
        }
        coord.onSendRequest = { msg in try? c.send(msg) }   // AUTHORIZATION passes the interlock
        coord.onError = { [weak self] _ in
            // Resume can fail if the pump forgot us; drop the saved secret so the UI re-pairs.
            if !isFullPairing { PairingStore.clear() }
            self?.snapshot.connection = .error; self?.onChange?()
        }
        coord.onPaired = { [weak self] key, _ in
            self?.authenticationKey = key
            if isFullPairing {
                PairingStore.save(coord.derivedSecret)   // enable future quick-pair
                self?.pairingCode = ""                    // subsequent connects resume
            }
            self?.startPolling()
        }
        coordinator = coord
        coord.start()
    }

    public var hasStoredPairing: Bool { PairingStore.load() != nil }
    public func forgetPairing() { PairingStore.clear(); authenticationKey = [] }

    public func pumpClient(_ c: PumpBLEClient, didReceiveFrame frame: [UInt8], on ch: Characteristic) {
        if ch == .authorization { coordinator?.handle(frame: frame); return }
        guard let parsed = try? ResponseParser.parse(frame: frame) else { return }
        switch parsed.message {
        case let m as ControlIQIOBResponse: snapshot.iobUnits = m.iobUnits
        case let m as InsulinStatusResponse: snapshot.reservoirUnits = Double(m.currentInsulinAmount)
        case let m as CurrentBatteryV2Response: snapshot.batteryPercent = m.batteryPercent
        case let m as CurrentEgvGuiDataV2Response:
            snapshot.cgmActive = m.hasValidReading
            snapshot.trend = m.trendArrow
            if m.hasValidReading {
                snapshot.glucose = m.cgmReading
                // De-dup: only append when the reading changes (CGM updates every ~5 min).
                if glucoseHistory.last?.mgdl != m.cgmReading {
                    glucoseHistory.append(GlucoseReading(date: Date(), mgdl: m.cgmReading))
                    if glucoseHistory.count > 288 { glucoseHistory.removeFirst() }  // ~24h @ 5-min
                }
            }
        case let m as LastBolusStatusV2Response:
            snapshot.lastBolusUnits = m.deliveredUnits
            // Convert the pump timestamp using the pump↔phone clock anchor (timezone-agnostic).
            if let a = pumpTimeAnchor {
                snapshot.lastBolusDate = a.phone.addingTimeInterval(Double(Int64(m.timestamp) - Int64(a.pump)))
            }
        case let m as BolusCalcDataSnapshotResponse:
            calcSnapshot = m
            if m.maxBolusAmount > 0 { snapshot.maxBolusUnits = Double(m.maxBolusAmount) / 1000.0 }
            snapshot.carbRatio = m.carbRatioGramsPerUnit
            snapshot.isf = m.isf
            snapshot.targetBg = m.targetBg
        case let m as TimeSinceResetResponse:
            pumpTimeAnchor = (m.currentTime, Date())
            timeCont?.resume(returning: m); timeCont = nil
            // Kick off the CGM history backfill once per connect (after we can talk to the pump).
            if !didBackfill { didBackfill = true; try? client.send(HistoryLogStatusRequest()) }
        case let m as HistoryLogStatusResponse:
            guard m.numEntries > 0, backfillRemaining == 0 else { break }
            let count = min(UInt32(Self.backfillRecords), m.numEntries)
            let startLog = m.lastSequenceNum &- (count - 1)   // the most-recent `count` records
            backfillRemaining = Int(count)
            backfillBuffer.removeAll(keepingCapacity: true)
            try? client.send(HistoryLogRequest(startLog: startLog, numberOfLogs: Int(count)))
        case let m as HistoryLogStreamResponse:
            guard backfillRemaining > 0 else { break }
            for r in m.cgmReadings { backfillBuffer.append((r.pumpTimeSec, r.glucoseMgdl)) }
            backfillRemaining -= max(m.numberOfHistoryLogs, m.records.count)
            if backfillRemaining <= 0 { finalizeBackfill() }
        case let m as BolusPermissionResponse: permissionCont?.resume(returning: m); permissionCont = nil
        case let m as InitiateBolusResponse: initiateCont?.resume(returning: m); initiateCont = nil
        default: break
        }
        onChange?()
    }

    public func pumpClient(_ c: PumpBLEClient, didError error: Error) {
        snapshot.connection = .disconnected; onChange?()
    }
}
