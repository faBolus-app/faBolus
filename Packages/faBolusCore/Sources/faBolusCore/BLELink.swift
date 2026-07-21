import Foundation
// watchOS has no CBPeripheralManager; the watch uses RemoteLink, so BLELink is iOS/macOS only.
#if canImport(CoreBluetooth) && !os(watchOS)
import CoreBluetooth

/// Bluetooth-LE transport for the phone↔Mac remote link. Unlike `PeerLink` (MultipeerConnectivity,
/// Wi-Fi), BLE keeps working when the iPhone is **locked or backgrounded**: the phone runs as a BLE
/// peripheral (GATT server) under the `bluetooth-peripheral` background mode — the same mechanism
/// that keeps the pump link alive — and the Mac runs as a central. Carries `RemoteCommand`s as JSON
/// with a 4-byte length-prefix framing so payloads larger than one ATT packet are fragmented and
/// reassembled.
///
/// Exposes the same surface as `PeerLink` (RemoteTransport + discovery/pairing) so it is a drop-in
/// swap. `@unchecked Sendable`: all mutable state is confined to `queue` (also the CoreBluetooth
/// delegate queue); the public callbacks are re-dispatched to the main actor.
public final class BLELink: NSObject, RemoteTransport, @unchecked Sendable {
    /// The iPhone host is the `peripheral`; the Mac remote is the `central`.
    public enum Role: Sendable { case peripheral, central }

    public var onReceive: (@MainActor (RemoteCommand) -> Void)?
    public var onReachabilityChange: (@MainActor (Bool) -> Void)?
    public var onPeersChanged: (@MainActor ([String]) -> Void)?

    // Fixed GATT identifiers shared by both ends. CBUUID is immutable; safe to share.
    nonisolated(unsafe) public static let serviceUUID = CBUUID(string: "F5A00001-8C2E-4B1A-9E7D-0A1B2C3D4E5F")
    nonisolated(unsafe) static let statusCharUUID = CBUUID(string: "F5A00002-8C2E-4B1A-9E7D-0A1B2C3D4E5F")   // notify: phone→Mac
    nonisolated(unsafe) static let commandCharUUID = CBUUID(string: "F5A00003-8C2E-4B1A-9E7D-0A1B2C3D4E5F")  // write: Mac→phone

    private let role: Role
    private let displayName: String
    private let queue = DispatchQueue(label: "com.fabolus.blelink")

    // Peripheral (iPhone) state
    private var peripheralManager: CBPeripheralManager?
    private var statusChar: CBMutableCharacteristic?
    private var subscribedCentrals: [CBCentral] = []

    // Central (Mac) state
    private var centralManager: CBCentralManager?
    private var discovered: [String: CBPeripheral] = [:]   // name → peripheral (retained so we can connect)
    private var connectedPeripheral: CBPeripheral?
    private var commandChar: CBCharacteristic?
    private var preferredPeerName: String?
    private var writing = false

    // Framing
    private var rxBuffer = Data()
    private var txChunks: [Data] = []

    public init(role: Role, displayName: String = BLELink.defaultDisplayName()) {
        self.role = role
        self.displayName = displayName
        super.init()
        switch role {
        case .peripheral:
            peripheralManager = CBPeripheralManager(delegate: self, queue: queue,
                options: [CBPeripheralManagerOptionRestoreIdentifierKey: "com.fabolus.ble.peripheral"])
        case .central:
            centralManager = CBCentralManager(delegate: self, queue: queue,
                options: [CBCentralManagerOptionRestoreIdentifierKey: "com.fabolus.ble.central"])
        }
    }

    public static func defaultDisplayName() -> String {
        let raw = ProcessInfo.processInfo.hostName
        return raw.isEmpty ? "faBolus" : String(raw.prefix(24))
    }

    public var isReachable: Bool {
        switch role {
        case .peripheral: return !subscribedCentrals.isEmpty
        case .central: return connectedPeripheral != nil && commandChar != nil
        }
    }
    public var connectedPeerName: String? { connectedPeripheral?.name }

    // MARK: Send

    public func send(_ command: RemoteCommand) {
        guard let data = try? command.encoded() else { return }
        var len = UInt32(data.count).bigEndian
        var frame = Data(bytes: &len, count: 4)
        frame.append(data)
        queue.async { [weak self] in
            guard let self else { return }
            self.txChunks.append(contentsOf: self.split(frame))
            self.pump()
        }
    }

    /// Current per-packet payload size for the active connection (ATT MTU minus headers), floored.
    private var chunkSize: Int {
        switch role {
        case .peripheral: return max(subscribedCentrals.map { $0.maximumUpdateValueLength }.min() ?? 20, 20)
        case .central: return max(connectedPeripheral?.maximumWriteValueLength(for: .withResponse) ?? 20, 20)
        }
    }

    private func split(_ data: Data) -> [Data] {
        let size = chunkSize
        var out: [Data] = [], i = 0
        while i < data.count { let e = min(i + size, data.count); out.append(data.subdata(in: i..<e)); i = e }
        return out
    }

    /// Drain the pending chunk queue, honoring each transport's flow control.
    private func pump() {
        switch role {
        case .peripheral:
            guard let pm = peripheralManager, let ch = statusChar, !subscribedCentrals.isEmpty else { return }
            while let chunk = txChunks.first {
                if pm.updateValue(chunk, for: ch, onSubscribedCentrals: nil) { txChunks.removeFirst() }
                else { break }   // queue full — resumes in peripheralManagerIsReadyToUpdateSubscribers
            }
        case .central:
            guard let p = connectedPeripheral, let ch = commandChar, !writing, let chunk = txChunks.first else { return }
            txChunks.removeFirst()
            writing = true
            p.writeValue(chunk, for: ch, type: .withResponse)   // serialized; next chunk on didWriteValueFor
        }
    }

    // MARK: Receive / reassembly (called on `queue`)

    private func ingest(_ chunk: Data) {
        rxBuffer.append(chunk)
        while rxBuffer.count >= 4 {
            let len = Int(rxBuffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            guard rxBuffer.count >= 4 + len else { break }
            let msg = rxBuffer.subdata(in: 4..<(4 + len))
            rxBuffer.removeSubrange(0..<(4 + len))
            if let cmd = try? RemoteCommand.decode(msg) {
                Task { @MainActor in self.onReceive?(cmd) }
            }
        }
    }

    private func reportReachability() {
        let r = isReachable
        Task { @MainActor in self.onReachabilityChange?(r) }
    }

    // MARK: Pairing (central / Mac side) — mirrors PeerLink's API

    public func setPreferredPeer(_ name: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.preferredPeerName = name
            if let name, let p = self.discovered[name], self.connectedPeripheral == nil {
                self.centralManager?.connect(p, options: nil)
            }
        }
    }

    public func disconnectAll() {
        queue.async { [weak self] in
            guard let self, let p = self.connectedPeripheral else { return }
            self.centralManager?.cancelPeripheralConnection(p)
        }
    }
}

// MARK: - Peripheral (iPhone)
extension BLELink: CBPeripheralManagerDelegate {
    public func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        guard peripheral.state == .poweredOn else { return }
        let status = CBMutableCharacteristic(type: Self.statusCharUUID, properties: [.notify],
                                             value: nil, permissions: [.readable])
        let command = CBMutableCharacteristic(type: Self.commandCharUUID,
                                              properties: [.write, .writeWithoutResponse],
                                              value: nil, permissions: [.writeable])
        let service = CBMutableService(type: Self.serviceUUID, primary: true)
        service.characteristics = [status, command]
        statusChar = status
        peripheral.removeAllServices()
        peripheral.add(service)
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [Self.serviceUUID],
                                     CBAdvertisementDataLocalNameKey: displayName])
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, willRestoreState dict: [String: Any]) {
        // Reattach after a background relaunch: recover our notify characteristic + resume advertising.
        if let services = dict[CBPeripheralManagerRestoredStateServicesKey] as? [CBMutableService] {
            for s in services where s.uuid == Self.serviceUUID {
                statusChar = s.characteristics?.first { $0.uuid == Self.statusCharUUID } as? CBMutableCharacteristic
            }
        }
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                  didSubscribeTo characteristic: CBCharacteristic) {
        if !subscribedCentrals.contains(where: { $0.identifier == central.identifier }) {
            subscribedCentrals.append(central)
        }
        reportReachability()
        pump()
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                  didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribedCentrals.removeAll { $0.identifier == central.identifier }
        reportReachability()
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        pump()
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests { if let v = r.value { ingest(v) } }
        if let first = requests.first { peripheral.respond(to: first, withResult: .success) }
    }
}

// MARK: - Central (Mac)
extension BLELink: CBCentralManagerDelegate, CBPeripheralDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        central.scanForPeripherals(withServices: [Self.serviceUUID], options: nil)
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let p = peripherals.first {
            connectedPeripheral = p
            p.delegate = self
        }
    }

    private func name(for peripheral: CBPeripheral, _ adv: [String: Any]) -> String {
        (adv[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name ?? peripheral.identifier.uuidString
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let n = name(for: peripheral, advertisementData)
        discovered[n] = peripheral
        if n == preferredPeerName, connectedPeripheral == nil {
            central.connect(peripheral, options: nil)
        }
        let names = Array(discovered.keys)
        Task { @MainActor in self.onPeersChanged?(names) }
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedPeripheral = peripheral
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        if peripheral.identifier == connectedPeripheral?.identifier {
            connectedPeripheral = nil; commandChar = nil; writing = false; txChunks.removeAll(); rxBuffer.removeAll()
        }
        reportReachability()
        // Auto-reconnect to the paired peer when it comes back.
        if let name = preferredPeerName, let p = discovered[name] { central.connect(p, options: nil) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard let service = peripheral.services?.first(where: { $0.uuid == Self.serviceUUID }) else { return }
        peripheral.discoverCharacteristics([Self.statusCharUUID, Self.commandCharUUID], for: service)
    }

    public func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService,
                           error: Error?) {
        for c in service.characteristics ?? [] {
            if c.uuid == Self.commandCharUUID { commandChar = c }
            if c.uuid == Self.statusCharUUID { peripheral.setNotifyValue(true, for: c) }
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic,
                           error: Error?) {
        if characteristic.uuid == Self.statusCharUUID, characteristic.isNotifying {
            reportReachability()
            pump()   // flush anything queued before we were ready (e.g. the initial statusRead)
        }
    }

    public func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        if characteristic.uuid == Self.statusCharUUID, let v = characteristic.value { ingest(v) }
    }

    public func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic,
                           error: Error?) {
        writing = false
        pump()
    }
}
#endif
