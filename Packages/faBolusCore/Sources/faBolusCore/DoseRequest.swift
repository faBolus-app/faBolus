import Foundation

/// One request to deliver insulin, from whichever surface asked. Every dose, phone or remote, is one
/// of these, so the dose checks and the ledger see a single shape.
public struct DoseRequest: Sendable, Hashable, Codable {
    /// How the insulin is to be delivered.
    public enum Shape: Sendable, Hashable, Codable {
        /// All of it now.
        case now(units: Double)
        /// Part now and the rest spread over `duration`. Room for a later release: no model offers it
        /// (`PumpCapabilities.supportsExtendedBolus`), and the access policy refuses it.
        case extended(nowUnits: Double, laterUnits: Double, duration: TimeInterval)

        /// Every unit the request asks for.
        public var totalUnits: Double {
            switch self {
            case .now(let units): return units
            case .extended(let nowUnits, let laterUnits, _): return nowUnits + laterUnits
            }
        }
    }

    /// Who asked.
    public enum Origin: Sendable, Hashable, Codable {
        /// The phone's own bolus screen.
        case phone
        /// A paired remote. `peerId` names the remote (for example `"garmin"`) and must not be
        /// `phonePeerId`; the request's `id` is the remote's own request ID, so a retried message is
        /// recognized as the same request. `sentAt` is the remote's send time, which the freshness check
        /// needs.
        case remote(peerId: String, sentAt: Date)
        /// A bolus suggestion (an eating nudge) that the user accepted on the phone's normal dose screen.
        /// Room for a later release; nothing produces it yet.
        case nudge(suggestionId: String)

        /// The ledger's name for who asked. The phone and a nudge it opened share one name, because
        /// both are the user at the phone.
        public var peerId: String {
            switch self {
            case .phone, .nudge: return Self.phonePeerId
            case .remote(let peerId, _): return peerId
            }
        }

        public static let phonePeerId = "phone"
    }

    /// The request's ID: a remote's own request ID, or one minted on the phone.
    public let id: String
    public let origin: Origin
    public let shape: Shape
    /// The carbs and glucose the dose was calculated from, when it was. They identify the request
    /// along with its units, so a request ID reused for different inputs is caught.
    public let carbsGrams: Double?
    public let bgMgdl: Int?

    /// - Parameter id: a remote's own request ID, or a fresh one for the phone. Required, with no
    ///   default, so a remote request can't silently get a new ID and slip past the at-most-once check.
    public init(
        id: String, origin: Origin, shape: Shape,
        carbsGrams: Double? = nil, bgMgdl: Int? = nil
    ) {
        self.id = id
        self.origin = origin
        self.shape = shape
        self.carbsGrams = carbsGrams
        self.bgMgdl = bgMgdl
    }

    public var totalUnits: Double { shape.totalUnits }

    /// The ledger key: who asked and the request's ID.
    public var ledgerKey: RemoteBolusLedger.Key { .init(peerId: origin.peerId, requestId: id) }

    /// A fingerprint of everything that defines the dose, so the same request ID with different
    /// parameters is refused rather than replayed, and the same dose resent under a new ID is recognized.
    ///
    /// A remote's calculator request is defined by what the remote sent, its carbs and glucose: the phone
    /// computes the units, and its recompute moves once the first bolus has raised IOB. Keyed on the units,
    /// a resend after that bolus would look like a new dose and be delivered again.
    public var doseKey: String {
        switch shape {
        case .now(let units):
            if case .remote = origin, carbsGrams != nil {
                return RemoteBolusLedger.doseKey(units: nil, carbsGrams: carbsGrams, bgMgdl: bgMgdl)
            }
            return RemoteBolusLedger.doseKey(units: units, carbsGrams: carbsGrams, bgMgdl: bgMgdl)
        case .extended(let nowUnits, let laterUnits, let duration):
            return RemoteBolusLedger.doseKey(units: nowUnits + laterUnits, carbsGrams: carbsGrams, bgMgdl: bgMgdl)
                + String(format: "|x:%.4f/%.4f/%.0f", nowUnits, laterUnits, duration)
        }
    }
}
