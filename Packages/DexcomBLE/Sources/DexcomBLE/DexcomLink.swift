import Foundation

// The seam between CoreBluetooth and the passive G6 and G7 observers. `DexcomCentral` turns
// CoreBluetooth callbacks into `DexcomEvent`s and carries out `DexcomCommand`s; an observer is a plain
// value that turns events into commands and readings. Keeping CoreBluetooth on one side means the
// observers run in tests and in recorded-session replays without a radio.

/// A characteristic of the Dexcom CGM service. G6 and G7 share the service and its UUIDs.
public enum DexcomCharacteristic: String, Sendable, Hashable, CaseIterable {
    case authentication
    case control
    case backfill
}

/// A peripheral as an observer sees it. The `CBPeripheral` itself stays inside `DexcomCentral`.
public struct DexcomPeripheral: Sendable, Hashable {
    public let id: UUID
    public let name: String?

    public init(id: UUID, name: String?) {
        self.id = id
        self.name = name
    }
}

public enum DexcomBluetoothState: String, Sendable {
    case unknown, resetting, unsupported, unauthorized, poweredOff, poweredOn
}

/// Why a connection ended.
public enum DexcomDisconnect: Sendable, Equatable {
    /// The transmitter or sensor closed the link, as it does after every 5-minute exchange.
    case remote
    /// This app cancelled the connection.
    case local
    case error(String)
}

public enum DexcomEvent: Sendable, Equatable {
    case bluetooth(DexcomBluetoothState)
    /// CoreBluetooth relaunched the app and handed back the peripherals it was connected or connecting to.
    case restored([DexcomPeripheral])
    /// The reply to `DexcomCommand.lookUp`: the remembered peripheral if the system still knows it, and
    /// the Dexcom peripherals some app on this phone (normally the Dexcom app) is connected to now.
    case found(known: DexcomPeripheral?, systemConnected: [DexcomPeripheral])
    /// Seen advertising, or (on iOS) connected by another app on this phone.
    case discovered(DexcomPeripheral)
    case connected(DexcomPeripheral)
    /// The CGM service and its characteristics were discovered; notifications can be turned on.
    case ready(DexcomPeripheral)
    /// Service or characteristic discovery, or turning on a notification, failed.
    case setupFailed(DexcomPeripheral, String)
    case disconnected(DexcomPeripheral, DexcomDisconnect)
    case failedToConnect(DexcomPeripheral, String?)
    case value(DexcomPeripheral, DexcomCharacteristic, Data)
    /// A periodic wake-up so an observer can notice that nothing has happened for too long.
    case tick
}

/// What an observer asks `DexcomCentral` to do. None of these writes to the transmitter or sensor:
/// passive mode only turns on notifications, so the Dexcom app keeps the session.
public enum DexcomCommand: Sendable, Equatable {
    /// After `delay` seconds, report the remembered peripheral and the system-connected ones (`found`).
    case lookUp(known: UUID?, delay: TimeInterval)
    /// Scan for the Dexcom advertisement and, on iOS, listen for other apps connecting to one.
    case scan
    case stopScan
    /// After `delay` seconds, connect. A connection request never times out, so this also waits for a
    /// sleeping transmitter's next wake-up.
    case connect(UUID, delay: TimeInterval)
    case cancel(UUID)
    case listen(UUID, DexcomCharacteristic)
}

/// One glucose value the sensor stands behind, with the time it was measured by the sensor's clock.
public struct DexcomReading: Sendable, Equatable {
    /// mg/dL as reported. Under 40 is the sensor's "LOW", below its measurable range.
    public let glucose: UInt16
    public let measuredAt: Date
    /// mg/dL per minute, or `nil` when the sensor reports no trend.
    public let trendRate: Double?
    /// Recovered from the sensor's history rather than measured this cycle.
    public let isBackfill: Bool

    public init(glucose: UInt16, measuredAt: Date, trendRate: Double?, isBackfill: Bool) {
        self.glucose = glucose
        self.measuredAt = measuredAt
        self.trendRate = trendRate
        self.isBackfill = isBackfill
    }
}

public struct DexcomObservation: Sendable, Equatable {
    public var commands: [DexcomCommand]
    public var readings: [DexcomReading]

    public init(commands: [DexcomCommand] = [], readings: [DexcomReading] = []) {
        self.commands = commands
        self.readings = readings
    }
}

/// Why direct Bluetooth isn't reading.
public enum DexcomProblem: Sendable, Equatable {
    case bluetoothOff
    case bluetoothNotAllowed
    case bluetoothUnsupported
    case notFound
    /// The link came up but the Dexcom app never signed in on it, so no readings flow.
    case dexcomAppNotConnected
    case notReady(String)
    case connectionFailed(String)
}

public enum DexcomLinkStatus: Sendable, Equatable {
    case stopped
    /// Waiting for the transmitter or sensor to connect.
    case searching
    /// Connected and signed in by the Dexcom app; waiting for this cycle's reading.
    case waiting
    /// A reading arrived within the last cycle.
    case reading
    case problem(DexcomProblem)
}

/// What an observer learned that is worth keeping across launches.
public struct DexcomMemory: Sendable, Equatable {
    /// The peripheral last read, so a relaunch can reconnect to it directly.
    public var peripheralID: UUID?
    /// The followed sensor's advertised name (G7 only).
    public var sensorName: String?
    /// When the G6 transmitter's clock started. A reading's time is relative to that clock, so keeping
    /// it lets a reading be dated after a relaunch before the Dexcom app next asks for the clock.
    public var activationDate: Date?

    public init(peripheralID: UUID? = nil, sensorName: String? = nil, activationDate: Date? = nil) {
        self.peripheralID = peripheralID
        self.sensorName = sensorName
        self.activationDate = activationDate
    }
}

/// An observer of one kind of Dexcom sensor, read passively alongside the Dexcom app.
public protocol DexcomObserver: Sendable {
    var memory: DexcomMemory { get }
    mutating func start(now: Date) -> [DexcomCommand]
    mutating func stop() -> [DexcomCommand]
    mutating func handle(_ event: DexcomEvent, now: Date) -> DexcomObservation
    func status(now: Date) -> DexcomLinkStatus
}

/// The link bookkeeping G6 and G7 share: Bluetooth state, how long since the sensor was last heard
/// from, connections the Dexcom app never signed in on, and the sensor's own not-ready reason. It turns
/// these into the one status the user sees.
public struct DexcomLinkTracker: Sendable, Equatable {
    /// Two 5-minute cycles and a margin with no connection means the sensor isn't reachable.
    public static let notFoundAfter: TimeInterval = 11 * 60
    /// A reading this recent means the link is delivering.
    public static let readingWithin: TimeInterval = 6 * 60
    /// Connections in a row that closed without the Dexcom app signing in.
    public static let unauthenticatedLimit = 2

    public private(set) var bluetooth: DexcomBluetoothState = .unknown
    public private(set) var startedAt: Date?
    /// The last time a connection to the followed sensor opened or closed.
    public private(set) var lastLinkAt: Date?
    public private(set) var lastReadingAt: Date?
    public private(set) var signedIn = false
    public private(set) var unauthenticatedConnections = 0
    public private(set) var lastError: String?
    public private(set) var notReady: String?

    public init() {}

    public mutating func start(now: Date) {
        self = DexcomLinkTracker()
        startedAt = now
    }

    public mutating func stop() {
        self = DexcomLinkTracker()
    }

    public mutating func setBluetooth(_ state: DexcomBluetoothState) {
        bluetooth = state
        if state != .poweredOn { signedIn = false }
    }

    public mutating func didConnect(now: Date) {
        lastLinkAt = now
        signedIn = false
        lastError = nil
    }

    public mutating func didSignIn(now: Date) {
        signedIn = true
        unauthenticatedConnections = 0
        lastLinkAt = now
    }

    public mutating func didDisconnect(now: Date, _ reason: DexcomDisconnect) {
        if !signedIn { unauthenticatedConnections += 1 }
        signedIn = false
        lastLinkAt = now
        if case .error(let message) = reason { lastError = message }
    }

    public mutating func didFail(_ message: String?) {
        lastError = message ?? "the connection failed"
    }

    public mutating func sensorNotReady(_ reason: String) {
        notReady = reason
    }

    public mutating func didRead(now: Date) {
        lastReadingAt = now
        notReady = nil
    }

    public func status(now: Date) -> DexcomLinkStatus {
        guard let startedAt else { return .stopped }
        switch bluetooth {
        case .poweredOn: break
        case .poweredOff: return .problem(.bluetoothOff)
        case .unauthorized: return .problem(.bluetoothNotAllowed)
        case .unsupported: return .problem(.bluetoothUnsupported)
        case .unknown, .resetting: return .searching
        }
        if let notReady { return .problem(.notReady(notReady)) }
        if let lastReadingAt, now.timeIntervalSince(lastReadingAt) <= Self.readingWithin { return .reading }
        if unauthenticatedConnections >= Self.unauthenticatedLimit { return .problem(.dexcomAppNotConnected) }
        if signedIn { return .waiting }
        let quietSince = max(startedAt, lastLinkAt ?? startedAt)
        if now.timeIntervalSince(quietSince) > Self.notFoundAfter {
            return .problem(lastError.map { .connectionFailed($0) } ?? .notFound)
        }
        return .searching
    }
}
