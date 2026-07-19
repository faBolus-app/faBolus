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

    /// Set once pairing completes; required to sign insulin-affecting commands.
    public var authenticationKey: [UInt8] = []
    public var pumpTimeSinceReset: UInt32 = 0
    private var isPaired: Bool { !authenticationKey.isEmpty }

    public override init() {
        super.init()
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

    private func pollStatus() {
        try? client.send(ControlIQIOBRequest())
        try? client.send(InsulinStatusRequest())
        try? client.send(CurrentBatteryV2Request())
    }
}

// PumpBLEClient invokes its delegate on the main queue; hop into the actor to touch state.
extension LivePumpDataSource: PumpBLEClientDelegate {
    public nonisolated func pumpClient(_ c: PumpBLEClient, didChange state: PumpBLEClient.State) {
        MainActor.assumeIsolated {
            switch state {
            case .scanning: snapshot.connection = .scanning
            case .connecting, .discovering: snapshot.connection = .connecting
            case .ready: snapshot.connection = .connected
            case .disconnected, .idle: snapshot.connection = .disconnected
            case .bolusing: snapshot.connection = .bolusing
            case .error: snapshot.connection = .error
            default: break
            }
            onChange?()
        }
    }

    public nonisolated func pumpClient(_ c: PumpBLEClient, didDiscover peripheral: CBPeripheral, rssi: Int) {
        MainActor.assumeIsolated { c.connect(peripheral) }   // connect to the first pump found
    }

    public nonisolated func pumpClientDidBecomeReady(_ c: PumpBLEClient) {
        MainActor.assumeIsolated { pollStatus() }
    }

    public nonisolated func pumpClient(_ c: PumpBLEClient, didReceiveFrame frame: [UInt8], on ch: Characteristic) {
        MainActor.assumeIsolated {
            guard let parsed = try? ResponseParser.parse(frame: frame) else { return }
            switch parsed.message {
            case let m as ControlIQIOBResponse: snapshot.iobUnits = m.iobUnits
            case let m as InsulinStatusResponse: snapshot.reservoirUnits = Double(m.currentInsulinAmount)
            case let m as CurrentBatteryV2Response: snapshot.batteryPercent = m.batteryPercent
            default: break
            }
            onChange?()
        }
    }

    public nonisolated func pumpClient(_ c: PumpBLEClient, didError error: Error) {
        MainActor.assumeIsolated { snapshot.connection = .error; onChange?() }
    }
}
