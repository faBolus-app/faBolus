import DexcomBLE
import Foundation

/// Reads a Dexcom G5, G6 or ONE transmitter passively, alongside the Dexcom app on the same phone.
///
/// iOS shares one Bluetooth link per peripheral among the apps that connect to it. The Dexcom app (and
/// the pump, through its own slot) talks to the transmitter; this observer connects to the same link,
/// waits for the Dexcom app's authentication to succeed, then turns on notifications for the control
/// and backfill characteristics and decodes the replies the transmitter sends to the Dexcom app. It
/// never writes to the transmitter, so it can't take the session from the Dexcom app.
///
/// The passive flow is CGMBLEKit's (`Transmitter` with `passiveModeEnabled`, and `BluetoothManager`'s
/// connect and reconnect rules): listen to authentication first, then control after an authenticated
/// and bonded challenge reply. Turning notifications on before that point, or turning authentication
/// off while the Dexcom app uses it, is what CGMBLEKit found puts CoreBluetooth "into a weird state".
public struct G6Observer: DexcomObserver {
    /// The transmitter ID currently matched against advertised names: the one typed in settings, else
    /// the one the pump reports, else `nil` (any Dexcom transmitter, preferring the one this phone's
    /// Dexcom app is connected to).
    public private(set) var transmitterID: String?
    /// The transmitter the Dexcom app was seen signing in to. Saved by the caller so a relaunch can
    /// reconnect to it directly, which works in the background where scanning is slow.
    public private(set) var peripheralID: UUID?

    private var link = DexcomLinkTracker()
    private var active: DexcomPeripheral?
    private var connected = false
    private var authenticated = false
    private var listening: Set<DexcomCharacteristic> = []
    private var connectFailures = 0
    /// Transmitters found by scanning that never signed in on two connections, when no ID is set: most
    /// likely someone else's. Skipped until the observer restarts.
    private var skipped: Set<UUID> = []
    /// When the current connection request was made, to notice a remembered transmitter that is gone.
    private var requestedAt: Date?
    /// The connection request has waited past the not-found limit, so a scan runs beside it in case the
    /// transmitter was replaced. The request stays: it is what reconnects in the background.
    private var searchingAgain = false

    // Passive observation state, after CGMBLEKit's `Transmitter`. The activation date is kept across
    // launches (`memory`): CGMBLEKit stores it too, and xDrip4iOS dates coexistence readings from it.
    private var activationDate: Date?
    private var backfillBuffer: GlucoseBackfillFrameBuffer?

    /// - Parameter activationDate: the remembered transmitter's clock start, from `memory`; used only
    ///   for readings from `peripheralID`, and refreshed by every clock reply.
    public init(transmitterID: String? = nil, peripheralID: UUID? = nil, activationDate: Date? = nil) {
        self.transmitterID = G6TransmitterID.normalized(transmitterID)
        self.peripheralID = peripheralID
        self.activationDate = peripheralID == nil ? nil : activationDate
    }

    public func status(now: Date) -> DexcomLinkStatus { link.status(now: now) }

    public var memory: DexcomMemory { DexcomMemory(peripheralID: peripheralID, activationDate: activationDate) }

    public mutating func start(now: Date) -> [DexcomCommand] {
        link.start(now: now)
        resetConnection()
        active = nil
        skipped = []
        // CoreBluetooth reports its state once the central exists; the look-up follows `poweredOn`.
        return []
    }

    public mutating func stop() -> [DexcomCommand] {
        var commands: [DexcomCommand] = [.stopScan]
        if let active { commands.append(.cancel(active.id)) }
        link.stop()
        resetConnection()
        active = nil
        return commands
    }

    /// Changes the ID to match. A transmitter that no longer matches is let go and the search starts over.
    public mutating func setTransmitterID(_ id: String?, now: Date) -> [DexcomCommand] {
        let normalized = G6TransmitterID.normalized(id)
        guard normalized != transmitterID else { return [] }
        transmitterID = normalized
        skipped = []
        guard let current = active, !matches(current) else { return [] }
        let wasRunning = link.startedAt != nil
        resetConnection()
        active = nil
        peripheralID = nil
        activationDate = nil
        guard wasRunning, link.bluetooth == .poweredOn else { return [.cancel(current.id)] }
        requestedAt = now
        return [.cancel(current.id), .lookUp(known: nil, delay: 0)]
    }

    public mutating func handle(_ event: DexcomEvent, now: Date) -> DexcomObservation {
        guard link.startedAt != nil else { return DexcomObservation() }
        switch event {
        case .bluetooth(let state):
            link.setBluetooth(state)
            guard state == .poweredOn else {
                resetConnection()
                return DexcomObservation()
            }
            requestedAt = now
            return DexcomObservation(commands: [.lookUp(known: peripheralID, delay: 0)])
        case .restored(let peripherals):
            if active == nil, let peripheral = peripherals.first(where: isOurs) { active = peripheral }
            return DexcomObservation()
        case .found(let known, let systemConnected):
            return DexcomObservation(commands: found(known: known, systemConnected: systemConnected, now: now))
        case .discovered(let peripheral):
            guard matches(peripheral), !skipped.contains(peripheral.id), peripheral.id != active?.id else {
                return DexcomObservation()
            }
            var commands: [DexcomCommand] = [.stopScan]
            if let current = active {
                // Only while searching again for a transmitter that hasn't come back.
                guard searchingAgain, !connected else { return DexcomObservation() }
                commands.append(.cancel(current.id))
            }
            active = peripheral
            searchingAgain = false
            requestedAt = now
            return DexcomObservation(commands: commands + [.connect(peripheral.id, delay: 0)])
        case .connected(let peripheral):
            if active == nil, isOurs(peripheral) { active = peripheral }
            guard isActive(peripheral) else { return DexcomObservation() }
            connected = true
            authenticated = false
            listening = []
            connectFailures = 0
            requestedAt = nil
            link.didConnect(now: now)
            guard searchingAgain else { return DexcomObservation() }
            searchingAgain = false
            return DexcomObservation(commands: [.stopScan])
        case .ready(let peripheral):
            guard isActive(peripheral), connected else { return DexcomObservation() }
            return DexcomObservation(commands: listen(peripheral, .authentication))
        case .setupFailed(let peripheral, let message):
            guard isActive(peripheral) else { return DexcomObservation() }
            link.didFail(message)
            return DexcomObservation(commands: [.cancel(peripheral.id)])
        case .disconnected(let peripheral, let reason):
            return DexcomObservation(commands: disconnected(peripheral, reason, now: now))
        case .failedToConnect(let peripheral, let message):
            guard isActive(peripheral) else { return DexcomObservation() }
            link.didFail(message)
            connected = false
            connectFailures += 1
            requestedAt = now
            return DexcomObservation(commands: [.connect(peripheral.id, delay: retryDelay)])
        case .value(let peripheral, let characteristic, let value):
            guard isActive(peripheral), connected else { return DexcomObservation() }
            // Copy to a zero-based buffer: the decoders index from 0.
            return received(Data(value), on: characteristic, from: peripheral, now: now)
        case .tick:
            return DexcomObservation(commands: tick(now: now))
        }
    }

    // MARK: - Connecting

    /// CGMBLEKit's `managerQueue_scanForPeripheral`: the remembered transmitter first, then one the
    /// system is already connected to, else scan.
    private mutating func found(
        known: DexcomPeripheral?, systemConnected: [DexcomPeripheral], now: Date
    ) -> [DexcomCommand] {
        guard !connected else { return [] }
        let candidate =
            if let known, known.name == nil || matches(known) {
                known
            } else {
                systemConnected.first { matches($0) && !skipped.contains($0.id) }
            }
        active = candidate
        guard let candidate else { return [.scan] }
        requestedAt = now
        return [.stopScan, .connect(candidate.id, delay: 0)]
    }

    private mutating func disconnected(
        _ peripheral: DexcomPeripheral, _ reason: DexcomDisconnect, now: Date
    ) -> [DexcomCommand] {
        guard isActive(peripheral) else { return [] }
        let wasConnected = connected
        let signedIn = authenticated
        resetConnection()
        if wasConnected { link.didDisconnect(now: now, reason) }
        guard link.bluetooth == .poweredOn else { return [] }
        if wasConnected, !signedIn, transmitterID == nil, peripheral.id != peripheralID,
            link.unauthenticatedConnections >= DexcomLinkTracker.unauthenticatedLimit
        {
            // No ID to go by, and the Dexcom app never signed in to this one: try another.
            skipped.insert(peripheral.id)
            active = nil
            requestedAt = now
            return [.lookUp(known: nil, delay: Self.reconnectDelay)]
        }
        // The transmitter sleeps between its 5-minute exchanges. CGMBLEKit waits 2 s for it to shut
        // down, then asks to connect again; the request waits for the next wake-up.
        requestedAt = now
        return [.connect(peripheral.id, delay: Self.reconnectDelay)]
    }

    /// A connection request that has waited longer than the not-found limit may be for a transmitter
    /// that was replaced. Keep the request, which reconnects in the background if it is only out of
    /// range, and scan beside it for a matching transmitter.
    private mutating func tick(now: Date) -> [DexcomCommand] {
        guard !connected, !searchingAgain, let requestedAt, active != nil, link.bluetooth == .poweredOn,
            now.timeIntervalSince(requestedAt) > DexcomLinkTracker.notFoundAfter
        else { return [] }
        searchingAgain = true
        return [.scan]
    }

    static let reconnectDelay: TimeInterval = 2

    /// CGMBLEKit retries a failed connection after 2 s; repeated failures back off, up to a minute, so
    /// a transmitter that keeps refusing isn't hammered.
    private var retryDelay: TimeInterval {
        min(Self.reconnectDelay * pow(2, Double(max(connectFailures - 1, 0))), 60)
    }

    /// "DexcomXX", where XX is the last two characters of the transmitter ID.
    private func matches(_ peripheral: DexcomPeripheral) -> Bool {
        guard let name = peripheral.name, name.hasPrefix("Dexcom") else { return false }
        guard let transmitterID else { return true }
        return name.suffix(2).uppercased() == transmitterID.suffix(2)
    }

    private func isActive(_ peripheral: DexcomPeripheral) -> Bool { peripheral.id == active?.id }

    /// The remembered transmitter, which CoreBluetooth may hand back without a name, or a matching one.
    private func isOurs(_ peripheral: DexcomPeripheral) -> Bool {
        peripheral.id == peripheralID || (matches(peripheral) && !skipped.contains(peripheral.id))
    }

    private mutating func resetConnection() {
        searchingAgain = false
        connected = false
        authenticated = false
        listening = []
        backfillBuffer = nil
    }

    private mutating func listen(_ peripheral: DexcomPeripheral, _ characteristic: DexcomCharacteristic)
        -> [DexcomCommand]
    {
        guard listening.insert(characteristic).inserted else { return [] }
        return [.listen(peripheral.id, characteristic)]
    }

    // MARK: - Observing

    private mutating func received(
        _ value: Data, on characteristic: DexcomCharacteristic, from peripheral: DexcomPeripheral, now: Date
    ) -> DexcomObservation {
        switch characteristic {
        case .authentication:
            guard !authenticated, let message = AuthChallengeRxMessage(data: value), message.isAuthenticated,
                message.isBonded
            else { return DexcomObservation() }
            authenticated = true
            if peripheral.id != peripheralID {
                // Another transmitter: its clock started at another time.
                activationDate = nil
                peripheralID = peripheral.id
            }
            link.didSignIn(now: now)
            return DexcomObservation(commands: listen(peripheral, .control))
        case .control:
            return controlResponse(value, from: peripheral, now: now)
        case .backfill:
            // CGMBLEKit's `didReceiveBackfillResponse`: frame 1 starts a new buffer.
            guard value.count > 2 else { return DexcomObservation() }
            if value[0] == 1 { backfillBuffer = GlucoseBackfillFrameBuffer(identifier: value[1]) }
            backfillBuffer?.append(value)
            return DexcomObservation()
        }
    }

    /// CGMBLEKit's passive `didReceiveControlResponse`.
    private mutating func controlResponse(_ response: Data, from peripheral: DexcomPeripheral, now: Date)
        -> DexcomObservation
    {
        guard let opcode = response.first.flatMap(Opcode.init(rawValue:)) else { return DexcomObservation() }
        switch opcode {
        case .transmitterTimeRx:
            guard let time = TransmitterTimeRxMessage(data: response) else { return DexcomObservation() }
            activationDate = now.addingTimeInterval(-TimeInterval(time.currentTime))
            if !time.hasValidSensorSession { link.sensorNotReady("no sensor session") }
            return DexcomObservation()
        case .glucoseRx, .glucoseG6Rx:
            guard let message = GlucoseRxMessage(data: response) else { return DexcomObservation() }
            // CGMBLEKit subscribes to backfill once the first reading of a connection arrives.
            var observation = DexcomObservation(commands: listen(peripheral, .backfill))
            guard let activationDate else {
                // The reading's time is relative to the transmitter's clock; without the clock reply
                // its measurement time is unknown, and an undated reading is never used.
                link.sensorNotReady("waiting for the transmitter's clock")
                return observation
            }
            if let reading = reading(message.glucose, activationDate: activationDate, backfill: false) {
                observation.readings = [reading]
                link.didRead(now: now)
            }
            return observation
        case .glucoseBackfillRx:
            return DexcomObservation(readings: backfill(response, now: now))
        default:
            return DexcomObservation()
        }
    }

    /// A reading the transmitter stands behind, or `nil` (CGMBLEKit's `Glucose.glucose`: a reliable
    /// calibration state and a value of at least 39, the transmitter's "LOW").
    private mutating func reading(_ message: GlucoseSubMessage, activationDate: Date, backfill: Bool)
        -> DexcomReading?
    {
        let state = CalibrationState(rawValue: message.state)
        guard state.hasReliableGlucose else {
            if !backfill { link.sensorNotReady(String(describing: state)) }
            return nil
        }
        guard message.glucose >= 39 else { return nil }
        let trend = message.trend
        return DexcomReading(
            glucose: message.glucose,
            measuredAt: activationDate.addingTimeInterval(TimeInterval(message.timestamp)),
            trendRate: trend < Int8.max && trend > Int8.min ? Double(trend) / 10 : nil,
            isBackfill: backfill)
    }

    /// CGMBLEKit's `glucoseBackfillRx` checks: the buffer's length, CRC and time span must all match the
    /// reply, or none of it is used.
    private mutating func backfill(_ response: Data, now: Date) -> [DexcomReading] {
        guard let message = GlucoseBackfillRxMessage(data: response), let buffer = backfillBuffer,
            let activationDate, message.bufferLength == buffer.count, message.bufferCRC == buffer.crc16
        else { return [] }
        backfillBuffer = nil
        let messages = buffer.glucose
        guard let first = messages.first, let last = messages.last, first.timestamp == message.startTime,
            last.timestamp == message.endTime, first.timestamp <= last.timestamp
        else { return [] }
        return messages.compactMap { reading($0, activationDate: activationDate, backfill: true) }
    }
}
