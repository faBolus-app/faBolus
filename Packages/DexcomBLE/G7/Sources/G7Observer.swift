import DexcomBLE
import Foundation

/// Reads a Dexcom G7 or ONE+ sensor passively, alongside the Dexcom app on the same phone.
///
/// The flow is G7SensorKit's (`G7Sensor` and `G7BluetoothManager`): connect to every "DXCM"/"DX02"
/// sensor in range until one is followed, listen to authentication, turn on control notifications
/// once the Dexcom app's authentication succeeds, and decode the glucose messages the sensor sends it.
/// The first sensor that delivers a reading on this phone is the one this phone's Dexcom app signed in
/// to, and becomes the followed sensor; a reading whose sensor reports its session ended or failed
/// lets it go so the next sensor is found. It never writes to the sensor.
public struct G7Observer: DexcomObserver {
    /// The followed sensor's advertised name ("DXCMxx"), saved by the caller across launches.
    public private(set) var sensorName: String?
    /// The followed sensor's peripheral, saved by the caller so a relaunch can reconnect to it directly.
    public private(set) var peripheralID: UUID?

    private struct Candidate: Sendable, Equatable {
        var peripheral: DexcomPeripheral
        var connected = false
        var authenticated = false
        var listening: Set<DexcomCharacteristic> = []
    }

    private var link = DexcomLinkTracker()
    private var candidates: [UUID: Candidate] = [:]
    private var scanning = false
    /// The followed sensor has been silent past the not-found limit, so other sensors are tried too: it
    /// may have been removed early, without the session-ended message that would let it go.
    private var lookingForNew = false

    // Passive observation state, after G7SensorKit's `G7Sensor`.
    private var activationDate: Date?
    private var backfillBuffer: [G7BackfillMessage] = []

    public init(sensorName: String? = nil, peripheralID: UUID? = nil) {
        self.sensorName = sensorName
        self.peripheralID = peripheralID
    }

    public func status(now: Date) -> DexcomLinkStatus { link.status(now: now) }

    public var memory: DexcomMemory { DexcomMemory(peripheralID: peripheralID, sensorName: sensorName) }

    public mutating func start(now: Date) -> [DexcomCommand] {
        link.start(now: now)
        candidates = [:]
        backfillBuffer = []
        scanning = false
        lookingForNew = false
        return []
    }

    public mutating func stop() -> [DexcomCommand] {
        let commands: [DexcomCommand] =
            [.stopScan]
            + candidates.keys.sorted { $0.uuidString < $1.uuidString }.map {
                .cancel($0)
            }
        link.stop()
        candidates = [:]
        backfillBuffer = []
        scanning = false
        return commands
    }

    public mutating func handle(_ event: DexcomEvent, now: Date) -> DexcomObservation {
        guard link.startedAt != nil else { return DexcomObservation() }
        switch event {
        case .bluetooth(let state):
            link.setBluetooth(state)
            guard state == .poweredOn else {
                for id in candidates.keys { candidates[id]?.connected = false }
                scanning = false
                return DexcomObservation()
            }
            return DexcomObservation(commands: [.lookUp(known: peripheralID, delay: 0)])
        case .restored(let peripherals):
            // CoreBluetooth may hand the followed sensor back without a name.
            for peripheral in peripherals where peripheral.id == peripheralID || connectDecision(peripheral) != nil {
                candidates[peripheral.id] = Candidate(peripheral: peripheral)
            }
            return DexcomObservation()
        case .found(let known, let systemConnected):
            // G7SensorKit's `managerQueue_scanForPeripheral`.
            var commands: [DexcomCommand] = []
            if let known {
                commands += consider(known, assumeFollowed: known.id == peripheralID)
            } else {
                for peripheral in systemConnected { commands += consider(peripheral) }
            }
            if !isFollowedConnected, !scanning {
                scanning = true
                commands.append(.scan)
            }
            return DexcomObservation(commands: commands)
        case .discovered(let peripheral):
            return DexcomObservation(commands: consider(peripheral))
        case .connected(let peripheral):
            if candidates[peripheral.id] == nil, peripheral.id == peripheralID {
                candidates[peripheral.id] = Candidate(peripheral: peripheral)
            }
            guard candidates[peripheral.id] != nil else { return DexcomObservation() }
            candidates[peripheral.id]?.connected = true
            candidates[peripheral.id]?.authenticated = false
            candidates[peripheral.id]?.listening = []
            guard isFollowed(peripheral) else { return DexcomObservation() }
            link.didConnect(now: now)
            lookingForNew = false
            // G7SensorKit stops scanning once the followed sensor is connected.
            return DexcomObservation(commands: stopScanning())
        case .ready(let peripheral):
            guard candidates[peripheral.id]?.connected == true else { return DexcomObservation() }
            return DexcomObservation(commands: listen(peripheral, .authentication))
        case .setupFailed(let peripheral, let message):
            guard candidates[peripheral.id] != nil else { return DexcomObservation() }
            if isFollowed(peripheral) { link.didFail(message) }
            return DexcomObservation(commands: [.cancel(peripheral.id)])
        case .disconnected(let peripheral, let reason):
            return disconnected(peripheral, reason, now: now)
        case .failedToConnect(let peripheral, let message):
            guard candidates[peripheral.id] != nil else { return DexcomObservation() }
            if isFollowed(peripheral) { link.didFail(message) }
            return DexcomObservation(commands: afterLinkEnded(peripheral))
        case .value(let peripheral, let characteristic, let value):
            guard candidates[peripheral.id]?.connected == true else { return DexcomObservation() }
            return received(Data(value), on: characteristic, from: peripheral, now: now)
        case .tick:
            return DexcomObservation(commands: tick(now: now))
        }
    }

    /// The followed sensor hasn't connected for longer than the not-found limit: scan for any sensor,
    /// keeping the request to the followed one in case it is only out of range.
    private mutating func tick(now: Date) -> [DexcomCommand] {
        guard sensorName != nil, !lookingForNew, !isFollowedConnected, link.bluetooth == .poweredOn,
            let startedAt = link.startedAt,
            now.timeIntervalSince(link.lastLinkAt ?? startedAt) > DexcomLinkTracker.notFoundAfter
        else { return [] }
        lookingForNew = true
        guard !scanning else { return [] }
        scanning = true
        return [.scan]
    }

    // MARK: - Connecting

    private enum Decision { case follow, candidate }

    /// G7SensorKit's `shouldConnectPeripheral`: a G7 advertises "DXCMxx", a ONE+ "DX02xx". The followed
    /// sensor is matched on the last two characters; with none followed, every sensor is a candidate.
    private func connectDecision(_ peripheral: DexcomPeripheral) -> Decision? {
        guard let name = peripheral.name, name.hasPrefix("DXCM") || name.hasPrefix("DX02") else { return nil }
        if let sensorName, name.suffix(2) == sensorName.suffix(2) { return .follow }
        return sensorName == nil || lookingForNew ? .candidate : nil
    }

    private mutating func consider(_ peripheral: DexcomPeripheral, assumeFollowed: Bool = false) -> [DexcomCommand] {
        guard candidates[peripheral.id] == nil else { return [] }
        guard assumeFollowed || connectDecision(peripheral) != nil else { return [] }
        candidates[peripheral.id] = Candidate(peripheral: peripheral)
        return [.connect(peripheral.id, delay: 0)]
    }

    private func isFollowed(_ peripheral: DexcomPeripheral) -> Bool {
        guard let sensorName else { return false }
        return peripheral.id == peripheralID || peripheral.name == sensorName
    }

    private var isFollowedConnected: Bool {
        candidates.values.contains { $0.connected && isFollowed($0.peripheral) }
    }

    private mutating func stopScanning() -> [DexcomCommand] {
        guard scanning else { return [] }
        scanning = false
        return [.stopScan]
    }

    private mutating func disconnected(
        _ peripheral: DexcomPeripheral, _ reason: DexcomDisconnect, now: Date
    ) -> DexcomObservation {
        guard let candidate = candidates[peripheral.id] else { return DexcomObservation() }
        // Sometimes the backfill-finished message doesn't arrive before the disconnect.
        let readings = isFollowed(peripheral) ? flushBackfill() : []
        if candidate.connected {
            candidates[peripheral.id]?.connected = false
            if isFollowed(peripheral) || sensorName == nil { link.didDisconnect(now: now, reason) }
        }
        return DexcomObservation(commands: afterLinkEnded(peripheral), readings: readings)
    }

    /// G7SensorKit forgets every peripheral but the followed one and, 2 s later, looks again.
    private mutating func afterLinkEnded(_ peripheral: DexcomPeripheral) -> [DexcomCommand] {
        if !isFollowed(peripheral) { candidates[peripheral.id] = nil }
        guard link.bluetooth == .poweredOn else { return [] }
        if isFollowed(peripheral) {
            candidates[peripheral.id]?.connected = false
            return [.connect(peripheral.id, delay: Self.reconnectDelay)]
        }
        return candidates.isEmpty ? [.lookUp(known: peripheralID, delay: Self.reconnectDelay)] : []
    }

    static let reconnectDelay: TimeInterval = 2

    private mutating func listen(_ peripheral: DexcomPeripheral, _ characteristic: DexcomCharacteristic)
        -> [DexcomCommand]
    {
        guard candidates[peripheral.id]?.listening.insert(characteristic).inserted == true else { return [] }
        return [.listen(peripheral.id, characteristic)]
    }

    // MARK: - Observing

    private mutating func received(
        _ value: Data, on characteristic: DexcomCharacteristic, from peripheral: DexcomPeripheral, now: Date
    ) -> DexcomObservation {
        switch characteristic {
        case .authentication:
            guard candidates[peripheral.id]?.authenticated == false,
                let message = AuthChallengeRxMessage(data: value), message.isAuthenticated, message.isBonded
            else { return DexcomObservation() }
            candidates[peripheral.id]?.authenticated = true
            if isFollowed(peripheral) || sensorName == nil { link.didSignIn(now: now) }
            return DexcomObservation(commands: listen(peripheral, .control))
        case .control:
            return controlResponse(value, from: peripheral, now: now)
        case .backfill:
            // G7SensorKit's `didReceiveBackfillResponse`.
            if value.count == 9, let message = G7BackfillMessage(data: value) { backfillBuffer.append(message) }
            return DexcomObservation()
        }
    }

    private mutating func controlResponse(_ response: Data, from peripheral: DexcomPeripheral, now: Date)
        -> DexcomObservation
    {
        switch response.first.flatMap(G7Opcode.init(rawValue:)) {
        case .glucoseTx:
            guard let message = G7GlucoseMessage(data: response) else { return DexcomObservation() }
            return glucose(message, from: peripheral, now: now)
        case .backfillFinished:
            return DexcomObservation(readings: flushBackfill())
        default:
            return DexcomObservation()
        }
    }

    /// G7SensorKit's `handleGlucoseMessage` and `G7CGMManager.sensor(_:didRead:)`.
    private mutating func glucose(_ message: G7GlucoseMessage, from peripheral: DexcomPeripheral, now: Date)
        -> DexcomObservation
    {
        var commands = listen(peripheral, .backfill)
        if sensorName == nil || (lookingForNew && !isFollowed(peripheral)), let name = peripheral.name {
            // The first sensor to deliver a reading here is the one this phone's Dexcom app signed in to.
            sensorName = name
            peripheralID = peripheral.id
            lookingForNew = false
            link.didSignIn(now: now)
            commands += stopScanning()
            for other in candidates.keys.sorted(by: { $0.uuidString < $1.uuidString }) where other != peripheral.id {
                candidates[other] = nil
                commands.append(.cancel(other))
            }
        } else if !isFollowed(peripheral) {
            return DexcomObservation(commands: commands)
        } else {
            peripheralID = peripheral.id
        }

        // The message's timestamp is seconds since the sensor started; its arrival dates it.
        activationDate = now.addingTimeInterval(-TimeInterval(message.messageTimestamp))
        var readings: [DexcomReading] = []
        if message.algorithmState.sensorFailed || message.algorithmState == .known(.sessionEnded) {
            link.sensorNotReady(String(describing: message.algorithmState))
            // Let this sensor go and find the next one.
            sensorName = nil
            peripheralID = nil
            if !scanning {
                scanning = true
                commands.append(.scan)
            }
        } else if let value = message.glucose, message.hasReliableGlucose, let activationDate,
            let timestamp = message.glucoseTimestamp
        {
            readings.append(
                DexcomReading(
                    glucose: value, measuredAt: activationDate.addingTimeInterval(TimeInterval(timestamp)),
                    trendRate: message.trend, isBackfill: false))
            link.didRead(now: now)
        } else {
            link.sensorNotReady(String(describing: message.algorithmState))
        }
        return DexcomObservation(commands: commands, readings: readings)
    }

    private mutating func flushBackfill() -> [DexcomReading] {
        let buffer = backfillBuffer
        backfillBuffer = []
        guard let activationDate else { return [] }
        return buffer.compactMap { entry in
            guard let value = entry.glucose, entry.hasReliableGlucose else { return nil }
            return DexcomReading(
                glucose: value, measuredAt: activationDate.addingTimeInterval(TimeInterval(entry.timestamp)),
                trendRate: entry.trend, isBackfill: true)
        }
    }
}
