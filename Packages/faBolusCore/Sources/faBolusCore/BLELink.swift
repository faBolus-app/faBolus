import Foundation
// watchOS has no CBPeripheralManager; the watch uses RemoteLink, so BLELink is iOS/macOS only.
#if canImport(CoreBluetooth) && !os(watchOS)
import CoreBluetooth

/// Bluetooth-LE transport for the host↔remote link (phone↔Mac and phone↔phone). BLE keeps working
/// when the host iPhone is **locked or backgrounded**: it runs as a BLE peripheral (GATT server)
/// under the `bluetooth-peripheral` background mode — the same mechanism that keeps the pump link
/// alive — and the remote (Mac or another iPhone) runs as a central. Carries `RemoteCommand`s as JSON
/// with a 4-byte length-prefix framing so payloads larger than one ATT packet are fragmented and
/// reassembled.
///
/// Conforms to `RemoteTransport` (+ discovery/pairing). `@unchecked Sendable`: all mutable state is
/// confined to `queue` (also the CoreBluetooth
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
    /// Audit A-08: serve exactly ONE central at a time. The first to subscribe is adopted; any other is
    /// ignored (not broadcast to, its writes dropped) until the accepted one unsubscribes/disconnects.
    /// This matches the single-identity auth in `PeerRemoteHost` (A-01) and keeps the one shared
    /// `rxBuffer` unambiguous — two centrals could otherwise interleave frames into it.
    private var acceptedCentral: CBCentral?

    // Central (Mac / remote iPhone) state
    private struct DiscoveredPeer { let peripheral: CBPeripheral; var name: String; var lastSeen: Date }
    private var centralManager: CBCentralManager?
    // Keyed by the STABLE peripheral identifier, not the advertised name: a backgrounded/locked host
    // stops advertising its LocalName, so keying by name split one device across a name and a UUID and
    // broke reconnect/matching. The display name is carried alongside for the UI.
    private var discovered: [UUID: DiscoveredPeer] = [:]
    private var connectedPeripheral: CBPeripheral?
    private var commandChar: CBCharacteristic?
    /// A name hint (the paired-host name) for picking among several visible peers. BLE selection is NOT
    /// gated on it — a backgrounded host advertises no name, so we connect to any faBolus peer and let
    /// the code/token handshake authenticate the right one.
    private var preferredPeerName: String?
    /// The remote wants to be connected (pairing or reconnecting) → auto-connect to a faBolus peer.
    private var wantsConnection = false
    private var pruneTimer: DispatchSourceTimer?
    private static let peerStale: TimeInterval = 12   // evict peers not re-seen within this window
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
        // P3: build the length-prefixed frame, then capture it as an IMMUTABLE `let` in the concurrent
        // send closure. Capturing the previous `var frame` tripped a Swift 6 Sendable warning (a mutable
        // binding crossing into a `@Sendable` closure); a `let` snapshot is an unambiguous value hand-off.
        // Ordering is preserved because `queue` is serial — frames enqueue and pump in FIFO order.
        let frame: Data = {
            var len = UInt32(data.count).bigEndian
            var f = Data(bytes: &len, count: 4)
            f.append(data)
            return f
        }()
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

    /// Hard cap on a single reassembled frame (audit A-07): a malicious/garbled central can otherwise
    /// declare a ~4 GB length prefix and make us buffer toward it unboundedly (memory-exhaustion DoS).
    /// Generously above any real command (see `RemoteCommand.maxEncodedBytes`).
    private static let maxFrameBytes = 64 * 1024

    private func ingest(_ chunk: Data) {
        rxBuffer.append(chunk)
        while rxBuffer.count >= 4 {
            let len = Int(rxBuffer.prefix(4).reduce(UInt32(0)) { ($0 << 8) | UInt32($1) })
            // Reject an oversized declared length before buffering toward it: drop + resync (a
            // well-behaved peer never sends this; a hostile one can't exhaust memory).
            if len > Self.maxFrameBytes { rxBuffer.removeAll(keepingCapacity: false); break }
            guard rxBuffer.count >= 4 + len else { break }
            let msg = rxBuffer.subdata(in: 4..<(4 + len))
            rxBuffer.removeSubrange(0..<(4 + len))
            if let cmd = try? RemoteCommand.decodeValidated(msg) {
                Task { @MainActor in self.onReceive?(cmd) }
            }
        }
    }

    private func reportReachability() {
        let r = isReachable
        Task { @MainActor in self.onReachabilityChange?(r) }
    }

    // MARK: Pairing (central / remote side)

    public func setPreferredPeer(_ name: String?) {
        queue.async { [weak self] in
            guard let self else { return }
            self.preferredPeerName = name
            self.wantsConnection = (name != nil)
            if name != nil, self.connectedPeripheral == nil { self.connectBestCandidate() }
        }
    }

    /// Connect to the best available faBolus peer: one whose advertised name matches the hint, else the
    /// most-recently-seen. Called whenever we want a connection and aren't connected yet. All discovered
    /// peers advertise our service (the scan is service-filtered), so any of them is a valid host — the
    /// pairing code / stored token authenticates the correct one.
    private func connectBestCandidate() {
        guard connectedPeripheral == nil, wantsConnection, !discovered.isEmpty else { return }
        let pick = discovered.values.first(where: { $0.name == preferredPeerName })
            ?? discovered.values.max(by: { $0.lastSeen < $1.lastSeen })
        if let pick { centralManager?.connect(pick.peripheral, options: nil) }
    }

    /// Scan for faBolus hosts. `allowDuplicates` so `lastSeen` refreshes and stale peers can be pruned.
    private func startScanning() {
        centralManager?.scanForPeripherals(withServices: [Self.serviceUUID],
                                           options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
        guard pruneTimer == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 4, repeating: 4)
        t.setEventHandler { [weak self] in self?.pruneStalePeers() }
        pruneTimer = t
        t.resume()
    }

    /// Drop peers not re-seen within `peerStale` (they walked away or stopped advertising), keeping the
    /// connected one. Re-emits the list so the UI doesn't show ghosts.
    private func pruneStalePeers() {
        let cutoff = Date().addingTimeInterval(-Self.peerStale)
        let before = discovered.count
        discovered = discovered.filter {
            $0.value.peripheral.identifier == connectedPeripheral?.identifier || $0.value.lastSeen >= cutoff
        }
        if discovered.count != before { emitPeers() }
    }

    private func emitPeers() {
        // Exclude the peer we're already connected to — it's shown as the connected device, not as a
        // "pair me" option. Otherwise the same phone appears twice (its BLE name in the list vs. the
        // paired name in the header), which reads as two devices.
        let connectedId = connectedPeripheral?.identifier
        let names = Set(discovered.values.filter { $0.peripheral.identifier != connectedId }.map { $0.name }).sorted()
        Task { @MainActor in self.onPeersChanged?(names) }
    }

    public func disconnectAll() {
        queue.async { [weak self] in
            guard let self, let p = self.connectedPeripheral else { return }
            self.centralManager?.cancelPeripheralConnection(p)
        }
    }

    /// Fully tear down the link: stop advertising/scanning and drop any connection. Used when the user
    /// turns remote access off, so the phone stops advertising a BLE service entirely (zero footprint).
    public func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            switch self.role {
            case .peripheral:
                self.peripheralManager?.stopAdvertising()
                self.peripheralManager?.removeAllServices()
                self.subscribedCentrals.removeAll()
                self.acceptedCentral = nil
                self.rxBuffer.removeAll(keepingCapacity: false)
            case .central:
                self.centralManager?.stopScan()
                self.pruneTimer?.cancel(); self.pruneTimer = nil
                if let p = self.connectedPeripheral { self.centralManager?.cancelPeripheralConnection(p) }
                self.connectedPeripheral = nil; self.commandChar = nil
                self.discovered.removeAll(); self.wantsConnection = false
            }
            self.txChunks.removeAll(); self.rxBuffer.removeAll()
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
        // Audit A-08: adopt the first central; ignore any other while one is active (CoreBluetooth can't
        // refuse the subscribe, but we never broadcast to it and drop its writes below).
        if acceptedCentral == nil { acceptedCentral = central; rxBuffer.removeAll(keepingCapacity: false) }
        guard central.identifier == acceptedCentral?.identifier else { return }
        if !subscribedCentrals.contains(where: { $0.identifier == central.identifier }) {
            subscribedCentrals.append(central)
        }
        reportReachability()
        pump()
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, central: CBCentral,
                                  didUnsubscribeFrom characteristic: CBCharacteristic) {
        subscribedCentrals.removeAll { $0.identifier == central.identifier }
        // Free the slot when the accepted central leaves so the next one can be adopted (A-08).
        if central.identifier == acceptedCentral?.identifier {
            acceptedCentral = nil
            rxBuffer.removeAll(keepingCapacity: false)
        }
        reportReachability()
    }

    public func peripheralManagerIsReady(toUpdateSubscribers peripheral: CBPeripheralManager) {
        pump()
    }

    public func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        // Only ingest writes from the accepted central (audit A-08) — a second central's frames must not
        // interleave into the shared rxBuffer. Reject others' writes explicitly.
        for r in requests where r.central.identifier == acceptedCentral?.identifier {
            if let v = r.value { ingest(v) }
        }
        if let first = requests.first {
            let ok = first.central.identifier == acceptedCentral?.identifier
            peripheral.respond(to: first, withResult: ok ? .success : .insufficientAuthorization)
        }
    }
}

// MARK: - Central (Mac)
extension BLELink: CBCentralManagerDelegate, CBPeripheralDelegate {
    public func centralManagerDidUpdateState(_ central: CBCentralManager) {
        guard central.state == .poweredOn else { return }
        startScanning()
    }

    public func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        if let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
           let p = peripherals.first {
            connectedPeripheral = p
            p.delegate = self
        }
    }

    private func name(for peripheral: CBPeripheral, _ adv: [String: Any]) -> String {
        if let n = adv[CBAdvertisementDataLocalNameKey] as? String, !n.isEmpty { return n }
        if let n = peripheral.name, !n.isEmpty { return n }
        // Backgrounded/locked host: no name in the advert. It IS a faBolus host (service-filtered scan);
        // show a stable, readable label with a short id suffix so multiple such peers stay distinct.
        return "faBolus device (\(peripheral.identifier.uuidString.suffix(4)))"
    }

    public func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                               advertisementData: [String: Any], rssi RSSI: NSNumber) {
        discovered[peripheral.identifier] = DiscoveredPeer(peripheral: peripheral,
                                                           name: name(for: peripheral, advertisementData),
                                                           lastSeen: Date())
        if connectedPeripheral == nil, wantsConnection { connectBestCandidate() }
        emitPeers()
    }

    public func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        connectedPeripheral = peripheral
        peripheral.delegate = self
        peripheral.discoverServices([Self.serviceUUID])
        emitPeers()   // drop the now-connected peer from the discoverable list
    }

    public func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                               error: Error?) {
        if peripheral.identifier == connectedPeripheral?.identifier {
            connectedPeripheral = nil; commandChar = nil; writing = false; txChunks.removeAll(); rxBuffer.removeAll()
        }
        reportReachability()
        emitPeers()   // the peer is discoverable again now that it's disconnected
        // Auto-reconnect to the (or any) faBolus peer when the remote still wants a connection.
        if wantsConnection { connectBestCandidate() }
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
