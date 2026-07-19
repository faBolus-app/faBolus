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

    /// Pump time epoch is 2008-01-01 UTC.
    private static let pumpEpoch: TimeInterval = 1_199_145_600
    private static let food2 = 8   // manual units-only bolus type

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
        guard units <= Interlocks.maxBolusUnits else { throw BolusError.exceedsMax(Interlocks.maxBolusUnits) }
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

    // MARK: - Helpers

    private func pollStatus() {
        for r: Message in [ControlIQIOBRequest(), InsulinStatusRequest(), CurrentBatteryV2Request(),
                           CurrentEgvGuiDataV2Request(), CurrentBasalStatusRequest(),
                           LastBolusStatusV2Request(), BolusCalcDataSnapshotRequest()] {
            try? client.send(r)
        }
    }

    private func startPolling() {
        pollStatus()
        pollTimer?.invalidate()
        pollTimer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { _ in
            MainActor.assumeIsolated { self.pollStatus() }
        }
    }
}

// PumpBLEClientDelegate is @MainActor; PumpBLEClient delivers all callbacks on the main actor.
extension LivePumpDataSource: PumpBLEClientDelegate {
    public func pumpClient(_ c: PumpBLEClient, didChange state: PumpBLEClient.State) {
        switch state {
        case .scanning: snapshot.connection = .scanning
        case .connecting, .discovering: snapshot.connection = .connecting
        case .ready: snapshot.connection = .connected
        case .disconnected, .idle: snapshot.connection = .disconnected
        default: break
        }
        onChange?()
    }

    public func pumpClient(_ c: PumpBLEClient, didDiscover peripheral: CBPeripheral, rssi: Int) {
        c.connect(peripheral)
    }

    public func pumpClientDidBecomeReady(_ c: PumpBLEClient) {
        guard !pairingCode.isEmpty, let coord = try? PairingCoordinator(pairingCode: pairingCode) else {
            startPolling(); return
        }
        coord.onSendRequest = { msg in try? c.send(msg) }   // AUTHORIZATION passes the interlock
        coord.onPaired = { [weak self] key, _ in
            self?.authenticationKey = key
            self?.startPolling()
        }
        coordinator = coord
        coord.start()
    }

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
                glucoseHistory.append(GlucoseReading(date: Date(), mgdl: m.cgmReading))
                if glucoseHistory.count > 72 { glucoseHistory.removeFirst() }
            }
        case let m as LastBolusStatusV2Response:
            snapshot.lastBolusUnits = m.deliveredUnits
            snapshot.lastBolusDate = Date(timeIntervalSince1970: Self.pumpEpoch + Double(m.timestamp))
        case let m as BolusCalcDataSnapshotResponse: calcSnapshot = m
        case let m as TimeSinceResetResponse: timeCont?.resume(returning: m); timeCont = nil
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
