import Foundation
import CoreBluetooth
import PumpX2Messages
import PumpX2Auth
import PumpX2BLE

/// Real pump data source over `PumpX2Kit`'s Core Bluetooth transport. On connect it polls the
/// status reads and maps parsed responses into the HUD snapshot.
///
/// NOT yet hardware-tested. The read path is wired end to end; the signed bolus path requires a
/// completed pairing (legacy or JPAKE) to supply `authenticationKey` + `pumpTimeSinceReset` —
/// pairing UI is a follow-on (see PumpX2Kit docs/OPEN_QUESTIONS.md). Until then `deliverBolus`
/// throws `notConnected` to fail safe.
@MainActor
public final class LivePumpDataSource: NSObject, PumpDataSource {
    public private(set) var snapshot = PumpSnapshot()
    public private(set) var glucoseHistory: [GlucoseReading] = []
    public var onChange: (@MainActor () -> Void)?

    private let client = PumpBLEClient()
    private var coordinator: PairingCoordinator?

    /// 6-digit JPAKE pairing code (from the pump screen). Set before `connect()`.
    public var pairingCode: String = ""
    /// Set once pairing completes; required to sign insulin-affecting commands.
    public var authenticationKey: [UInt8] = []
    public var pumpTimeSinceReset: UInt32 = 0
    private var isPaired: Bool { !authenticationKey.isEmpty }

    /// Read-only safety mode — mirrors `PumpBLEClient.readOnly`. Defaults ON: the app connects,
    /// pairs, and reads status but cannot write a bolus until writes are explicitly enabled.
    public var readOnly: Bool = true {
        didSet { client.readOnly = readOnly }
    }

    public override init() {
        super.init()
        client.readOnly = readOnly
        client.delegate = self
    }

    public func connect() async {
        snapshot.connection = .scanning; onChange?()
        client.startScan()
    }

    public func disconnect() { client.disconnect() }

    public func recommendBolus(carbsGrams: Double, bgMgdl: Int?) async -> BolusRecommendation {
        // TODO: drive the pump's bolus calculator (BolusCalcDataSnapshot) like controlX2.
        var rec = BolusRecommendation()
        rec.carbsGrams = carbsGrams; rec.bgMgdl = bgMgdl; rec.iobUnits = snapshot.iobUnits
        rec.recommendedUnits = max(0, carbsGrams / 10.0 - snapshot.iobUnits)
        return rec
    }

    public func deliverBolus(units: Double) async throws -> Double {
        guard snapshot.connection == .connected else { throw BolusError.notConnected }
        guard isPaired else { throw BolusError.pumpRejected("not paired") }
        guard units <= Interlocks.maxBolusUnits else { throw BolusError.exceedsMax(Interlocks.maxBolusUnits) }
        // Bolus flow: permission → (await BolusPermissionResponse.bolusId) → initiate. The
        // bolusId correlation across responses is wired once the connection state machine +
        // pairing land; structurally the signed sends go through PumpBLEClient.send(...).
        _ = try client.send(BolusPermissionRequest(),
                            authenticationKey: authenticationKey,
                            pumpTimeSinceReset: pumpTimeSinceReset,
                            allowInsulinDelivery: true)
        throw BolusError.pumpRejected("live bolus flow pending bench validation")
    }

    public func cancelBolus() async {
        if isPaired {
            _ = try? client.send(CancelBolusRequest(bolusId: 0),
                                 authenticationKey: authenticationKey,
                                 pumpTimeSinceReset: pumpTimeSinceReset,
                                 allowInsulinDelivery: true)
        }
    }

    /// Pump time epoch is 2008-01-01 UTC; convert pump seconds-since-reset timestamps to Date.
    private static let pumpEpoch: TimeInterval = 1_199_145_600

    private func pollStatus() {
        try? client.send(ControlIQIOBRequest())
        try? client.send(InsulinStatusRequest())
        try? client.send(CurrentBatteryV2Request())
        try? client.send(CurrentEgvGuiDataV2Request())
        try? client.send(CurrentBasalStatusRequest())
        try? client.send(LastBolusStatusV2Request())
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
        c.connect(peripheral)   // connect to the first pump found
    }

    public func pumpClientDidBecomeReady(_ c: PumpBLEClient) {
        // Pair over JPAKE (6-digit) if a code is set, then poll status once paired.
        guard !pairingCode.isEmpty, let coord = try? PairingCoordinator(pairingCode: pairingCode) else {
            pollStatus(); return
        }
        coord.onSendRequest = { msg in try? c.send(msg) }   // AUTHORIZATION passes the read-only gate
        coord.onPaired = { [weak self] key, _ in
            self?.authenticationKey = key
            self?.pollStatus()
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
        default: break
        }
        onChange?()
    }

    public func pumpClient(_ c: PumpBLEClient, didError error: Error) {
        snapshot.connection = .disconnected; onChange?()
    }
}
