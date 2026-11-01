import CoreBluetooth
import Foundation
import os

/// The CoreBluetooth side of a passive Dexcom reader: one `CBCentralManager` on its own serial queue,
/// turning callbacks into `DexcomEvent`s and carrying out `DexcomCommand`s. It decides nothing; the
/// observer does. Built on the shape of CGMBLEKit's and G7SensorKit's `BluetoothManager`s.
///
/// Each source has its own central and its own restore identifier, never the pump's
/// (`com.fabolus.app.pump`): two live managers with one restore identifier crash CoreBluetooth.
/// `RestoreIdentifierClaims` refuses a second claim on an identifier instead, and that central runs
/// without state restoration.
///
/// Create one per source and keep it for the source's life: stopping cancels connections and scanning
/// but keeps the manager, because a new manager with the same restore identifier can't be made while
/// the old one lives.
// @unchecked Sendable: every stored property is read and written only on `queue`, the queue the
// central manager delivers its callbacks on and the one `perform` dispatches to.
public final class DexcomCentral: NSObject, @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.fabolus.app.cgm.central")
    private let restoreIdentifier: String?
    private let emit: @Sendable (DexcomEvent) -> Void
    private let log = Logger(subsystem: "com.fabolus.app", category: "DexcomCentral")

    private var manager: CBCentralManager?
    private var peripherals: [UUID: CBPeripheral] = [:]
    private var restoredConnected: [CBPeripheral] = []
    /// Bumped by `stop`, so delayed commands asked for before it don't run after it.
    private var generation = 0

    /// - Parameters:
    ///   - restoreIdentifier: the production source's fixed identifier, or `nil` for no restoration.
    ///   - emit: called on the central's queue, in callback order, for every event.
    public init(restoreIdentifier: String?, emit: @escaping @Sendable (DexcomEvent) -> Void) {
        self.restoreIdentifier = restoreIdentifier.flatMap { RestoreIdentifierClaims.claim($0) ? $0 : nil }
        self.emit = emit
        super.init()
        if let restoreIdentifier, self.restoreIdentifier == nil {
            log.error("restore identifier \(restoreIdentifier, privacy: .public) already in use; no restoration")
        }
    }

    deinit {
        if let restoreIdentifier { RestoreIdentifierClaims.release(restoreIdentifier) }
    }

    /// Creates the central manager if needed. CoreBluetooth then reports its state (and, after a
    /// relaunch, what it restored) through events.
    public func start() {
        queue.async { [self] in
            guard manager == nil else {
                // Restarting after `stop`: report the current state so the observer begins again.
                if let manager { emit(.bluetooth(DexcomBluetoothState(manager.state))) }
                return
            }
            var options: [String: Any] = [:]
            #if os(iOS)
            if let restoreIdentifier { options[CBCentralManagerOptionRestoreIdentifierKey] = restoreIdentifier }
            #endif
            manager = CBCentralManager(delegate: self, queue: queue, options: options)
        }
    }

    public func perform(_ commands: [DexcomCommand]) {
        guard !commands.isEmpty else { return }
        queue.async { [self] in
            for command in commands { perform(command) }
        }
    }

    private func perform(_ command: DexcomCommand) {
        switch command {
        case .lookUp(let known, let delay):
            after(delay) { $0.lookUp(known: known) }
        case .scan:
            guard let manager, manager.state == .poweredOn, !manager.isScanning else { return }
            #if os(iOS)
            // G7SensorKit also listens for other apps connecting, which wakes the app faster than
            // background scanning does.
            manager.registerForConnectionEvents(options: [.serviceUUIDs: Self.lookUpServices])
            #endif
            manager.scanForPeripherals(withServices: [TransmitterServiceUUID.advertisement.cbUUID])
        case .stopScan:
            if let manager, manager.isScanning { manager.stopScan() }
        case .connect(let id, let delay):
            after(delay) { central in
                guard let manager = central.manager, manager.state == .poweredOn,
                    let peripheral = central.peripheral(id)
                else { return }
                peripheral.delegate = central
                manager.connect(peripheral)
            }
        case .cancel(let id):
            if let manager, let peripheral = peripherals[id] { manager.cancelPeripheralConnection(peripheral) }
        case .listen(let id, let characteristic):
            guard let peripheral = peripherals[id], let found = peripheral.characteristic(characteristic) else {
                if let peripheral = peripherals[id] {
                    emit(.setupFailed(DexcomPeripheral(peripheral), "no \(characteristic) characteristic"))
                }
                return
            }
            peripheral.setNotifyValue(true, for: found)
        }
    }

    private func after(_ delay: TimeInterval, _ work: @escaping @Sendable (DexcomCentral) -> Void) {
        guard delay > 0 else { return work(self) }
        let asked = generation
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == asked else { return }
            work(self)
        }
    }

    private static var lookUpServices: [CBUUID] {
        [TransmitterServiceUUID.advertisement.cbUUID, TransmitterServiceUUID.cgmService.cbUUID]
    }

    private func lookUp(known: UUID?) {
        guard let manager, manager.state == .poweredOn else { return }
        let knownPeripheral = known.flatMap { manager.retrievePeripherals(withIdentifiers: [$0]).first }
        let connected = manager.retrieveConnectedPeripherals(withServices: Self.lookUpServices)
        for peripheral in connected + [knownPeripheral].compactMap({ $0 }) { remember(peripheral) }
        emit(
            .found(
                known: knownPeripheral.map(DexcomPeripheral.init), systemConnected: connected.map(DexcomPeripheral.init)
            ))
    }

    private func peripheral(_ id: UUID) -> CBPeripheral? {
        if let peripheral = peripherals[id] { return peripheral }
        guard let peripheral = manager?.retrievePeripherals(withIdentifiers: [id]).first else { return nil }
        remember(peripheral)
        return peripheral
    }

    private func remember(_ peripheral: CBPeripheral) {
        peripherals[peripheral.identifier] = peripheral
    }

    /// Stops scanning and cancels every connection this central made. The manager stays.
    public func stop() {
        queue.async { [self] in
            generation += 1
            guard let manager else { return }
            if manager.isScanning { manager.stopScan() }
            for peripheral in peripherals.values where peripheral.state != .disconnected {
                manager.cancelPeripheralConnection(peripheral)
            }
        }
    }
}

extension DexcomCentral: CBCentralManagerDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        let state = DexcomBluetoothState(central.state)
        log.info("bluetooth \(state.rawValue, privacy: .public)")
        emit(.bluetooth(state))
        guard state == .poweredOn else { return }
        // A peripheral CoreBluetooth restored already connected gets no `didConnect`; report it and
        // discover its services again, since this process holds no characteristics for it yet.
        for peripheral in restoredConnected where peripheral.state == .connected {
            emit(.connected(DexcomPeripheral(peripheral)))
            peripheral.discoverServices([TransmitterServiceUUID.cgmService.cbUUID])
        }
        restoredConnected = []
    }

    #if os(iOS)
    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        let restored = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral] ?? []
        for peripheral in restored {
            peripheral.delegate = self
            remember(peripheral)
        }
        restoredConnected = restored
        log.info("restored \(restored.count) peripherals")
        emit(.restored(restored.map(DexcomPeripheral.init)))
    }

    public func centralManager(
        _ central: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent, for peripheral: CBPeripheral
    ) {
        guard event == .peerConnected else { return }
        remember(peripheral)
        emit(.discovered(DexcomPeripheral(peripheral)))
    }
    #endif

    public func centralManager(
        _ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        remember(peripheral)
        let name = advertisementData[CBAdvertisementDataLocalNameKey] as? String ?? peripheral.name
        emit(.discovered(DexcomPeripheral(id: peripheral.identifier, name: name)))
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log.info("connected \(peripheral.identifier, privacy: .public)")
        peripheral.delegate = self
        emit(.connected(DexcomPeripheral(peripheral)))
        peripheral.discoverServices([TransmitterServiceUUID.cgmService.cbUUID])
    }

    public func centralManager(
        _ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?
    ) {
        let reason: DexcomDisconnect
        if let error = error as? CBError, error.code == .peripheralDisconnected {
            reason = .remote
        } else if let error {
            reason = .error(error.localizedDescription)
        } else {
            reason = .local
        }
        log.info("disconnected \(peripheral.identifier, privacy: .public): \(String(describing: reason))")
        emit(.disconnected(DexcomPeripheral(peripheral), reason))
    }

    public func centralManager(
        _ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?
    ) {
        log.error("failed to connect: \(error?.localizedDescription ?? "no error", privacy: .public)")
        emit(.failedToConnect(DexcomPeripheral(peripheral), error?.localizedDescription))
    }
}

extension DexcomCentral: CBPeripheralDelegate {
    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
            let service = peripheral.services?.first(where: { $0.uuid == TransmitterServiceUUID.cgmService.cbUUID })
        else {
            emit(.setupFailed(DexcomPeripheral(peripheral), error?.localizedDescription ?? "no CGM service"))
            return
        }
        peripheral.discoverCharacteristics(DexcomCharacteristic.allCases.map(\.uuid.cbUUID), for: service)
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?
    ) {
        guard error == nil, DexcomCharacteristic.allCases.allSatisfy({ peripheral.characteristic($0) != nil }) else {
            emit(.setupFailed(DexcomPeripheral(peripheral), error?.localizedDescription ?? "missing characteristics"))
            return
        }
        emit(.ready(DexcomPeripheral(peripheral)))
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard let error else { return }
        emit(.setupFailed(DexcomPeripheral(peripheral), error.localizedDescription))
    }

    public func peripheral(
        _ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?
    ) {
        guard error == nil, let value = characteristic.value, !value.isEmpty,
            let which = DexcomCharacteristic(characteristic.uuid)
        else { return }
        log.debug("\(which.rawValue, privacy: .public) \(value.hexadecimalString, privacy: .public)")
        emit(.value(DexcomPeripheral(peripheral), which, value))
    }
}

/// The restore identifiers live in this process. A second central claiming one runs without
/// restoration instead of crashing CoreBluetooth.
enum RestoreIdentifierClaims {
    private static let claimed = OSAllocatedUnfairLock<Set<String>>(initialState: [])

    static func claim(_ identifier: String) -> Bool {
        claimed.withLock { $0.insert(identifier).inserted }
    }

    static func release(_ identifier: String) {
        _ = claimed.withLock { $0.remove(identifier) }
    }
}

extension DexcomCharacteristic {
    var uuid: CGMServiceCharacteristicUUID {
        switch self {
        case .authentication: return .authentication
        case .control: return .control
        case .backfill: return .backfill
        }
    }

    init?(_ uuid: CBUUID) {
        guard let match = Self.allCases.first(where: { $0.uuid.cbUUID == uuid }) else { return nil }
        self = match
    }
}

extension DexcomPeripheral {
    init(_ peripheral: CBPeripheral) {
        self.init(id: peripheral.identifier, name: peripheral.name)
    }
}

extension DexcomBluetoothState {
    init(_ state: CBManagerState) {
        switch state {
        case .poweredOn: self = .poweredOn
        case .poweredOff: self = .poweredOff
        case .unauthorized: self = .unauthorized
        case .unsupported: self = .unsupported
        case .resetting: self = .resetting
        case .unknown: self = .unknown
        @unknown default: self = .unknown
        }
    }
}

extension CBPeripheral {
    fileprivate func characteristic(_ which: DexcomCharacteristic) -> CBCharacteristic? {
        services?.first { $0.uuid == TransmitterServiceUUID.cgmService.cbUUID }?
            .characteristics?.first { $0.uuid == which.uuid.cbUUID }
    }
}
