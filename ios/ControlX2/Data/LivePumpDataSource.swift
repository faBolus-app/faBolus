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
    public private(set) var activeNotifications: [PumpNotification] = []
    public var onChange: (@MainActor () -> Void)?

    // Active notifications by kind (merged into `activeNotifications`, alarms first).
    private var alarmList: [PumpNotification] = []
    private var alertList: [PumpNotification] = []
    private var cgmAlertList: [PumpNotification] = []
    private func mergeNotifications() { activeNotifications = alarmList + alertList + cgmAlertList }

    // Restore identifier enables CoreBluetooth state restoration: iOS relaunches the app on pump
    // BLE events (with `bluetooth-central` background mode) and hands the connection back.
    private let client = PumpBLEClient(restoreIdentifier: "com.zgranowitz.controlx2.pump")
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

    // CGM history backfill: pages backward through the pump's history log (in 255-record pages)
    // until it has enough CGM readings to fill the chart, then merges them. Paging is driven by
    // a debounce timer (each page's stream ends when frames stop) rather than an exact record
    // count, because sequence numbers can be non-contiguous. Re-runs on each connect.
    private var didBackfill = false
    private var backfillActive = false
    private var backfillBuffer: [(pumpSec: UInt32, mgdl: Int)] = []
    private var backfillNextEnd: UInt32 = 0     // upper sequence number for the next page
    private var backfillFirstSeq: UInt32 = 0    // oldest available sequence number
    private var backfillPages = 0
    private var backfillTimer: Timer?
    private static let backfillPageSize = 255   // numberOfLogs is one byte
    private static let backfillMaxPages = 8     // safety cap (~2040 records)
    private static let backfillTargetReadings = 288  // ~24 h @ 5-min

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

    /// Clear a pump notification with a signed DismissNotificationRequest. It's a signed CONTROL
    /// message but does NOT modify insulin delivery, so it runs under `.allowNonDelivery`.
    public func dismissNotification(_ notification: PumpNotification) async {
        guard isPaired else { return }
        // Fresh signing timestamp for the HMAC.
        guard let time = try? await withCheckedThrowingContinuation({ (cont: CheckedContinuation<TimeSinceResetResponse, Error>) in
            timeCont = cont
            do { try client.send(TimeSinceResetRequest()) } catch { timeCont = nil; cont.resume(throwing: error) }
        }) else { return }
        signingTimestamp = time.currentTime

        let previous = client.writePolicy
        client.writePolicy = .allowNonDelivery
        defer { client.writePolicy = previous }
        _ = try? client.send(DismissNotificationRequest(kind: notification.kind, notificationId: notification.id),
                             authenticationKey: authenticationKey, pumpTimeSinceReset: signingTimestamp)
        // Optimistically drop it locally; the next fastRead confirms via the bitmap.
        alarmList.removeAll { $0.id == notification.id && $0.kind == notification.kind }
        alertList.removeAll { $0.id == notification.id && $0.kind == notification.kind }
        cgmAlertList.removeAll { $0.id == notification.id && $0.kind == notification.kind }
        mergeNotifications()
        onChange?()
    }

    // MARK: - Helpers (tiered polling to spare phone + pump battery)

    private var pollTick = 0

    /// Fast-changing state (~60 s): IOB, glucose, reservoir, last bolus, battery, alerts/alarms.
    private func fastRead() {
        for r: Message in [ControlIQIOBRequest(), CurrentEgvGuiDataV2Request(),
                           InsulinStatusRequest(), LastBolusStatusV2Request(), CurrentBatteryV2Request(),
                           AlertStatusRequest(), AlarmStatusRequest(), CGMAlertStatusRequest()] {
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

    /// Request one page of history (255 records) ending at `backfillNextEnd`, walking backward.
    private func requestBackfillPage() {
        guard backfillNextEnd >= backfillFirstSeq, backfillPages < Self.backfillMaxPages else {
            finishBackfill(); return
        }
        let available = backfillNextEnd - backfillFirstSeq + 1
        let count = min(UInt32(Self.backfillPageSize), available)
        guard count > 0 else { finishBackfill(); return }
        let startLog = backfillNextEnd - (count - 1)
        backfillPages += 1
        try? client.send(HistoryLogRequest(startLog: startLog, numberOfLogs: Int(count)))
        backfillNextEnd = startLog > 0 ? startLog - 1 : 0   // next (older) page
        scheduleBackfillTick()
    }

    /// Debounce: a page's stream has ended once ~1.5 s pass with no new frames.
    private func scheduleBackfillTick() {
        backfillTimer?.invalidate()
        backfillTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { _ in
            MainActor.assumeIsolated { self.backfillPageDone() }
        }
    }

    private func backfillPageDone() {
        // Keep paging backward until we have enough CGM readings or run out of history.
        if backfillBuffer.count < Self.backfillTargetReadings && backfillNextEnd >= backfillFirstSeq {
            requestBackfillPage()
        } else {
            finishBackfill()
        }
    }

    /// Merge the buffered CGM history into the chart. Aligns the newest backfilled reading to
    /// ~now and spaces the rest by their true pump-clock deltas — robust to any pump
    /// timezone/epoch offset, and consistent with the (correct) live `Date()`-stamped readings.
    private func finishBackfill() {
        backfillTimer?.invalidate(); backfillTimer = nil
        backfillActive = false
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
        // Reflect the newest reading + its age for staleness.
        if let last = deduped.last { snapshot.glucose = last.mgdl; snapshot.glucoseDate = last.date }
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
            didBackfill = false; backfillActive = false
            backfillTimer?.invalidate(); backfillTimer = nil; backfillBuffer.removeAll()
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
                let now = Date()
                snapshot.glucose = m.cgmReading
                snapshot.glucoseDate = now
                // Append on a value change OR every ~4.5 min, so a stable BG still advances the
                // plot to "now" (a value-only de-dup left the newest point drifting into the past).
                if let last = glucoseHistory.last {
                    if last.mgdl != m.cgmReading || now.timeIntervalSince(last.date) > 270 {
                        glucoseHistory.append(GlucoseReading(date: now, mgdl: m.cgmReading))
                    }
                } else {
                    glucoseHistory.append(GlucoseReading(date: now, mgdl: m.cgmReading))
                }
                if glucoseHistory.count > 288 { glucoseHistory.removeFirst() }
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
            guard !backfillActive, m.numEntries > 0 else { break }
            backfillActive = true
            backfillBuffer.removeAll(keepingCapacity: true)
            backfillFirstSeq = m.firstSequenceNum
            backfillNextEnd = m.lastSequenceNum
            backfillPages = 0
            requestBackfillPage()
        case let m as HistoryLogStreamResponse:
            guard backfillActive else { break }
            for r in m.cgmReadings { backfillBuffer.append((r.pumpTimeSec, r.glucoseMgdl)) }
            scheduleBackfillTick()   // debounce: page ends when frames stop arriving
        case let m as AlertStatusResponse: alertList = m.notifications; mergeNotifications()
        case let m as AlarmStatusResponse: alarmList = m.notifications; mergeNotifications()
        case let m as CGMAlertStatusResponse: cgmAlertList = m.notifications; mergeNotifications()
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
