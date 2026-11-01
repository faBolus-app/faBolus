import Foundation
import TandemLink
import TandemMessages
import faBolusCore

/// The paired pump, as stored with the pairing. A restored or retrieved reconnect has no advertisement,
/// so the model read from the advertised name at pairing is kept here and passed to the link.
public struct StoredPairing: Sendable, Equatable, Codable {
    public enum Scheme: String, Sendable, Codable {
        /// The 16-character code; every connection runs the challenge again.
        case legacy
        /// The 6-digit code; later connections use the derived secret.
        case jpake
    }

    public var peripheralID: UUID
    public var model: faBolusCore.PumpModel
    public var scheme: Scheme
    public var advertisedName: String?
    /// The pump unit (serial and firmware) seen on the first authenticated connection. A later
    /// connection to a different serial is refused: its history doesn't speak for this pairing's
    /// boluses, and its settings aren't the ones the user paired with.
    public var trustedSerial: UInt32?
    public var pairedAt: Date

    public init(
        peripheralID: UUID, model: faBolusCore.PumpModel, scheme: Scheme, advertisedName: String?,
        trustedSerial: UInt32? = nil, pairedAt: Date
    ) {
        self.peripheralID = peripheralID
        self.model = model
        self.scheme = scheme
        self.advertisedName = advertisedName
        self.trustedSerial = trustedSerial
        self.pairedAt = pairedAt
    }

    /// The ledger's name for this pump: its serial, once known. Bolus IDs are per pump, so history is
    /// used to settle a bolus only when it comes from the pump that assigned the ID.
    public var pumpKey: String? { trustedSerial.map { "tandem|\($0)" } }
}

/// Everything the session persists apart from the pairing secret and the bolus ledger.
public struct PumpSessionRecord: Sendable, Equatable, Codable {
    public var pairing: StoredPairing?
    /// What this pump answers, per unit and firmware (TandemKit's support matrix). Kept with the pairing
    /// so an unsupported read is never sent to the same pump twice.
    public var support: SupportMatrix
    /// The history sequence numbers already held for the paired pump.
    public var coverage: HistoryCoverage
    public var lastHistorySync: Date?

    public init(
        pairing: StoredPairing? = nil, support: SupportMatrix = SupportMatrix(),
        coverage: HistoryCoverage = HistoryCoverage(), lastHistorySync: Date? = nil
    ) {
        self.pairing = pairing
        self.support = support
        self.coverage = coverage
        self.lastHistorySync = lastHistorySync
    }
}

/// Where the session keeps its record. A protocol so tests can make a save fail.
public protocol PumpSessionPersisting: Sendable {
    func load() -> PumpSessionRecord?
    func save(_ record: PumpSessionRecord) throws
}

/// The record as a JSON file, written atomically and readable after the first unlock, because a
/// relaunch in the background while the phone is locked must still reconnect.
public struct FilePumpSessionStore: PumpSessionPersisting {
    public let url: URL

    public init(url: URL) { self.url = url }

    /// `pump-session.json` in the App Group container when there is one, else Application Support.
    public static func defaultURL(appGroupID: String?) -> URL? {
        RemoteBolusLedgerStore.defaultURL(appGroupID: appGroupID)?
            .deletingLastPathComponent().appendingPathComponent("pump-session.json")
    }

    public func load() -> PumpSessionRecord? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(PumpSessionRecord.self, from: data)
    }

    public func save(_ record: PumpSessionRecord) throws {
        try JSONEncoder().encode(record).write(
            to: url, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    }
}

/// The record in memory, for tests and the debug mock.
public final class MemoryPumpSessionStore: PumpSessionPersisting, @unchecked Sendable {
    // @unchecked Sendable: every access goes through `lock`.
    private let lock = NSLock()
    private var record: PumpSessionRecord?
    /// Make the next saves throw, to test a failed save.
    public var failSaves = false

    public init(_ record: PumpSessionRecord? = nil) { self.record = record }

    public func load() -> PumpSessionRecord? { lock.withLock { record } }

    public func save(_ record: PumpSessionRecord) throws {
        try lock.withLock {
            if failSaves { throw CocoaError(.fileWriteUnknown) }
            self.record = record
        }
    }
}

/// The pairing secret in a `SecretStore`: the legacy code, or JPAKE's derived secret. One account, so a
/// new pairing of either kind replaces the old one and the two can never both be present.
public struct PairingSecrets: Sendable {
    public static let account = "pumpPairing"
    public static let keychainService = "com.fabolus.app.pairing"
    private let store: any SecretStore

    public init(store: any SecretStore = KeychainSecretStore(service: Self.keychainService)) { self.store = store }

    /// The stored credentials for a pairing of `scheme`. A stored secret of the other scheme is ignored:
    /// it belongs to an earlier pairing, and guessing would authenticate with the wrong one.
    public func credentials(for scheme: StoredPairing.Scheme) -> PairingCredentials? {
        guard let value = store.secret(for: Self.account) else { return nil }
        switch scheme {
        case .legacy:
            guard value.hasPrefix("legacy:") else { return nil }
            return .legacy(code: String(value.dropFirst("legacy:".count)))
        case .jpake:
            guard value.hasPrefix("jpake:"), let data = Data(base64Encoded: String(value.dropFirst("jpake:".count))),
                !data.isEmpty
            else { return nil }
            return .jpakeResume(derivedSecret: [UInt8](data))
        }
    }

    /// Stores what a later connection authenticates with. A first JPAKE code isn't stored: it works once,
    /// and the derived secret the pairing reports replaces it.
    public func store(_ credentials: PairingCredentials) throws {
        switch credentials {
        case .legacy(let code): try store.setSecret("legacy:" + code, for: Self.account)
        case .jpakeResume(let secret):
            try store.setSecret("jpake:" + Data(secret).base64EncodedString(), for: Self.account)
        case .jpake: break
        }
    }

    public func clear() throws { try store.setSecret(nil, for: Self.account) }
}
